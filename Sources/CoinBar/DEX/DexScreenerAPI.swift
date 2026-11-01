import Foundation

/// DexScreener 免费接口封装（无需 API Key）。
/// 文档：https://docs.dexscreener.com/api/reference
/// 免费额度大约 300 次/分钟，批量查价格时一次最多 30 个地址。
enum DexScreenerAPI {
    static let baseURL = URL(string: "https://api.dexscreener.com/latest/dex")!

    /// /tokens 端点一次最多接受 30 个地址
    static let maxAddressesPerBatch = 30

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = [
            "User-Agent": "CoinBar/1.0 (macOS)",
            "Accept": "application/json",
        ]
        return URLSession(configuration: cfg)
    }()

    /// GET /latest/dex/tokens/{addr1,addr2,...}
    static func tokensURL(addresses: [String]) -> URL? {
        guard !addresses.isEmpty else { return nil }
        let list = addresses
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: ",")
        return URL(string: "\(baseURL.absoluteString)/tokens/\(list)")
    }

    /// GET /latest/dex/search?q={query}
    static func searchURL(query: String) -> URL? {
        var comps = URLComponents(string: "\(baseURL.absoluteString)/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        return comps?.url
    }

    /// 带重试的 GET。429 / 5xx 退避重试，连不上也再试一次；
    /// 其它错误直接抛。错误类型见 `DexScreenerError`。
    static func get<T: Decodable>(_ url: URL, as type: T.Type, maxAttempts: Int = 3) async throws -> T {
        let decoder = JSONDecoder()
        var lastError: DexScreenerError = .unknown

        for attempt in 0..<maxAttempts {
            if Task.isCancelled { throw CancellationError() }
            do {
                let (data, response) = try await session.data(from: url)

                if let http = response as? HTTPURLResponse {
                    guard (200..<300).contains(http.statusCode) else {
                        let err = DexScreenerError.http(http.statusCode)
                        lastError = err
                        // 只有限流和服务端错误值得重试
                        guard http.statusCode == 429 || http.statusCode >= 500 else { throw err }
                        if attempt < maxAttempts - 1 {
                            try? await Task.sleep(nanoseconds: Self.backoff(attempt))
                        }
                        continue
                    }
                }

                do {
                    return try decoder.decode(T.self, from: data)
                } catch {
                    throw DexScreenerError.decoding
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError {
                if urlError.code == .cancelled { throw CancellationError() }
                // 连不上：可能是断网，也可能是在网络受限地区被墙
                lastError = .network
                // 网络不通重试一次就够，别让用户等太久才能看到提示
                if attempt >= 1 { throw DexScreenerError.network }
            } catch let err as DexScreenerError {
                lastError = err
                // 已经明确不可重试的错误，直接抛
                if case .http(let code) = err, !(code == 429 || code >= 500) { throw err }
                if case .decoding = err { throw err }
            } catch {
                lastError = .unknown
            }

            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: Self.backoff(attempt))
            }
        }
        throw lastError
    }

    private static func backoff(_ attempt: Int) -> UInt64 {
        UInt64(Double(attempt + 1) * 1.5 * 1_000_000_000)
    }
}

enum DexScreenerError: LocalizedError, Equatable {
    /// 连不上服务器：断网，或所在网络访问不了 DexScreener
    case network
    /// 服务器返回了非 2xx（429 表示请求太频繁）
    case http(Int)
    /// 返回的数据解析不了
    case decoding
    case unknown

    var errorDescription: String? {
        switch self {
        case .network: return "连不上 DexScreener，可能需要开启代理"
        case .http(let code): return "DexScreener 返回 HTTP \(code)"
        case .decoding: return "DexScreener 返回的数据无法解析"
        case .unknown: return "DexScreener 请求失败"
        }
    }
}

// MARK: - 接口模型

/// 接口里数字有时是数字、有时是字符串，统一兼容
struct DexNumber: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = Double(s)
        } else {
            value = nil
        }
    }
}

struct DexToken: Decodable {
    let address: String
    let name: String?
    let symbol: String?
}

struct DexPriceChange: Decodable {
    let m5: DexNumber?
    let h1: DexNumber?
    let h6: DexNumber?
    let h24: DexNumber?
}

