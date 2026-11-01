import Foundation

/// 添加链上代币时的两个查询入口。
///
/// 错误约定：
/// - 返回空数组 = 没找到这个币（或该地址在 DexScreener 上没有交易对），不是错误
/// - 抛 `DexScreenerError.network` = 连不上 DexScreener，多半需要代理
/// - 抛 `DexScreenerError.http(429)` = 请求太频繁
enum DEXSearch {
    /// 合约地址 → 识别是哪条链、什么币。结果按流动性从高到低。
    ///
    /// 依次尝试三个数据源：DexScreener → GeckoTerminal → LI.FI。
    /// 前两个在大陆被墙时，LI.FI 是能直连的兜底。
    /// 一个地址可能在多条链上都存在，所以返回的是候选列表，让用户确认。
    static func resolve(address: String) async throws -> [CoinCandidate] {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return [] }

        var lastError: DexScreenerError?

        // 1. DexScreener
        if let url = DexScreenerAPI.tokensURL(addresses: [addr]) {
            do {
                let response = try await DexScreenerAPI.get(url, as: DexResponse.self)
                let candidates = DexCandidates.build(from: response.pairs ?? [], limit: 25, onlyBaseAddress: addr)
                if !candidates.isEmpty { return withIconFallbacks(candidates) }
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as DexScreenerError {
                lastError = err
            } catch {
                lastError = .unknown
            }
        }

        // 2. GeckoTerminal
        let (geckoCandidates, geckoError) = try await resolveWithGeckoTerminal(address: addr)
        if !geckoCandidates.isEmpty { return withIconFallbacks(geckoCandidates) }
        if lastError == nil { lastError = geckoError }

        // 3. LI.FI（大陆可直连，约 5 分钟缓存）
        do {
            let candidates = try await LiFiAPI.resolve(address: addr)
            if !candidates.isEmpty { return withIconFallbacks(candidates) }
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as DexScreenerError {
            if lastError == nil { lastError = err }
        } catch {
            if lastError == nil { lastError = .unknown }
        }

        if let lastError { throw lastError }
        return []
    }

    private static func resolveWithGeckoTerminal(address: String) async throws -> ([CoinCandidate], DexScreenerError?) {
        guard let url = GeckoTerminalAPI.searchPoolsURL(query: address) else { return ([], nil) }
        do {
            let response = try await GeckoTerminalAPI.get(url, as: GTResponse<GTPool>.self)
            let candidates = GTCandidates.build(from: response.data ?? [], limit: 25, onlyBaseAddress: address)
            guard !candidates.isEmpty else { return ([], nil) }
            return (await GTCandidates.enriching(candidates), nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as DexScreenerError {
            return ([], err)
        } catch {
            return ([], .unknown)
        }
    }

    /// 按名称 / 代号搜链上代币，结果按流动性从高到低。
    ///
    /// 如果输入看起来像合约地址，会额外按地址精确查一遍并合并，
    /// 这样 UI 只调 search 也能处理粘贴地址的情况。
    static func search(query: String) async throws -> [CoinCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // 输入是合约地址时直接精确查询。模糊搜索会把「该地址作为计价货币」的池子
        // 也返回，那些池子的 base 是别的币，混进来会误导用户。
        if looksLikeContractAddress(q) {
            return try await resolve(address: q)
        }

        var candidates: [CoinCandidate] = []
        var firstError: DexScreenerError?

        if let url = DexScreenerAPI.searchURL(query: q) {
            do {
                let response = try await DexScreenerAPI.get(url, as: DexResponse.self)
                candidates = DexCandidates.build(from: response.pairs ?? [], limit: 30)
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as DexScreenerError {
                firstError = err
            } catch {
                firstError = .unknown
            }
        }

        // DexScreener 没搜到，再试 GeckoTerminal（收录更全）
        if candidates.isEmpty, let geckoURL = GeckoTerminalAPI.searchPoolsURL(query: q) {
            do {
                let response = try await GeckoTerminalAPI.get(geckoURL, as: GTResponse<GTPool>.self, maxAttempts: 2)
                let geckoCandidates = GTCandidates.build(from: response.data ?? [], limit: 30)
                if !geckoCandidates.isEmpty {
                    candidates = await GTCandidates.enriching(geckoCandidates)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil {
                    firstError = (error as? DexScreenerError) ?? .unknown
                }
            }
        }

        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.id).inserted }
        let sorted = unique.sorted { lhs, rhs in
            let l = lhs.liquidityUSD ?? 0
            let r = rhs.liquidityUSD ?? 0
            if l != r { return l > r }
            return lhs.coin.symbol < rhs.coin.symbol
        }

        // 一条结果都没有，且请求本身出错：把错误抛给界面（比如提示开代理）
        if sorted.isEmpty, let firstError {
            throw firstError
        }
        return withIconFallbacks(Array(sorted.prefix(30)))
    }

    /// 给链上候选补上多个图标地址，按优先顺序排：
    /// DexScreener → GeckoTerminal → LI.FI，Ave 的 CDN 放最后兜底（它不需要 key，大陆可直连）。
    /// CoinIcons 会依次尝试，前一个下载失败就换下一个。
    private static func withIconFallbacks(_ candidates: [CoinCandidate]) -> [CoinCandidate] {
        candidates.map { candidate in
            guard case .dex(let chainId, let address) = candidate.coin.source else { return candidate }
            // Solana 地址区分大小写，URL 里必须原样保留；EVM 地址用小写
            let pathAddress = chainId.lowercased() == "solana" ? address : address.lowercased()

            // (排序优先级, 原顺序, 地址)
            var urls: [(rank: Int, order: Int, url: String)] = []
            urls.append((0, 0, "https://dd.dexscreener.com/ds-data/tokens/\(chainId.lowercased())/\(pathAddress).png"))
            if let own = candidate.coin.iconURL {
                urls.append((iconRank(own), 1, own))
            }
            if let ave = aveIconURL(chainId: chainId, address: pathAddress) {
                urls.append((3, 2, ave))
            }

            let sorted = urls.sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.order < rhs.order
            }
            var seen = Set<String>()
            let unique = sorted.map(\.url).filter { !$0.isEmpty && seen.insert($0).inserted }
            guard !unique.isEmpty else { return candidate }

            var coin = candidate.coin
            coin.iconURL = unique.first
            coin.altIconURLs = unique.count > 1 ? Array(unique.dropFirst()) : nil
            return CoinCandidate(coin: coin, priceUSD: candidate.priceUSD,
                                 liquidityUSD: candidate.liquidityUSD, detail: candidate.detail)
        }
    }

    /// 数据源图标的优先级：DexScreener → GeckoTerminal → LI.FI 等
    private static func iconRank(_ url: String) -> Int {
        let lower = url.lowercased()
        if lower.contains("dexscreener") { return 0 }
        if lower.contains("geckoterminal") || lower.contains("coingecko") { return 1 }
        return 2
    }

    /// Ave 的图标 CDN，大陆实测可直连。链名对不上的不生成，避免无谓的下载尝试。
    private static func aveIconURL(chainId: String, address: String) -> String? {
        let network: String
        switch chainId.lowercased() {
        case "bsc": network = "bsc"
        case "ethereum": network = "eth"
        case "solana": network = "solana"
        case "polygon": network = "polygon"
        case "base": network = "base"
        case "arbitrum": network = "arbitrum"
        default: return nil
        }
        return "https://www.iconaves.com/token_icon/\(network)/\(address).png"
    }

    /// 0x 开头的 40 位十六进制（EVM），或 32~44 位 base58（Solana）视为合约地址
    static func looksLikeContractAddress(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x"), s.count == 42 {
            return s.dropFirst(2).allSatisfy { $0.isHexDigit }
        }
        if (32...44).contains(s.count) {
            let base58 = CharacterSet(charactersIn: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
            return s.unicodeScalars.allSatisfy { base58.contains($0) }
        }
        return false
    }
}
