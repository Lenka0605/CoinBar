import Foundation

/// GeckoTerminal 免费接口封装（无需 API Key）。
/// 作为 DexScreener 的补充：很多新币、小币 DexScreener 没收录，它收得比较全。
/// 文档：https://docs.geckoterminal.com/api-reference
/// 免费额度：每个 IP 每分钟 30 次，所以调用方要拉开间隔。
///
/// 错误类型复用 `DexScreenerError`，这样界面不用区分两个数据源。
enum GeckoTerminalAPI {
    static let baseURL = URL(string: "https://api.geckoterminal.com/api/v2")!
    /// tokens/multi 一次最多 30 个地址
    static let maxAddressesPerBatch = 30
    /// 30 次/分钟，单次之间至少隔 2 秒
    static let requestSpacing: TimeInterval = 2.0

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 40
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "CoinBar/1.0 (macOS)",
        ]
        return URLSession(configuration: cfg)
    }()

    // MARK: 地址

    static func searchPoolsURL(query: String) -> URL? {
        var comps = URLComponents(string: "\(baseURL.absoluteString)/search/pools")
        comps?.queryItems = [URLQueryItem(name: "query", value: query)]
        return comps?.url
    }

    static func tokensMultiURL(network: String, addresses: [String], includeTopPools: Bool = false) -> URL? {
        guard !addresses.isEmpty else { return nil }
        let list = addresses
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: ",")
        var comps = URLComponents(string: "\(baseURL.absoluteString)/networks/\(network)/tokens/multi/\(list)")
        if includeTopPools {
            comps?.queryItems = [URLQueryItem(name: "include", value: "top_pools")]
        }
        return comps?.url
    }

    /// 带重试的 GET。429 会退避（5s / 10s），网络错误重试一次。
    static func get<T: Decodable>(_ url: URL, as type: T.Type, maxAttempts: Int = 3) async throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var lastError: DexScreenerError = .unknown

        for attempt in 0..<maxAttempts {
            if Task.isCancelled { throw CancellationError() }
            do {
                let (data, response) = try await session.data(from: url)

                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 429 {
                        lastError = .http(429)
                        if attempt < maxAttempts - 1 {
                            try? await Task.sleep(nanoseconds: backoff(attempt))
                        }
                        continue
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw DexScreenerError.http(http.statusCode)
                    }
                }

                do {
                    return try decoder.decode(T.self, from: data)
                } catch {
                    throw DexScreenerError.decoding
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as DexScreenerError {
                if case .decoding = err { throw err }
                if case .http(let code) = err, !(code == 429 || code >= 500) { throw err }
                lastError = err
            } catch let urlError as URLError {
                if urlError.code == .cancelled { throw CancellationError() }
                lastError = .network
                if attempt >= 1 { throw DexScreenerError.network }
            } catch {
                lastError = .unknown
            }

            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: backoff(attempt))
            }
        }
        throw lastError
    }

    private static func backoff(_ attempt: Int) -> UInt64 {
        UInt64(Double(attempt + 1) * 5) * 1_000_000_000
    }

    // MARK: 链名对照

    /// GeckoTerminal 的网络 id → DexScreener 的 chainId（Coin.source 里统一存后者）
    static func dexChainId(fromNetwork network: String) -> String {
        switch network.lowercased() {
        case "eth": return "ethereum"
        case "polygon_pos": return "polygon"
        case "avax": return "avalanche"
        case "ftm": return "fantom"
        case "cro": return "cronos"
        default: return network.lowercased()
        }
    }

    /// DexScreener 的 chainId → GeckoTerminal 的网络 id
    static func network(fromChainId chainId: String) -> String {
        switch chainId.lowercased() {
        case "ethereum": return "eth"
        case "polygon": return "polygon_pos"
        case "avalanche": return "avax"
        case "fantom": return "ftm"
        case "cronos": return "cro"
        default: return chainId.lowercased()
        }
    }

    /// GeckoTerminal 的 token id 形如 `bsc_0x85a...` / `solana_DezX...`
    static func splitTokenID(_ id: String) -> (network: String, address: String)? {
        if let range = id.range(of: "_0x", options: .backwards) {
            let network = String(id[..<range.lowerBound])
            let address = String(id[range.lowerBound...].dropFirst())
            guard !network.isEmpty, !address.isEmpty else { return nil }
            return (network, address)
        }
        guard let idx = id.firstIndex(of: "_") else { return nil }
        let network = String(id[..<idx])
        let address = String(id[id.index(after: idx)...])
        guard !network.isEmpty, !address.isEmpty else { return nil }
        return (network, address)
    }

    static func key(network: String, address: String) -> String {
        "\(network.lowercased()):\(address.lowercased())"
    }
}

// MARK: - 接口模型

struct GTResponse<T: Decodable>: Decodable {
    let data: [T]?
    /// `?include=top_pools` 时随 token 一起返回的池子信息
    let included: [GTPoolSummary]?
}

/// included 里的池子（只取算涨跌幅需要的字段）。
/// 字段全部可选，这样即使 included 里混了别的类型也不会让整个响应解析失败。
struct GTPoolSummary: Decodable {
    let id: String?
    let attributes: Attributes?

    struct Attributes: Decodable {
        let reserveInUsd: DexNumber?
        let priceChangePercentage: [String: DexNumber]?
    }
}

struct GTPool: Decodable {
    let id: String
    let attributes: Attributes
    let relationships: Relationships?

    struct Attributes: Decodable {
        let name: String?
        let address: String?
        let baseTokenPriceUsd: DexNumber?
        let priceChangePercentage: [String: DexNumber]?
        let reserveInUsd: DexNumber?
    }

    struct Relationships: Decodable {
        let baseToken: Ref?
        let dex: Ref?