struct DexLiquidity: Decodable {
    let usd: DexNumber?
    let base: DexNumber?
    let quote: DexNumber?
}

struct DexPair: Decodable {
    let chainId: String
    let dexId: String?
    let pairAddress: String?
    let baseToken: DexToken
    let quoteToken: DexToken?
    let priceUsd: DexNumber?
    let priceChange: DexPriceChange?
    let liquidity: DexLiquidity?

    var price: Double? { priceUsd?.value }
    var liquidityUSD: Double { liquidity?.usd?.value ?? 0 }
    var change24h: Double? { priceChange?.h24?.value }
}

struct DexResponse: Decodable {
    let pairs: [DexPair]?
}

// MARK: - 把接口返回的池子整理成候选

enum DexCandidates {
    /// 同一个代币（chainId + 合约地址）可能有多个池子，取流动性最大的那个。
    /// 结果按流动性从高到低排列。
    static func build(from pairs: [DexPair], limit: Int = 30) -> [CoinCandidate] {
        var best: [String: DexPair] = [:]
        for pair in pairs {
            guard pair.price != nil,
                  let symbol = pair.baseToken.symbol, !symbol.isEmpty else { continue }
            let key = pairKey(chainId: pair.chainId, address: pair.baseToken.address)
            if let current = best[key], current.liquidityUSD >= pair.liquidityUSD { continue }
            best[key] = pair
        }

        let candidates: [CoinCandidate] = best.values.map { pair in
            let symbol = (pair.baseToken.symbol ?? "?").uppercased()
            let name = pair.baseToken.name ?? symbol
            let coin = Coin(
                symbol: symbol,
                name: name,
                source: .dex(chainId: pair.chainId, address: pair.baseToken.address)
            )
            return CoinCandidate(
                coin: coin,
                priceUSD: pair.price,
                liquidityUSD: pair.liquidity?.usd?.value,
                detail: "\(chainDisplayName(pair.chainId)) · \(dexDisplayName(pair.dexId))"
            )
        }

        let sorted = candidates.sorted { lhs, rhs in
            let l = lhs.liquidityUSD ?? 0
            let r = rhs.liquidityUSD ?? 0
            if l != r { return l > r }
            return lhs.coin.symbol < rhs.coin.symbol
        }
        return Array(sorted.prefix(limit))
    }

    /// provider 匹配价格用的 key
    static func pairKey(chainId: String, address: String) -> String {
        "\(chainId.lowercased()):\(address.lowercased())"
    }

    static func chainDisplayName(_ chainId: String) -> String {
        switch chainId.lowercased() {
        case "ethereum": return "Ethereum"
        case "bsc": return "BNB Chain"
        case "solana": return "Solana"
        case "base": return "Base"
        case "arbitrum": return "Arbitrum"
        case "polygon": return "Polygon"
        case "polygon-zkevm": return "Polygon zkEVM"
        case "optimism": return "Optimism"
        case "avalanche": return "Avalanche"
        case "blast": return "Blast"
        case "zksync": return "zkSync"
        case "linea": return "Linea"
        case "scroll": return "Scroll"
        case "mantle": return "Mantle"
        case "sui": return "Sui"
        case "ton": return "TON"
        case "tron": return "Tron"
        case "pulsechain": return "PulseChain"
        case "hyperevm": return "HyperEVM"
        default: return chainId
        }
    }

    static func dexDisplayName(_ dexId: String?) -> String {
        guard let dexId, !dexId.isEmpty else { return "DEX" }
        switch dexId.lowercased() {
        case "uniswap": return "Uniswap"
        case "pancakeswap": return "PancakeSwap"
        case "raydium": return "Raydium"
        case "orca": return "Orca"
        case "meteora": return "Meteora"
        case "pumpfun": return "Pump.fun"
        case "aerodrome": return "Aerodrome"
        case "sushiswap": return "SushiSwap"
        case "curve": return "Curve"
        case "camelot": return "Camelot"
        case "velodrome": return "Velodrome"
        case "traderjoe": return "Trader Joe"
        case "gmtrade": return "GMGN"
        default: return dexId
        }
    }
}
