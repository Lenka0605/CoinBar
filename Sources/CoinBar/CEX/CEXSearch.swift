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
    static func lookup(symbol input: String, catalog: GateCatalog) async -> CoinCandidate? {
        guard !Task.isCancelled, let symbol = CEXSymbol.normalize(input),
              let snapshot = await catalog.snapshot(), !Task.isCancelled,
              let row = snapshot.tradableCurrencies.first(where: { $0.currency.uppercased() == symbol }) else { return nil }
        return candidate(row)
    }

    static func lookup(address input: String, catalog: GateCatalog) async -> [CoinCandidate] {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !Task.isCancelled,
              let snapshot = await catalog.snapshot(), !Task.isCancelled else { return [] }
        let evm = isEVMAddress(address)
        var results: [CoinCandidate] = []
        for row in snapshot.tradableCurrencies {
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
        return sortedUnique(results)
    }

    static func search(query input: String, catalog: GateCatalog) async -> [CoinCandidate] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !Task.isCancelled,
              let snapshot = await catalog.snapshot(), !Task.isCancelled else { return [] }
        let normalized = CEXSymbol.normalize(query) ?? query.uppercased()
        let rows = snapshot.tradableCurrencies.filter {
            $0.currency.localizedCaseInsensitiveContains(normalized)
                || ($0.name?.localizedCaseInsensitiveContains(query) ?? false)
        }.sorted {
            let left = rank($0, query: query, symbol: normalized)
            let right = rank($1, query: query, symbol: normalized)
            return left == right ? $0.currency < $1.currency : left < right
        }
        var seen: Set<String> = []
        return rows.compactMap { row in
            let result = candidate(row)
            return seen.insert(result.id).inserted ? result : nil
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
