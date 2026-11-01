import Foundation

/// BSC / PancakeSwap V2 的最后一层读价兜底，不需要 key，不发送交易。
/// 接口与 LiFiAPI 一致；只处理 chainId=bsc（同时兼容 56）。
/// 使用储备比计算现货参考价：USDT 近似美元，WBNB 用 Gate BNB_USDT 换算。
/// 不提供 24h 涨跌和图标；不覆盖其它链、V3 或其它 DEX。
/// Factory：https://developer.pancakeswap.finance/contracts/v2/factory-v2
/// Pair：https://github.com/pancakeswap/pancake-swap-core/blob/master/contracts/PancakePair.sol
enum ChainRPC {
    static let endpoints = ["https://bsc-rpc.publicnode.com", "https://bsc.drpc.org", "https://1rpc.io/bnb"]
        .map { URL(string: $0)! }
    static let factory = "0xca143ce32fe78f1f7019d7d551a6402fc5350c73"
    static let usdt = "0x55d398326f99059ff775485246999027b3197955"
    static let wbnb = "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c"
    private static let client = ChainRPCClient()

    static func resolve(address: String) async throws -> [CoinCandidate] {
        try await client.resolve(address: address)
    }

    static func prices(_ items: [(chainId: String, address: String)]) async throws -> [String: Double] {
        try await client.quotes(items).mapValues(\.priceUSD)
    }

    /// 调用方需要流动性、所读区块或时间时使用这一入口。
    static func quotes(_ items: [(chainId: String, address: String)]) async throws -> [String: ChainRPCQuote] {
        try await client.quotes(items)
    }
}

struct ChainRPCQuote {
    let coin: Coin
    let priceUSD: Double
    let liquidityUSD: Double
    /// 读到这一快照的时间；不是最后一笔交易发生的时间。
    let timestamp: Date
    let blockNumber: String
    let pairAddress: String
    let quoteSymbol: String
    var change24h: Double? { nil }
}

