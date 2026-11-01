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
            if (err as? DexScreenerError) == .network {
                result.dexNotice = cexList.isEmpty
                    ? "连不上链上数据源 DexScreener（中国大陆网络需开代理）。交易所里没找到这个币。"
                    : "链上数据源 DexScreener 连不上（中国大陆需代理），下面只显示交易所结果。"
            } else {
                result.dexNotice = "链上搜索失败：\(err.localizedDescription)"
            }
        }
        return result
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
