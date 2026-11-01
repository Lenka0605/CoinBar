import Foundation

/// 大陆可直连的链上行情兜底。无需 key，公共端点限额 100 次/分钟。
/// /token 响应可能缓存 300 秒；收到响应不代表上游价格刚刚变化。
/// 文档：https://docs.li.fi/api-reference/fetch-information-about-a-token
enum LiFiAPI {
    private static let client = LiFiClient()

    static func resolve(address: String) async throws -> [CoinCandidate] {
        try await client.resolve(address: address)
    }

    /// chainId 使用 DexScreener 链名；同时兼容 LI.FI 的编号和 sol。
    /// 只返回有限且大于零的美元价格，key 与现有 Coin.id 完全一致。
    /// 部分请求失败时保留已取得的价格；没有结果且有请求失败时抛错。
    static func prices(_ items: [(chainId: String, address: String)]) async throws -> [String: Double] {
        try await client.prices(items)
    }
}

// MARK: - 链名、响应模型

private enum LiFiChain: String, CaseIterable, Sendable {
    case ethereum, bsc, base, arbitrum, polygon, solana

    var apiID: String {
        switch self {
        case .ethereum: return "1"
        case .bsc: return "56"
        case .base: return "8453"
        case .arbitrum: return "42161"
        case .polygon: return "137"
        case .solana: return "sol"
        }
    }

    init?(identifier: String) {
        switch identifier.lowercased() {
        case "ethereum", "eth", "1": self = .ethereum
        case "bsc", "56": self = .bsc
        case "base", "8453": self = .base
        case "arbitrum", "arb", "42161": self = .arbitrum
        case "polygon", "137": self = .polygon
        case "solana", "sol", "1151111081099710": self = .solana
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .ethereum: return "Ethereum"
        case .bsc: return "BNB Chain"
        case .base: return "Base"
        case .arbitrum: return "Arbitrum"
        case .polygon: return "Polygon"
        case .solana: return "Solana"
        }
    }

    func normalizedAddress(_ value: String) -> String? {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if self == .solana {
            let base58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
            guard (32...44).contains(address.count), address.allSatisfy({ base58.contains($0) }) else { return nil }
            return address // Solana 地址严格区分大小写。
        }
        guard address.lowercased().hasPrefix("0x"), address.count == 42,
              address.dropFirst(2).allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { return nil }
        return address.lowercased()
    }
}

private struct LiFiToken: Decodable, Sendable {
    let address: String
    let chainId: String
    let symbol: String
    let name: String?
    let priceUSD: Double?
    let logoURI: String?

    enum CodingKeys: String, CodingKey { case address, chainId, symbol, name, priceUSD, logoURI }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        address = try values.decode(String.self, forKey: .address)
        symbol = try values.decode(String.self, forKey: .symbol)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        logoURI = try values.decodeIfPresent(String.self, forKey: .logoURI)
        if let string = try? values.decode(String.self, forKey: .chainId) {
            chainId = string
        } else {
            chainId = String(try values.decode(Int64.self, forKey: .chainId))
        }
        let price: Double?
        if let string = try? values.decode(String.self, forKey: .priceUSD) {
            price = Double(string)
        } else {
            price = try? values.decode(Double.self, forKey: .priceUSD)
        }
        priceUSD = price.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    func coin(on chain: LiFiChain) -> Coin {
        let displaySymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let icon = logoURI.flatMap { value -> String? in
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            return value
        }
        return Coin(symbol: displaySymbol, name: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? displaySymbol,
                    source: .dex(chainId: chain.rawValue, address: address), iconURL: icon)
    }
}

// MARK: - 缓存与请求调度

