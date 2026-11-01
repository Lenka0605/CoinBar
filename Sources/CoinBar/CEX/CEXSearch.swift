import Foundation

enum CEXSearch {
    static func lookup(symbol input: String) async -> CoinCandidate? {
        await lookup(symbol: input, catalog: .shared)
    }

    static func lookup(address: String) async -> [CoinCandidate] {
        await lookup(address: address, catalog: .shared)
    }

    static func search(query: String) async -> [CoinCandidate] {
        await search(query: query, catalog: .shared)
    }

    // 可注入独立缓存，方便验证网络错误、缓存过期和地址匹配，不污染用户缓存。
    static func lookup(symbol input: String, catalog: GateCatalog,
                       tickers: GateTickerCache = .shared) async -> CoinCandidate? {
        guard !Task.isCancelled, let symbol = CEXSymbol.normalize(input),
              let snapshot = await catalog.snapshot(), !Task.isCancelled,
              let row = snapshot.tradableCurrencies.first(where: { $0.currency.uppercased() == symbol && isAllowed($0) }) else { return nil }
        return await priced([candidate(row)], using: tickers).first
    }

    static func lookup(address input: String, catalog: GateCatalog,
                       tickers: GateTickerCache = .shared) async -> [CoinCandidate] {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !Task.isCancelled,
              let snapshot = await catalog.snapshot(), !Task.isCancelled else { return [] }
        let evm = isEVMAddress(address)
        var results: [CoinCandidate] = []
        for row in snapshot.tradableCurrencies where isAllowed(row) {
            let matches = (row.chains ?? []).filter { chain in
                guard let raw = chain.addr else { return false }
                let contract = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return evm ? contract.lowercased() == address.lowercased() : contract == address
            }
            if !matches.isEmpty {
                let chains = matches.map { $0.name ?? "合约已匹配" }
                // 每个币只返回一个候选，多条链放进说明，避免重复添加同一现货交易对。
                results.append(candidate(row, matchedChains: chains))
            }
        }
        return await priced(sortedUnique(results), using: tickers)
    }

    static func search(query input: String, catalog: GateCatalog,
                       tickers: GateTickerCache = .shared) async -> [CoinCandidate] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !Task.isCancelled,
              let snapshot = await catalog.snapshot(), !Task.isCancelled else { return [] }
        let normalized = CEXSymbol.normalize(query) ?? query.uppercased()
        let rows = snapshot.tradableCurrencies.filter {
            isAllowed($0) && ($0.currency.localizedCaseInsensitiveContains(normalized)
                || ($0.name?.localizedCaseInsensitiveContains(query) ?? false))
        }.sorted {
            let left = rank($0, query: query, symbol: normalized)
            let right = rank($1, query: query, symbol: normalized)
            return left == right ? $0.currency < $1.currency : left < right
        }
        var seen: Set<String> = []
        let results = rows.compactMap { row -> CoinCandidate? in
            let result = candidate(row)
            return seen.insert(result.id).inserted ? result : nil
        }
        return await priced(results, using: tickers)
    }

    private static func isAllowed(_ row: GateCurrency) -> Bool {
        let symbol = row.currency.uppercased()
        // 部分 5L/5S 产品的链仍填 ETH，后缀与虚拟链任一命中都排除。
        return !["3L", "3S", "5L", "5S"].contains(where: symbol.hasSuffix)
            && row.chain?.uppercased() != "ITSNOTACHAIN"
            && !(row.chains ?? []).contains { $0.name?.uppercased() == "ITSNOTACHAIN" }
    }

    private static func priced(_ candidates: [CoinCandidate], using tickers: GateTickerCache) async -> [CoinCandidate] {
        guard !candidates.isEmpty, !Task.isCancelled else { return [] }
        let prices = await tickers.prices()
        guard !Task.isCancelled else { return [] }
        return candidates.map {
            CoinCandidate(coin: $0.coin, priceUSD: prices[$0.coin.symbol], liquidityUSD: $0.liquidityUSD,
                          detail: $0.detail)
        }
    }

    private static func rank(_ row: GateCurrency, query: String, symbol: String) -> Int {
        if row.currency.uppercased() == symbol { return 0 }
        if row.name?.caseInsensitiveCompare(query) == .orderedSame { return 1 }
        if row.currency.uppercased().hasPrefix(symbol) { return 2 }
        return 3
    }

    private static func candidate(_ row: GateCurrency, matchedChains: [String] = []) -> CoinCandidate {
        let chains = matchedChains.isEmpty ? (row.chains ?? []).compactMap(\.name) : matchedChains
        let displayChains = Array(Set(chains.map(chainName))).sorted()
        let suffix = displayChains.isEmpty ? "" : " · " + displayChains.joined(separator: "/")
        let symbol = row.currency.uppercased()
        let name = row.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoinCandidate(coin: Coin(symbol: symbol, name: name?.isEmpty == false ? name! : symbol,
                                        source: .cex(symbol: symbol)),
                             priceUSD: nil, liquidityUSD: nil,
                             detail: "Gate 现货 · \(symbol)/USDT\(suffix)")
    }

    private static func chainName(_ chain: String) -> String {
        let names = ["ETH": "Ethereum", "SOL": "Solana", "BSC": "BNB Chain",
                     "ARBEVM": "Arbitrum", "BASEEVM": "Base", "OPETH": "Optimism",
                     "MATIC": "Polygon", "TRX": "Tron", "AVAX_C": "Avalanche"]
        return names[chain.uppercased()] ?? chain
    }

    private static func isEVMAddress(_ address: String) -> Bool {
        address.count == 42 && address.lowercased().hasPrefix("0x")
            && address.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func sortedUnique(_ candidates: [CoinCandidate]) -> [CoinCandidate] {
        var seen: Set<String> = []
        return candidates.sorted { $0.coin.symbol < $1.coin.symbol }.filter { seen.insert($0.id).inserted }
    }
}

/// 搜索用的轻量快照：一次拉全量行情，短时间内的并发搜索共用请求。
/// 行情只放内存并保留 5 秒；失败时保留候选、留空价格，不把旧价冒充当前价。
actor GateTickerCache {
    static let shared = GateTickerCache()
    private let session: URLSession
    private let now: () -> Date
    private let ttl: TimeInterval
    private var cached: [String: Double] = [:]
    private var fetchedAt: Date = .distantPast
    private var retryAfter: Date = .distantPast
    private var inFlight: Task<[String: Double], Error>?

    init(session: URLSession = .shared, ttl: TimeInterval = 5, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.ttl = ttl
        self.now = now
    }

    func prices() async -> [String: Double] {
        let date = now()
        if date >= fetchedAt, date.timeIntervalSince(fetchedAt) < ttl { return cached }
        if let inFlight { return (try? await inFlight.value) ?? [:] }
        guard date >= retryAfter else { return [:] }
        let session = self.session
        let work = Task { try await Self.fetch(session: session) }
        inFlight = work
        do {
            let result = try await work.value
            cached = result
            fetchedAt = now()
            retryAfter = .distantPast
            inFlight = nil
            return result
        } catch {
            inFlight = nil
            retryAfter = now().addingTimeInterval(3)
            return [:]
        }
    }

    private static func fetch(session: URLSession) async throws -> [String: Double] {
        let url = URL(string: "https://api.gateio.ws/api/v4/spot/tickers")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw TickerError.invalid }
        var prices: [String: Double] = [:]
        for quote in try CEXWire.restQuotes(from: data, timestamp: Date()) {
            prices[quote.symbol] = quote.price
        }
        return prices
    }

    private enum TickerError: Error { case invalid }
}
