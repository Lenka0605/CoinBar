import Foundation

/// 币种来源：中心化交易所（实时 WebSocket）或链上 DEX（合约地址轮询）
enum CoinSource: Codable, Hashable {
    /// 交易所现货交易对，如 symbol = "BTC"，对 USDT 计价
    case cex(symbol: String)
    /// 链上代币：chainId 用 DexScreener 的命名（ethereum / bsc / solana / base / arbitrum ...）
    case dex(chainId: String, address: String)
}

/// 用户关注的一个币
struct Coin: Codable, Hashable, Identifiable {
    var id: String { switch source {
        case .cex(let s): return "cex:\(s.uppercased())"
        case .dex(let c, let a): return "dex:\(c):\(a.lowercased())"
    } }
    var symbol: String          // 显示用，如 "BTC"、"PEPE"
    var name: String            // 全名，如 "Bitcoin"
    var source: CoinSource
    var showInMenuBar: Bool = false
    /// 图标地址（链上币由 DexScreener 提供；交易所币用内置图标，可为空）
    var iconURL: String? = nil
}

/// 一次价格更新
struct PriceTick: Equatable {
    let coinId: String
    let priceUSD: Double
    let change24h: Double?      // 百分比，如 -2.35 表示 -2.35%
    let timestamp: Date
}

/// 搜索/识别结果（添加币种时用）
struct CoinCandidate: Hashable, Identifiable {
    var id: String { coin.id }
    let coin: Coin
    let priceUSD: Double?
    let liquidityUSD: Double?   // DEX 用，便于用户挑流动性最大的那个
    let detail: String          // 给用户看的说明，如 "Binance 现货" / "Solana · Raydium"
}

/// 所有数据源都实现这个协议
protocol PriceProvider: AnyObject {
    /// 价格更新回调（任意线程调用即可，PriceStore 会切回主线程）
    var onTick: ((PriceTick) -> Void)? { get set }
    /// 设置要订阅的币（只会传入属于本数据源的币），可重复调用，需要自己做增量订阅
    func setCoins(_ coins: [Coin])
    func start()
    func stop()
}