/// 所有静态调用共用一个 actor，使搜索和轮询共享缓存、限流及 429 冷却。
/// 可注入 URLSession，方便用 URLProtocol 验证异常和并发情形。
actor LiFiClient {
    private struct CacheEntry {
        let token: LiFiToken?
        let expiresAt: Date
    }

    private struct Query: Sendable {
        let chain: LiFiChain
        let address: String
        var key: String { "\(chain.rawValue):\(address)" }
    }

    private enum QueryResult: Sendable {
        case success(Int, LiFiToken?)
        case failure(Int, DexScreenerError)
        case cancelled
    }

    private let session: URLSession
    private let baseURL: URL
    private let requestSpacing: TimeInterval
    private var cache: [String: CacheEntry] = [:]
    private var nextRequestAt = Date.distantPast
    private var cooldownUntil = Date.distantPast
    private var recentRequests: [Date] = []

    init(session: URLSession? = nil,
         baseURL: URL = URL(string: "https://li.quest/v1/token")!,
         requestSpacing: TimeInterval = 0.65) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 20
            config.requestCachePolicy = .useProtocolCachePolicy
            config.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "CoinBar/1.0 (macOS)"]
            self.session = URLSession(configuration: config)
        }
        self.baseURL = baseURL
        // 每次出站请求至少相隔 650ms，任意一分钟最多约 93 次（含并发调用）。
        self.requestSpacing = max(0.65, requestSpacing)
    }

    func resolve(address: String) async throws -> [CoinCandidate] {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let chains: [LiFiChain] = address.lowercased().hasPrefix("0x")
            ? [.ethereum, .bsc, .base, .arbitrum, .polygon] : [.solana]
        let queries = chains.compactMap { chain in
            chain.normalizedAddress(address).map { Query(chain: chain, address: $0) }
        }
        let (tokens, errors) = try await queryAll(queries)
        let candidates = tokens.map { index, token in
            CoinCandidate(coin: token.coin(on: queries[index].chain), priceUSD: token.priceUSD,
                          liquidityUSD: nil, detail: "\(queries[index].chain.displayName) · LI.FI（约 5 分钟缓存）")
        }
        if candidates.isEmpty, let error = preferredError(errors) { throw error }
        return candidates
    }

    func prices(_ items: [(chainId: String, address: String)]) async throws -> [String: Double] {
        var seen = Set<String>()
        let queries = items.compactMap { item -> Query? in
            guard let chain = LiFiChain(identifier: item.chainId),
                  let address = chain.normalizedAddress(item.address) else { return nil }
            let query = Query(chain: chain, address: address)
            return seen.insert(query.key).inserted ? query : nil
        }
        let (tokens, errors) = try await queryAll(queries)
        var result: [String: Double] = [:]
        for (index, token) in tokens {
            if let price = token.priceUSD { result[token.coin(on: queries[index].chain).id] = price }
        }
        if result.isEmpty, let error = preferredError(errors) { throw error }
        return result
    }

    private func queryAll(_ queries: [Query]) async throws -> ([(Int, LiFiToken)], [DexScreenerError]) {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: QueryResult.self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask {
                    do { return .success(index, try await self.token(for: query)) }
                    catch is CancellationError { return .cancelled }
                    catch let error as DexScreenerError { return .failure(index, error) }
                    catch { return .failure(index, .unknown) }
                }
            }
            var tokens: [(Int, LiFiToken)] = []
            var errors: [(Int, DexScreenerError)] = []
            for try await result in group {
                try Task.checkCancellation()
                switch result {
                case .success(let index, let token):
                    if let token { tokens.append((index, token)) }
                case .failure(let index, let error): errors.append((index, error))
                case .cancelled: throw CancellationError()
                }
            }
            return (tokens.sorted { $0.0 < $1.0 }, errors.sorted { $0.0 < $1.0 }.map { $0.1 })
        }
    }

    private func preferredError(_ errors: [DexScreenerError]) -> DexScreenerError? {
        if errors.contains(.http(429)) { return .http(429) }
        if errors.contains(.network) { return .network }
        return errors.first
    }

    private func token(for query: Query) async throws -> LiFiToken? {
        try Task.checkCancellation()
        if let entry = cache[query.key], entry.expiresAt > Date() { return entry.token }
        guard cooldownUntil <= Date() else { throw DexScreenerError.http(429) }

        // 先预留时间再挂起，actor 重入时下一个请求会预留后续时间。
        let scheduledAt = max(Date(), nextRequestAt)
        nextRequestAt = scheduledAt.addingTimeInterval(requestSpacing)
        let delay = scheduledAt.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        guard cooldownUntil <= Date() else { throw DexScreenerError.http(429) }
        // 等待限流期间另一调用可能已填好缓存。
        if let entry = cache[query.key], entry.expiresAt > Date() { return entry.token }

        // Mac 睡眠恢复后，多个原定于睡眠期间发出的请求可能一起醒来。
        // 再按实际出站时间卡住滚动窗口，不能仅依赖预留的时间间隔。
        while true {
            try Task.checkCancellation()
            guard cooldownUntil <= Date() else { throw DexScreenerError.http(429) }
            let now = Date()
            recentRequests.removeAll { now.timeIntervalSince($0) >= 60 }
            if recentRequests.count < 95 {
                recentRequests.append(now)
                break
            }
            let wait = max(0.01, 60 - now.timeIntervalSince(recentRequests[0]))
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "chain", value: query.chain.apiID),
                                  URLQueryItem(name: "token", value: query.address)]
        guard let url = components?.url else { throw DexScreenerError.unknown }
        do {
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw DexScreenerError.network }
            if http.statusCode == 404 {
                cache[query.key] = CacheEntry(token: nil, expiresAt: Date().addingTimeInterval(60))
                return nil
            }
            if http.statusCode == 429 {
                let retryAfter = retryDelay(http.value(forHTTPHeaderField: "Retry-After"))
                cooldownUntil = max(cooldownUntil, Date().addingTimeInterval(retryAfter))
                throw DexScreenerError.http(429)
            }
            guard (200..<300).contains(http.statusCode) else { throw DexScreenerError.http(http.statusCode) }
            let token: LiFiToken
            do { token = try JSONDecoder().decode(LiFiToken.self, from: data) }
            catch { throw DexScreenerError.decoding }
            guard LiFiChain(identifier: token.chainId) == query.chain,
                  query.chain.normalizedAddress(token.address) == query.address,
                  !token.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DexScreenerError.decoding
            }
            let age = max(0, Double(http.value(forHTTPHeaderField: "Age") ?? "") ?? 0)
            cache[query.key] = CacheEntry(token: token, expiresAt: Date().addingTimeInterval(max(0, 300 - age)))
            // 顺手清理过期项，避免长期搜索大量地址使缓存无限增长。
            if cache.count > 512 { cache = cache.filter { $0.value.expiresAt > Date() } }
            return token
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw DexScreenerError.network
        } catch let error as DexScreenerError {
            throw error
        } catch {
            throw DexScreenerError.unknown
        }
    }

    private func retryDelay(_ header: String?) -> TimeInterval {
        if let header, let seconds = Double(header), seconds.isFinite { return max(60, seconds) }
        if let header {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return max(60, date.timeIntervalSinceNow) }
        }
        return 60
    }
}
