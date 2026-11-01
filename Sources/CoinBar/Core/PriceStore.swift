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
    // 菜单栏显示样式
    @Published var showChangeInBar: Bool {
        didSet { UserDefaults.standard.set(showChangeInBar, forKey: "showChangeInBar") }
    }
    @Published var showIconInBar: Bool {
        didSet { UserDefaults.standard.set(showIconInBar, forKey: "showIconInBar") }
    }
    @Published var showSymbolInBar: Bool {
        didSet { UserDefaults.standard.set(showSymbolInBar, forKey: "showSymbolInBar") }
    }
    /// 菜单栏轮播：每隔多少秒换一个币；0 = 关闭（显示勾选的币）
    @Published var rotateSeconds: Int {
        didSet { UserDefaults.standard.set(rotateSeconds, forKey: "rotateSeconds") }
    }
    /// 轮播顺序：false = 按列表顺序，true = 随机
    @Published var rotateRandom: Bool {
        didSet { UserDefaults.standard.set(rotateRandom, forKey: "rotateRandom") }
    }
    /// 轮播范围：false = 全部币种，true = 只轮播勾选的币
    @Published var rotateCheckedOnly: Bool {
        didSet { UserDefaults.standard.set(rotateCheckedOnly, forKey: "rotateCheckedOnly") }
    }
    /// 公开图标库都没有时，后台打开 Ave 网页读取图标（默认开）
    @Published var aveWebIcons: Bool {
        didSet { UserDefaults.standard.set(aveWebIcons, forKey: "aveWebIcons") }
    }
    static let rotateOptions = [3, 5, 10, 15, 30, 60]

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
        showIconInBar = UserDefaults.standard.object(forKey: "showIconInBar") as? Bool ?? true
        showSymbolInBar = UserDefaults.standard.object(forKey: "showSymbolInBar") as? Bool ?? true
        rotateSeconds = UserDefaults.standard.object(forKey: "rotateSeconds") as? Int ?? 0
        rotateRandom = UserDefaults.standard.object(forKey: "rotateRandom") as? Bool ?? false
        rotateCheckedOnly = UserDefaults.standard.object(forKey: "rotateCheckedOnly") as? Bool ?? false
        aveWebIcons = UserDefaults.standard.object(forKey: "aveWebIcons") as? Bool ?? true
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

    /// 超过阈值没更新视为数据陈旧。交易所有 WS 推送 + 每 60 秒 REST 补价，给 90 秒；
    /// 链上每轮都会回 tick，但币多时会轮转，给 120 秒
    func isStale(_ coin: Coin, now: Date = Date()) -> Bool {
        guard let t = prices[coin.id] else { return true }
        let limit: TimeInterval
        if case .dex = coin.source { limit = 120 } else { limit = 90 }
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
        // 轮播开启时一次只显示一个币，可以勾选任意多个
        if rotateSeconds == 0, !coins[i].showInMenuBar,
           coins.filter(\.showInMenuBar).count >= Self.maxInMenuBar { return false }
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
