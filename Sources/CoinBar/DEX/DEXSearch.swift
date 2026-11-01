import Foundation

/// 添加链上代币时的两个查询入口。
///
/// 错误约定：
/// - 返回空数组 = 没找到这个币（或该地址在 DexScreener 上没有交易对），不是错误
/// - 抛 `DexScreenerError.network` = 连不上 DexScreener，多半需要代理
/// - 抛 `DexScreenerError.http(429)` = 请求太频繁
enum DEXSearch {
    /// 合约地址 → 识别是哪条链、什么币。结果按流动性从高到低。
    ///
    /// 先查 DexScreener；它没收录的币（很多新币、小币）再查 GeckoTerminal。
    /// 一个地址可能在多条链上都存在，所以返回的是候选列表，让用户确认。
    static func resolve(address: String) async throws -> [CoinCandidate] {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return [] }

        var dexError: DexScreenerError?

        if let url = DexScreenerAPI.tokensURL(addresses: [addr]) {
            do {
                let response = try await DexScreenerAPI.get(url, as: DexResponse.self)
                let candidates = DexCandidates.build(from: response.pairs ?? [], limit: 25, onlyBaseAddress: addr)
                if !candidates.isEmpty { return candidates }
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as DexScreenerError {
                dexError = err
            } catch {
                dexError = .unknown
            }
        }

        return try await resolveWithGeckoTerminal(address: addr, dexError: dexError)
    }

    private static func resolveWithGeckoTerminal(address: String, dexError: DexScreenerError?) async throws -> [CoinCandidate] {
        guard let url = GeckoTerminalAPI.searchPoolsURL(query: address) else { return [] }
        do {
            let response = try await GeckoTerminalAPI.get(url, as: GTResponse<GTPool>.self)
            let candidates = GTCandidates.build(from: response.data ?? [], limit: 25, onlyBaseAddress: address)
            if candidates.isEmpty { return [] }
            return await GTCandidates.enriching(candidates)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 两个源都没成功：优先把 DexScreener 的错误抛出去，界面据此提示开代理
            if let dexError { throw dexError }
            if let geckoError = error as? DexScreenerError { throw geckoError }
            throw DexScreenerError.unknown
        }
    }

    /// 按名称 / 代号搜链上代币，结果按流动性从高到低。
    ///
    /// 如果输入看起来像合约地址，会额外按地址精确查一遍并合并，
    /// 这样 UI 只调 search 也能处理粘贴地址的情况。
    static func search(query: String) async throws -> [CoinCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // 输入是合约地址时直接精确查询。模糊搜索会把「该地址作为计价货币」的池子
        // 也返回，那些池子的 base 是别的币，混进来会误导用户。
        if looksLikeContractAddress(q) {
            return try await resolve(address: q)
        }

        var candidates: [CoinCandidate] = []
        var firstError: DexScreenerError?

        if let url = DexScreenerAPI.searchURL(query: q) {
            do {
                let response = try await DexScreenerAPI.get(url, as: DexResponse.self)
                candidates = DexCandidates.build(from: response.pairs ?? [], limit: 30)
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as DexScreenerError {
                firstError = err
            } catch {
                firstError = .unknown
            }
        }

        // DexScreener 没搜到，再试 GeckoTerminal（收录更全）
        if candidates.isEmpty, let geckoURL = GeckoTerminalAPI.searchPoolsURL(query: q) {
            do {
                let response = try await GeckoTerminalAPI.get(geckoURL, as: GTResponse<GTPool>.self, maxAttempts: 2)
                let geckoCandidates = GTCandidates.build(from: response.data ?? [], limit: 30)
                if !geckoCandidates.isEmpty {
                    candidates = await GTCandidates.enriching(geckoCandidates)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil {
                    firstError = (error as? DexScreenerError) ?? .unknown
                }
            }
        }

        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.id).inserted }
        let sorted = unique.sorted { lhs, rhs in
            let l = lhs.liquidityUSD ?? 0
            let r = rhs.liquidityUSD ?? 0
            if l != r { return l > r }
            return lhs.coin.symbol < rhs.coin.symbol
        }

        // 一条结果都没有，且请求本身出错：把错误抛给界面（比如提示开代理）
        if sorted.isEmpty, let firstError {
            throw firstError
        }
        return Array(sorted.prefix(30))
    }

    /// 0x 开头的 40 位十六进制（EVM），或 32~44 位 base58（Solana）视为合约地址
    static func looksLikeContractAddress(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x"), s.count == 42 {
            return s.dropFirst(2).allSatisfy { $0.isHexDigit }
        }
        if (32...44).contains(s.count) {
            let base58 = CharacterSet(charactersIn: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
            return s.unicodeScalars.allSatisfy { base58.contains($0) }
        }
        return false
    }
}
