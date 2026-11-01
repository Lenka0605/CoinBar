import Foundation
import Combine

/// 全局状态：关注列表（持久化）+ 最新价格；把币分发给对应的数据源
@MainActor
final class PriceStore: ObservableObject {
    static let shared = PriceStore()

    @Published private(set) var coins: [Coin] = []
    @Published private(set) var prices: [String: PriceTick] = [:]
    /// 链上数据源整轮请求失败（大陆多半是没开代理）
    @Published private(set) var dexError: DexScreenerError?
    var hasDexCoins: Bool { coins.contains { if case .dex = $0.source { return true }; return false } }
    @Published var showChangeInBar: Bool {
        didSet { UserDefaults.standard.set(showChangeInBar, forKey: "showChangeInBar") }
    }

    private let cex = CEXProvider()
    private let dex = DEXProvider()
    private let key = "coins.v1"

    static let defaults: [Coin] = [
        Coin(symbol: "BTC", name: "Bitcoin", source: .cex(symbol: "BTC"), showInMenuBar: true),
        Coin(symbol: "ETH", name: "Ethereum", source: .cex(symbol: "ETH")),
        Coin(symbol: "SOL", name: "Solana", source: .cex(symbol: "SOL")),
        Coin(symbol: "BNB", name: "BNB", source: .cex(symbol: "BNB")),
        Coin(symbol: "DOGE", name: "Dogecoin", source: .cex(symbol: "DOGE")),
        Coin(symbol: "XRP", name: "XRP", source: .cex(symbol: "XRP")),
    ]

    private init() {
        showChangeInBar = UserDefaults.standard.object(forKey: "showChangeInBar") as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Coin].self, from: data) {
            coins = saved
        } else {
            coins = Self.defaults
        }
    }

    func start() {
        let debug = ProcessInfo.processInfo.environment["COINBAR_DEBUG"] != nil
        let handler: (PriceTick) -> Void = { [weak self] tick in
            if debug { print("tick", tick.coinId, tick.priceUSD, tick.change24h ?? 0) }
            Task { @MainActor in self?.enqueue(tick) }
        }
        cex.onTick = handler
        dex.onTick = handler
        dex.onError = { [weak self] err in Task { @MainActor in self?.dexError = err } }
        dispatch()
        cex.start()
        dex.start()
    }

    func stop() { cex.stop(); dex.stop() }

    // MARK: 节流：行情可能一秒几十条，攒 0.5 秒统一发布一次，避免菜单/窗口频繁重绘
    private var pending: [String: PriceTick] = [:]
    private var flushScheduled = false

    private func enqueue(_ tick: PriceTick) {
        guard contains(tick.coinId) else { return }
        pending[tick.coinId] = tick
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushScheduled = false
                guard !self.pending.isEmpty else { return }
                self.prices.merge(self.pending) { _, new in new }
                self.pending.removeAll()
            }
        }
    }

    /// 超过阈值没更新视为数据陈旧。交易所只在价格变动时推送，冷门币可能很久不动，给 180 秒；
    /// 链上每轮都会回 tick，但币多时会轮转，给 120 秒
    func isStale(_ coin: Coin, now: Date = Date()) -> Bool {
        guard let t = prices[coin.id] else { return true }
        let limit: TimeInterval
        if case .dex = coin.source { limit = 120 } else { limit = 180 }
        return now.timeIntervalSince(t.timestamp) > limit
    }

    // MARK: 编辑关注列表
    func add(_ coin: Coin) {
        guard !coins.contains(where: { $0.id == coin.id }) else { return }
        coins.append(coin); changed()
    }

    func remove(_ id: String) {
        coins.removeAll { $0.id == id }
        prices[id] = nil
        changed()
    }

    func move(from: IndexSet, to: Int) {
        coins.move(fromOffsets: from, toOffset: to); changed()
    }

    /// 菜单栏最多显示几个币（再多会把系统图标挤掉）
    static let maxInMenuBar = 3

    /// 返回 false 表示已达上限、没有勾选成功
    @discardableResult
    func toggleMenuBar(_ id: String) -> Bool {
        guard let i = coins.firstIndex(where: { $0.id == id }) else { return false }
        if !coins[i].showInMenuBar && coins.filter(\.showInMenuBar).count >= Self.maxInMenuBar { return false }
        coins[i].showInMenuBar.toggle(); changed()
        return true
    }

    func contains(_ id: String) -> Bool { coins.contains { $0.id == id } }

    private func changed() {
        if let data = try? JSONEncoder().encode(coins) { UserDefaults.standard.set(data, forKey: key) }
        dispatch()
    }

    private func dispatch() {
        cex.setCoins(coins.filter { if case .cex = $0.source { return true }; return false })
        dex.setCoins(coins.filter { if case .dex = $0.source { return true }; return false })
    }
}
