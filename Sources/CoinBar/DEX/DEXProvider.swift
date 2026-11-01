import Foundation

/// 链上代币价格源：用 DexScreener /tokens 轮询。
///
/// - 每 10 秒一轮（免费接口能给到的较高频率，远低于 300 次/分钟限额）
/// - 一次请求只查一个地址：批量端点总共只返回 30 个池子，热门币会把名额占满，
///   同批其它币就拿不到数据了
/// - 每轮最多刷新 20 个地址，币更多时轮转，保证不超过 300 次/分钟
/// - 同一个代币有多个池子时，取流动性最大的那个池子
final class DEXProvider: PriceProvider {
    var onTick: ((PriceTick) -> Void)?

    /// 数据源状态：整轮请求全部失败时给出错误（DexScreener 被墙就是 .network），
    /// 恢复正常时给 nil。只在状态变化时回调，可在任意线程调用。
    var onError: ((DexScreenerError?) -> Void)?

    /// 轮询间隔，默认 10 秒
    var refreshInterval: TimeInterval = 10

    /// 每轮最多请求多少个地址（20 个 / 10 秒 = 120 次/分钟）
    private let maxRequestsPerRound = 20
    /// 单次请求间隔，控制在 5 次/秒以内
    private let requestDelay: TimeInterval = 0.2

    private let lock = NSLock()
    private var coins: [Coin] = []
    private var running = false
    private var loopTask: Task<Void, Never>?
    /// setCoins 有变化时置位，让当前这一轮等待提前结束、立刻拉一次
    private var kick = false
    /// 币比 maxRequestsPerRound 多时，从上次的位置继续轮转
    private var rotationIndex = 0
    /// 上一次通知给界面的状态，只在轮询任务里访问
    private var lastReportedError: DexScreenerError?

    // MARK: - PriceProvider

    func setCoins(_ coins: [Coin]) {
        let dexCoins = coins.filter { coin in
            if case .dex = coin.source { return true }
            return false
        }
        storeCoins(dexCoins)
    }

    func start() {
        guard markRunning() else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        let task = markStopped()
        task?.cancel()
    }

    // MARK: - 加锁的状态读写（保持同步方法，避免在 async 上下文里直接用 NSLock）

    private func storeCoins(_ newCoins: [Coin]) {
        lock.lock()
        defer { lock.unlock() }
        let changed = newCoins.map(\.id) != coins.map(\.id)
        coins = newCoins
        if changed { kick = true }
    }

    private func snapshotCoins() -> [Coin] {
        lock.lock()
        defer { lock.unlock() }
        return coins
    }

    private func takeKick() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = kick
        kick = false
        return value
    }

    /// 返回 false 表示已经在运行
    private func markRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    private func markStopped() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        running = false
        let task = loopTask
        loopTask = nil
        kick = false
        return task
    }

    // MARK: - 轮询循环

    private func runLoop() async {
        // 启动前积累的 kick 没有意义，第一轮本来就要刷新
        _ = takeKick()

        while !Task.isCancelled {
            let roundStart = Date()
            let error = await refreshOnce()
            if Task.isCancelled { return }
            reportStatus(error)

            // 一轮固定 10 秒（含请求耗时），请求多时不会把周期越拖越长
            let elapsed = Date().timeIntervalSince(roundStart)
            let remaining = max(0, refreshInterval - elapsed)

            // 拆成小片睡眠，期间如果 setCoins 变了就提前醒来
            let slice: TimeInterval = 0.25
            var waited: TimeInterval = 0
            while waited < remaining {
                do {
                    try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                } catch {
                    return
                }
                if Task.isCancelled { return }
                waited += slice

                if takeKick() { break }
            }
        }
    }

    /// 返回非 nil 表示这一轮所有请求都失败了（比如 DexScreener 被墙）
    private func refreshOnce() async -> DexScreenerError? {
        let snapshot = snapshotCoins()
        guard !snapshot.isEmpty else { return nil }

        // 按 (chainId, address) 建索引；地址去重
        var wanted: [String: Coin] = [:]
        var addressOrder: [String] = []
        var seenAddresses = Set<String>()

        for coin in snapshot {
            guard case .dex(let chainId, let address) = coin.source else { continue }
            let addr = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !addr.isEmpty else { continue }
            wanted[DexCandidates.pairKey(chainId: chainId, address: addr)] = coin
            if seenAddresses.insert(addr).inserted {
                addressOrder.append(addr)
            }
        }

        guard !addressOrder.isEmpty else { return nil }

        // 本轮要刷新的地址：币多时轮转
        let total = addressOrder.count
        let start = rotationIndex % total
        let count = min(maxRequestsPerRound, total)
        var batch: [String] = []
        batch.reserveCapacity(count)
        for offset in 0..<count {
            batch.append(addressOrder[(start + offset) % total])
        }
        rotationIndex = (start + count) % total

        var attempted = 0
        var failed = 0
        var lastError: DexScreenerError?

        for (i, address) in batch.enumerated() {
            if Task.isCancelled { return nil }

            if let url = DexScreenerAPI.tokensURL(addresses: [address]) {
                attempted += 1
                do {
                    let response = try await DexScreenerAPI.get(url, as: DexResponse.self)
                    if let pairs = response.pairs {
                        emit(pairs: pairs, wanted: wanted)
                    }
                } catch is CancellationError {
                    return nil
                } catch let err as DexScreenerError {
                    failed += 1
                    lastError = err
                } catch {
                    failed += 1
                    lastError = .unknown
                }
            }

            if i < batch.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(requestDelay * 1_000_000_000))
            }
        }

        // 只有整轮全军覆没才当作数据源故障，部分失败是单个币的问题
        guard attempted > 0, failed == attempted else { return nil }
        return lastError ?? .unknown
    }

    /// 状态只在变化时回调，避免每轮重复通知界面
    private func reportStatus(_ error: DexScreenerError?) {
        guard error != lastReportedError else { return }
        lastReportedError = error
        onError?(error)
    }

    /// 从一批池子里挑出每个代币流动性最大的池子，回调价格
    private func emit(pairs: [DexPair], wanted: [String: Coin]) {
        var best: [String: DexPair] = [:]

        for pair in pairs {
            guard pair.price != nil else { continue }
            let key = DexCandidates.pairKey(chainId: pair.chainId, address: pair.baseToken.address)
            guard wanted[key] != nil else { continue }
            if let current = best[key], current.liquidityUSD >= pair.liquidityUSD { continue }
            best[key] = pair
        }

        let now = Date()
        for (key, pair) in best {
            guard let coin = wanted[key], let price = pair.price else { continue }
            let tick = PriceTick(
                coinId: coin.id,
                priceUSD: price,
                change24h: pair.change24h,
                timestamp: now
            )
            onTick?(tick)
        }
    }
}
