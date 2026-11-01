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
            DispatchQueue.main.async { self?.prices[tick.coinId] = tick }
        }
        cex.onTick = handler
        dex.onTick = handler
        dex.onError = { [weak self] err in DispatchQueue.main.async { self?.dexError = err } }
        dispatch()
        cex.start()
        dex.start()
    }

    func stop() { cex.stop(); dex.stop() }

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

    func toggleMenuBar(_ id: String) {
        guard let i = coins.firstIndex(where: { $0.id == id }) else { return }
        coins[i].showInMenuBar.toggle(); changed()
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
