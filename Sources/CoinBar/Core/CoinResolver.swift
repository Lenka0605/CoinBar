import Foundation

/// 「添加币种」：交易所结果优先（实时推送、大陆可直连），再补链上 DEX 结果
enum CoinResolver {
    struct Result {
        var candidates: [CoinCandidate] = []
        /// DEX 查询失败的提示（如大陆网络连不上 DexScreener）
        var dexNotice: String?
    }

    static func resolve(_ raw: String) async -> Result {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return Result() }
        let isAddress = DEXSearch.looksLikeContractAddress(input)

        async let cexHits: [CoinCandidate] = cexSearch(input, isAddress: isAddress)
        async let dexHits: Swift.Result<[CoinCandidate], Error> = dexSearch(input, isAddress: isAddress)

        var result = Result()
        let cexList = await cexHits
        result.candidates = cexList
        switch await dexHits {
        case .success(let list):
            let seen = Set(cexList.map(\.id))
            result.candidates += list.filter { !seen.contains($0.id) }
        case .failure(let err):
            result.dexNotice = notice(err, cexFound: !cexList.isEmpty)
        }
        return result
    }

    /// 交易所部分（Gate 本地缓存，通常秒回）
    static func cex(_ input: String) async -> [CoinCandidate] {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return await cexSearch(q, isAddress: DEXSearch.looksLikeContractAddress(q))
    }

    /// 链上部分；返回 (结果, 提示)。大陆无代理时可能要十几秒才失败，界面不要等它
    static func dex(_ input: String, cexFound: Bool) async -> ([CoinCandidate], String?) {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await dexSearch(q, isAddress: DEXSearch.looksLikeContractAddress(q)) {
        case .success(let list): return (list, nil)
        case .failure(let err): return ([], notice(err, cexFound: cexFound))
        }
    }

    private static func notice(_ err: Error, cexFound: Bool) -> String {
        if (err as? DexScreenerError) == .network {
            return cexFound ? "链上数据源 DexScreener 连不上（中国大陆需代理），只显示了交易所结果。"
                            : "交易所里没找到；链上数据源 DexScreener 连不上（中国大陆需开代理）。"
        }
        return "链上搜索失败：\(err.localizedDescription)"
    }

    private static func cexSearch(_ input: String, isAddress: Bool) async -> [CoinCandidate] {
        if isAddress { return await CEXSearch.lookup(address: input) }
        var list = await CEXSearch.search(query: input)
        if list.isEmpty, let exact = await CEXSearch.lookup(symbol: input) { list = [exact] }
        return list
    }

    private static func dexSearch(_ input: String, isAddress: Bool) async -> Swift.Result<[CoinCandidate], Error> {
        do {
            return .success(isAddress ? try await DEXSearch.resolve(address: input)
                                      : try await DEXSearch.search(query: input))
        } catch { return .failure(error) }
    }
}
