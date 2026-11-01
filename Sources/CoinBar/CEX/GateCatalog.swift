import Foundation

struct GateCurrency: Codable {
    let currency: String
    let name: String?
    let delisted: Bool?
    let trade_disabled: Bool?
    let chain: String?
    let chains: [Chain]?

    struct Chain: Codable {
        let name: String?
        let addr: String?
    }
}

struct GateCurrencyPair: Codable {
    let id: String
    let base: String
    let quote: String
    let trade_status: String
}

/// 币种表和可用交易对一并缓存，避免把已下架币或无 USDT 行情的币作为候选。
actor GateCatalog {
    static let shared = GateCatalog()

    struct Snapshot: Codable {
        let version: Int
        let fetchedAt: Date
        let currencies: [GateCurrency]
        let pairs: [GateCurrencyPair]

        var tradableCurrencies: [GateCurrency] {
            let symbols = Set(pairs.filter {
                $0.quote == "USDT" && $0.id == $0.base + "_USDT" && $0.trade_status == "tradable"
            }.map { $0.base.uppercased() })
            return currencies.filter {
                $0.delisted != true && $0.trade_disabled != true
                    && symbols.contains($0.currency.uppercased()) && CEXSymbol.normalize($0.currency) != nil
            }
        }
    }

    private let session: URLSession
    private let cacheURL: URL?
    private let now: () -> Date
    private let ttl: TimeInterval
    private let retryDelay: TimeInterval
    private var cached: Snapshot?
    private var readDisk = false
    private var inFlight: Task<Snapshot, Error>?
    private var retryAfter: Date = .distantPast

    init(session: URLSession = .shared, cacheURL: URL? = GateCatalog.defaultCacheURL,
         ttl: TimeInterval = 24 * 60 * 60, retryDelay: TimeInterval = 60,
         now: @escaping () -> Date = Date.init) {
        self.session = session
        self.cacheURL = cacheURL
        self.ttl = ttl
        self.retryDelay = retryDelay
        self.now = now
    }

    static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CoinBar", isDirectory: true)
            .appendingPathComponent("gate-catalog-v1.json")
    }

    func snapshot() async -> Snapshot? {
        if !readDisk {
            readDisk = true
            if let url = cacheURL, let data = try? Data(contentsOf: url), data.count <= 20_000_000,
               let stored = try? JSONDecoder().decode(Snapshot.self, from: data), stored.version == 1 {
                cached = stored
            }
        }
        let date = now()
        if let cached, date >= cached.fetchedAt, date.timeIntervalSince(cached.fetchedAt) < ttl { return cached }
        if let inFlight { return (try? await inFlight.value) ?? cached }
        guard date >= retryAfter else { return cached }

        let session = self.session
        let work = Task { try await Self.fetch(session: session, date: date) }
        inFlight = work
        do {
            let snapshot = try await work.value
            cached = snapshot
            inFlight = nil
            retryAfter = .distantPast
            if let url = cacheURL, let data = try? JSONEncoder().encode(snapshot) {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch { /* 只读文件系统或缓存不可写不影响本次查询。 */ }
            }
            return snapshot
        } catch {
            inFlight = nil
            retryAfter = now().addingTimeInterval(retryDelay)
            // 断网时沿用上次成功的目录；行情仍从实时连接获取。失败不会延长 24 小时有效期。
            return cached
        }
    }

    private static func fetch(session: URLSession, date: Date) async throws -> Snapshot {
        async let currencies: [GateCurrency] = get("currencies", session: session)
        async let pairs: [GateCurrencyPair] = get("currency_pairs", session: session)
        let snapshot = try await Snapshot(version: 1, fetchedAt: date, currencies: currencies, pairs: pairs)
        guard !snapshot.currencies.isEmpty, !snapshot.pairs.isEmpty else { throw CatalogError.empty }
        return snapshot
    }

    private static func get<T: Decodable>(_ resource: String, session: URLSession) async throws -> T {
        let url = URL(string: "https://api.gateio.ws/api/v4/spot/" + resource)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw CatalogError.http }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private enum CatalogError: Error { case http, empty }
}