        struct Ref: Decodable {
            let data: RefData?
        }

        struct RefData: Decodable {
            let id: String
        }
    }
}

struct GTToken: Decodable {
    let id: String
    let attributes: Attributes
    let relationships: Relationships?

    struct Attributes: Decodable {
        let address: String?
        let name: String?
        let symbol: String?
        let imageUrl: String?
        let priceUsd: DexNumber?
        let totalReserveInUsd: DexNumber?
    }

    struct Relationships: Decodable {
        let topPools: TopPools?

        struct TopPools: Decodable {
            let data: [Ref]?
        }

        struct Ref: Decodable {
            let id: String
        }
    }
}

// MARK: - 把 GeckoTerminal 的池子整理成候选

enum GTCandidates {
    /// 同一个代币（chainId + 合约地址）有多个池子时取流动性最大的。
    /// `onlyBaseAddress` 用于按合约地址精确查询，过滤掉 base 是别的币的池子。
    static func build(from pools: [GTPool], limit: Int = 30, onlyBaseAddress: String? = nil) -> [CoinCandidate] {
        var best: [String: (pool: GTPool, chainId: String, address: String)] = [:]

        for pool in pools {
            guard let baseID = pool.relationships?.baseToken?.data?.id,
                  let split = GeckoTerminalAPI.splitTokenID(baseID),
                  let price = pool.attributes.baseTokenPriceUsd?.value, price > 0 else { continue }
            if let want = onlyBaseAddress, !DexCandidates.addressEquals(split.address, want) { continue }

            let chainId = GeckoTerminalAPI.dexChainId(fromNetwork: split.network)
            let key = DexCandidates.pairKey(chainId: chainId, address: split.address)
            let liquidity = pool.attributes.reserveInUsd?.value ?? 0
            if let current = best[key],
               (current.pool.attributes.reserveInUsd?.value ?? 0) >= liquidity { continue }
            best[key] = (pool, chainId, split.address)
        }

        let candidates: [CoinCandidate] = best.values.map { entry in
            let pool = entry.pool
            let poolSymbol = symbol(fromPoolName: pool.attributes.name, fallbackAddress: entry.address)
            let coin = Coin(
                symbol: poolSymbol,
                name: poolSymbol,
                source: .dex(chainId: entry.chainId, address: entry.address)
            )
            return CoinCandidate(
                coin: coin,
                priceUSD: pool.attributes.baseTokenPriceUsd?.value,
                liquidityUSD: pool.attributes.reserveInUsd?.value,
                detail: "\(DexCandidates.chainDisplayName(entry.chainId)) · \(dexDisplay(pool.relationships?.dex?.data?.id))"
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

    /// 用 tokens/multi 补准确名称和图标。失败就保持原样，不影响搜索结果。
    static func enriching(_ candidates: [CoinCandidate]) async -> [CoinCandidate] {
        guard !candidates.isEmpty else { return candidates }

        var groups: [String: [(address: String, chainId: String)]] = [:]
        for candidate in candidates {
            guard case .dex(let chainId, let address) = candidate.coin.source else { continue }
            let network = GeckoTerminalAPI.network(fromChainId: chainId)
            groups[network, default: []].append((address, chainId))
        }

        var info: [String: GTToken.Attributes] = [:]
        var isFirstRequest = true

        for (network, entries) in groups {
            let addresses = entries.map(\.address)
            for chunk in chunks(addresses, size: GeckoTerminalAPI.maxAddressesPerBatch) {
                if !isFirstRequest {
                    try? await Task.sleep(nanoseconds: UInt64(GeckoTerminalAPI.requestSpacing * 1_000_000_000))
                }
                isFirstRequest = false

                guard let url = GeckoTerminalAPI.tokensMultiURL(network: network, addresses: chunk) else { continue }
                guard let response = try? await GeckoTerminalAPI.get(url, as: GTResponse<GTToken>.self, maxAttempts: 2) else { continue }
                for token in response.data ?? [] {
                    guard let address = token.attributes.address else { continue }
                    info[GeckoTerminalAPI.key(network: network, address: address)] = token.attributes
                }
            }
        }

        guard !info.isEmpty else { return candidates }

        return candidates.map { candidate in
            guard case .dex(let chainId, let address) = candidate.coin.source else { return candidate }
            let network = GeckoTerminalAPI.network(fromChainId: chainId)
            guard let attributes = info[GeckoTerminalAPI.key(network: network, address: address)] else {
                return candidate
            }

            var coin = candidate.coin
            if let image = attributes.imageUrl, !image.isEmpty { coin.iconURL = image }
            if let name = attributes.name, !name.isEmpty { coin.name = name }
            if let symbol = attributes.symbol, !symbol.isEmpty { coin.symbol = symbol.uppercased() }

            return CoinCandidate(
                coin: coin,
                priceUSD: candidate.priceUSD,
                liquidityUSD: candidate.liquidityUSD,
                detail: candidate.detail
            )
        }
    }

    private static func symbol(fromPoolName name: String?, fallbackAddress: String) -> String {
        if let name, let first = name.split(separator: "/").first {
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.uppercased() }
        }
        return String(fallbackAddress.prefix(6)).uppercased()
    }

    private static func dexDisplay(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "DEX" }
        let parts = id.split(separator: "_")
        guard let first = parts.first else { return id }
        var name = DexCandidates.dexDisplayName(String(first))
        if parts.count > 1 {
            name += " " + parts.dropFirst().joined(separator: " ").uppercased()
        }
        return name
    }

    private static func chunks<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0, !items.isEmpty else { return [] }
        var result: [[T]] = []
        var index = 0
        while index < items.count {
            let end = min(index + size, items.count)
            result.append(Array(items[index..<end]))
            index = end
        }
        return result
    }
}