/// 搜索与轮询共用 10 秒内存快照，失败不返回过期缓存。
/// session / endpoints 可注入，用来验证节点故障、ABI 和精度。
actor ChainRPCClient {
    private struct CachedQuote {
        let value: ChainRPCQuote?
        let expires: Date
    }
    private struct Metadata {
        let decimals: Int
        let symbol: String
        let name: String
    }
    private struct Pool {
        let address: String
        let quote: String
        let tokenReserve: Double
        let quoteReserve: Double
    }
    private struct Operation {
        let method: String
        let params: [Any]
        static func call(to: String, data: String, block: String) -> Self {
            Self(method: "eth_call", params: [["to": to, "data": data], block])
        }
    }
    private struct Reply: Decodable {
        let jsonrpc: String
        let id: Int
        let result: String?
        let error: RPCError?
        struct RPCError: Decodable {
            let code: Int
            let message: String
        }
        func value() throws -> String {
            if let error {
                if error.message.lowercased().contains("revert") { throw Fault.contract }
                if error.code == -32005 || error.message.lowercased().contains("rate limit") {
                    throw DexScreenerError.http(429)
                }
                throw DexScreenerError.unknown
            }
            guard let result else { throw DexScreenerError.decoding }
            return result
        }
    }
    private enum Fault: Error { case contract }

    private let endpoints: [URL]
    private let session: URLSession
    private let gateURL: URL
    private let requestInterval: TimeInterval
    private var cache: [String: CachedQuote] = [:]
    private var bnbPrice: (price: Double, at: Date)?
    private var nextRequests: [URL: Date] = [:]
    private var cooldowns: [URL: Date] = [:]

    init(endpoints: [URL] = ChainRPC.endpoints, session: URLSession? = nil,
         gateURL: URL = URL(string: "https://api.gateio.ws/api/v4/spot/tickers?currency_pair=BNB_USDT")!,
         requestInterval: TimeInterval = 1) {
        self.endpoints = endpoints
        self.gateURL = gateURL
        self.requestInterval = max(0, requestInterval)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 4
            config.timeoutIntervalForResource = 8
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "CoinBar/1.0 (macOS)"]
            self.session = URLSession(configuration: config)
        }
    }

    func resolve(address: String) async throws -> [CoinCandidate] {
        guard let address = Self.address(address), let quote = try await quote(address: address) else { return [] }
        return [CoinCandidate(coin: quote.coin, priceUSD: quote.priceUSD, liquidityUSD: quote.liquidityUSD,
                              detail: "BNB Chain · PancakeSwap V2（链上读价）")]
    }

    func quotes(_ items: [(chainId: String, address: String)]) async throws -> [String: ChainRPCQuote] {
        try Task.checkCancellation()
        var seen = Set<String>()
        let addresses = items.compactMap { item -> String? in
            guard ["bsc", "56"].contains(item.chainId.lowercased()), let address = Self.address(item.address),
                  seen.insert(address).inserted else { return nil }
            return address
        }
        var results: [String: ChainRPCQuote] = [:]
        var errors: [DexScreenerError] = []
        // 顺序读取，避免几十个币同时向公共 RPC 节点发请求。
        for address in addresses {
            try Task.checkCancellation()
            do {
                if let quote = try await quote(address: address) { results[quote.coin.id] = quote }
            } catch is CancellationError { throw CancellationError() }
            catch { errors.append(Self.externalError(error)) }
        }
        if results.isEmpty, let error = Self.preferredError(errors) { throw error }
        return results
    }

    private func quote(address: String) async throws -> ChainRPCQuote? {
        try Task.checkCancellation()
        if let entry = cache[address], entry.expires > Date() { return entry.value }
        var errors: [DexScreenerError] = []
        // 每次新快照都从主节点开始；一次快照内固定节点和区块，失败再整体换节点。
        for endpoint in endpoints {
            try Task.checkCancellation()
            do {
                let result = try await readQuote(address: address, endpoint: endpoint)
                cache[address] = CachedQuote(value: result, expires: Date().addingTimeInterval(result == nil ? 30 : 10))
                if cache.count > 256 { cache = cache.filter { $0.value.expires > Date() } }
                return result
            } catch is CancellationError { throw CancellationError() }
            catch { errors.append(Self.externalError(error)) }
        }
        throw Self.preferredError(errors) ?? DexScreenerError.network
    }

    private func readQuote(address: String, endpoint: URL) async throws -> ChainRPCQuote? {
        let head = try await batch([Operation(method: "eth_chainId", params: []),
                                    Operation(method: "eth_blockNumber", params: [])], endpoint: endpoint)
        guard try Self.quantity(head[0].value()) == 56 else { throw DexScreenerError.decoding }
        let block = try head[1].value()
        guard let blockNumber = Self.quantity(block), blockNumber > 0 else { throw DexScreenerError.decoding }
        let quotes = [ChainRPC.usdt, ChainRPC.wbnb].filter { $0 != address }
        let pairReplies = try await batch(quotes.map {
            .call(to: ChainRPC.factory, data: "0xe6a43905" + Self.addressWord(address) + Self.addressWord($0), block: block)
        }, endpoint: endpoint)
        var pairs: [(address: String, quote: String)] = []
        for (index, reply) in pairReplies.enumerated() {
            guard let pair = Self.abiAddress(try reply.value()) else { throw DexScreenerError.decoding }
            if pair != Self.zeroAddress { pairs.append((pair, quotes[index])) }
        }
        guard !pairs.isEmpty else { return nil }

        let meta = try await metadata(address: address, block: block, endpoint: endpoint)
        var pools: [Pool] = []
        var poolErrors: [DexScreenerError] = []
        for pair in pairs {
            do {
                if let pool = try await pool(address: pair.address, token: address, quote: pair.quote,
                                             decimals: meta.decimals, block: block, endpoint: endpoint) {
                    pools.append(pool)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { poolErrors.append(Self.externalError(error)) }
        }
        var priced: [(Pool, Double, Double)] = []
        for pool in pools {
            do {
                let quotePrice = pool.quote == ChainRPC.usdt ? 1.0 : try await gateBNBPrice()
                let price = pool.quoteReserve / pool.tokenReserve * quotePrice
                let liquidity = pool.quoteReserve * quotePrice * 2
                guard price.isFinite, price > 0, liquidity.isFinite, liquidity > 0 else { continue }
                priced.append((pool, price, liquidity))
            } catch is CancellationError { throw CancellationError() }
            catch { poolErrors.append(Self.externalError(error)) }
        }
        guard let best = priced.max(by: { $0.2 < $1.2 }) else {
            if let error = Self.preferredError(poolErrors) { throw error }
            return nil // 无池子 / 空储备不能当成 0 美元。
        }
        let coin = Coin(symbol: meta.symbol, name: meta.name, source: .dex(chainId: "bsc", address: address))
        return ChainRPCQuote(coin: coin, priceUSD: best.1, liquidityUSD: best.2, timestamp: Date(),
                             blockNumber: block, pairAddress: best.0.address,
                             quoteSymbol: best.0.quote == ChainRPC.usdt ? "USDT" : "WBNB")
    }

    private func metadata(address: String, block: String, endpoint: URL) async throws -> Metadata {
        let replies = try await batch(["0x313ce567", "0x95d89b41", "0x06fdde03"].map {
            .call(to: address, data: $0, block: block)
        }, endpoint: endpoint)
        // decimals 是计算价格所必需的；缺少它时绝不能猜成 18。
        guard let raw = Self.words(try replies[0].value()), raw.count == 1,
              let decimals = Self.smallInteger(raw[0]), (0...255).contains(decimals) else {
            throw DexScreenerError.decoding
        }
        // ERC20 的 name / symbol 是可选方法，兼容 string 和老式 bytes32。
        let symbol = (try? replies[1].value()).flatMap(Self.abiString) ?? "\(address.prefix(6))…\(address.suffix(4))"
        let name = (try? replies[2].value()).flatMap(Self.abiString) ?? symbol
        return Metadata(decimals: decimals, symbol: symbol, name: name)
    }

    private func pool(address: String, token: String, quote: String, decimals: Int,
                      block: String, endpoint: URL) async throws -> Pool? {
        let replies = try await batch(["0x0dfe1681", "0xd21220a7", "0x0902f1ac"].map {
            .call(to: address, data: $0, block: block)
        }, endpoint: endpoint)
        guard let token0 = Self.abiAddress(try replies[0].value()),
              let token1 = Self.abiAddress(try replies[1].value()),
              (token0 == token && token1 == quote) || (token1 == token && token0 == quote),
              let reserves = Self.words(try replies[2].value()), reserves.count == 3,
              reserves[0].prefix(36).allSatisfy({ $0 == "0" }),
              reserves[1].prefix(36).allSatisfy({ $0 == "0" }) else { throw DexScreenerError.decoding }
        let reserve0 = Self.number(reserves[0]), reserve1 = Self.number(reserves[1])
        let tokenRaw = token0 == token ? reserve0 : reserve1
        let quoteRaw = token0 == token ? reserve1 : reserve0
        // BSC 的这两个固定计价合约都是 18 位，目标代币用其真实 decimals。
        let tokenReserve = tokenRaw / pow(10, Double(decimals))
        let quoteReserve = quoteRaw / 1e18
        guard tokenReserve.isFinite, quoteReserve.isFinite, tokenReserve > 0, quoteReserve > 0 else { return nil }
        return Pool(address: address, quote: quote, tokenReserve: tokenReserve, quoteReserve: quoteReserve)
    }

    /// 每批最多三条：实测 drpc 免费节点拒绝大于三条的 JSON-RPC batch。
    private func batch(_ operations: [Operation], endpoint: URL) async throws -> [Reply] {
        guard !operations.isEmpty, operations.count <= 3 else { throw DexScreenerError.unknown }
        // 公共节点对短时连发也会限流。每个节点每秒最多一批，最多三条调用。
        while true {
            try Task.checkCancellation()
            guard (cooldowns[endpoint] ?? .distantPast) <= Date() else { throw DexScreenerError.http(429) }
            let wait = (nextRequests[endpoint] ?? .distantPast).timeIntervalSinceNow
            if wait <= 0 {
                nextRequests[endpoint] = Date().addingTimeInterval(requestInterval)
                break
            }
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        let payload: [[String: Any]] = operations.enumerated().map {
            ["jsonrpc": "2.0", "id": $0.offset + 1, "method": $0.element.method, "params": $0.element.params]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await send(request)
        let replies: [Reply]
        do { replies = try JSONDecoder().decode([Reply].self, from: data) }
        catch { throw DexScreenerError.decoding }
        guard replies.count == operations.count,
              Set(replies.map(\.id)) == Set(1...operations.count),
              replies.allSatisfy({ $0.jsonrpc == "2.0" }) else { throw DexScreenerError.decoding }
        return replies.sorted { $0.id < $1.id } // 节点可以乱序返回 batch 结果。
    }

    private func gateBNBPrice() async throws -> Double {
        if let cached = bnbPrice, Date().timeIntervalSince(cached.at) < 15 { return cached.price }
        let data = try await send(URLRequest(url: gateURL))
        struct Ticker: Decodable {
            let currency_pair: String
            let last: String
        }
        let tickers: [Ticker]
        do { tickers = try JSONDecoder().decode([Ticker].self, from: data) }
        catch { throw DexScreenerError.decoding }
        guard let ticker = tickers.first(where: { $0.currency_pair == "BNB_USDT" }),
              let price = Double(ticker.last), price.isFinite, price > 0 else { throw DexScreenerError.decoding }
        bnbPrice = (price, Date())
        return price
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        if let url = request.url, (cooldowns[url] ?? .distantPast) > Date() { throw DexScreenerError.http(429) }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw DexScreenerError.network }
            if http.statusCode == 429, let url = request.url {
                let raw = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
                cooldowns[url] = Date().addingTimeInterval(raw.isFinite ? max(60, raw) : 60)
            }
            guard (200..<300).contains(http.statusCode) else { throw DexScreenerError.http(http.statusCode) }
            guard data.count <= 1_048_576 else { throw DexScreenerError.decoding }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw DexScreenerError.network
        }
    }

    // MARK: - 只读 ABI 解码（无需第三方大整数或 Web3 库）

    private static let zeroAddress = "0x" + String(repeating: "0", count: 40)

    private static func address(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 42, value.hasPrefix("0x"), value != zeroAddress,
              value.dropFirst(2).allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }

    private static func addressWord(_ address: String) -> String { String(repeating: "0", count: 24) + address.dropFirst(2) }

    private static func hex(_ value: String) -> String? {
        guard value.hasPrefix("0x"), value.count <= 131_074 else { return nil }
        let raw = String(value.dropFirst(2)).lowercased()
        guard raw.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return raw
    }

    private static func quantity(_ value: String) -> UInt64? {
        guard let raw = hex(value), !raw.isEmpty else { return nil }
        return UInt64(raw, radix: 16)
    }

    private static func words(_ value: String) -> [String]? {
        guard let raw = hex(value), !raw.isEmpty, raw.count % 64 == 0 else { return nil }
        let bytes = Array(raw)
        return stride(from: 0, to: bytes.count, by: 64).map { String(bytes[$0..<($0 + 64)]) }
    }

    private static func abiAddress(_ value: String) -> String? {
        guard let words = words(value), words.count == 1,
              words[0].prefix(24).allSatisfy({ $0 == "0" }) else { return nil }
        return "0x" + words[0].suffix(40)
    }

    private static func smallInteger(_ word: String) -> Int? { Int(word, radix: 16) }

    private static func number(_ word: String) -> Double {
        word.reduce(0) { $0 * 16 + Double($1.hexDigitValue!) }
    }

    private static func abiString(_ value: String) -> String? {
        guard let raw = hex(value), raw.count >= 64 else { return nil }
        let chars = Array(raw)
        let payload: ArraySlice<Character>
        if chars.count == 64 { payload = chars[...] }
        else {
            guard let parsed = words(value), let offset = smallInteger(parsed[0]), offset >= 32,
                  offset % 32 == 0, offset <= (chars.count / 2) - 32,
                  let length = smallInteger(String(chars[(offset * 2)..<(offset * 2 + 64)])),
                  (1...256).contains(length), offset + 32 + length <= chars.count / 2 else { return nil }
            payload = chars[((offset + 32) * 2)..<((offset + 32 + length) * 2)]
        }
        let encoded = Array(payload)
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: encoded.count, by: 2) {
            guard let byte = UInt8(String(encoded[index...index + 1]), radix: 16) else { return nil }
            if byte == 0 { break }
            bytes.append(byte)
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
        let result = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return result
    }

    private static func externalError(_ error: Error) -> DexScreenerError {
        (error as? DexScreenerError) ?? .unknown
    }

    private static func preferredError(_ errors: [DexScreenerError]) -> DexScreenerError? {
        if errors.contains(.network) { return .network }
        if errors.contains(.http(429)) { return .http(429) }
        return errors.first
    }
}
