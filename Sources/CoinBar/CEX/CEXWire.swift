import Foundation
import CoreFoundation

/// USDT 现货报价近似记作 USD；不包含 USDT/USD 的汇率转换。
enum CEXExchange {
    case gate, binance

    var webSocketURL: URL {
        switch self {
        case .gate: return URL(string: "wss://api.gateio.ws/ws/v4/")!
        case .binance: return URL(string: "wss://data-stream.binance.vision/ws")!
        }
    }

    func subscription(symbols: [String], subscribe: Bool, id: Int) -> [String: Any] {
        switch self {
        case .gate:
            return ["time": Int(Date().timeIntervalSince1970), "id": id,
                    "channel": "spot.tickers", "event": subscribe ? "subscribe" : "unsubscribe",
                    "payload": symbols.map { $0 + "_USDT" }]
        case .binance:
            return ["method": subscribe ? "SUBSCRIBE" : "UNSUBSCRIBE",
                    "params": symbols.map { $0.lowercased() + "usdt@miniTicker" }, "id": id]
        }
    }
}

enum CEXSymbol {
    static func normalize(_ input: String) -> String? {
        var symbol = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if symbol.hasPrefix("$") { symbol.removeFirst() }
        for suffix in ["/USDT", "-USDT", "_USDT"] where symbol.hasSuffix(suffix) {
            symbol.removeLast(suffix.count)
        }
        guard !symbol.isEmpty, symbol.count <= 40,
              symbol.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else { return nil }
        return symbol
    }
}

struct CEXQuote {
    let symbol: String
    let price: Double
    let change24h: Double?
    let timestamp: Date
}

enum CEXWire {
    static func restQuotes(from data: Data, timestamp: Date) throws -> [CEXQuote] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw WireError.invalidPayload
        }
        return rows.compactMap { row in
            guard let pair = row["currency_pair"] as? String, pair.hasSuffix("_USDT"),
                  !pair.dropLast(5).isEmpty, let price = number(row["last"]), price > 0 else { return nil }
            return CEXQuote(symbol: String(pair.dropLast(5)), price: price,
                            change24h: number(row["change_percentage"]), timestamp: timestamp)
        }
    }

    static func quotes(from object: [String: Any], exchange: CEXExchange) -> [CEXQuote] {
        switch exchange {
        case .gate:
            guard object["channel"] as? String == "spot.tickers", object["event"] as? String == "update",
                  let row = object["result"] as? [String: Any],
                  let pair = row["currency_pair"] as? String, pair.hasSuffix("_USDT"),
                  let price = number(row["last"]), price > 0 else { return [] }
            let seconds = number(object["time_ms"]).map { $0 / 1000 } ?? number(object["time"])
            guard let seconds, seconds > 0, !pair.dropLast(5).isEmpty else { return [] }
            return [CEXQuote(symbol: String(pair.dropLast(5)), price: price,
                             change24h: number(row["change_percentage"]),
                             timestamp: Date(timeIntervalSince1970: seconds))]
        case .binance:
            let row = object["data"] as? [String: Any] ?? object
            guard row["e"] as? String == "24hrMiniTicker",
                  let pair = row["s"] as? String, pair.hasSuffix("USDT"),
                  let quote = quote(row, symbol: String(pair.dropLast(4)),
                                    priceKey: "c", openKey: "o", timeKey: "E") else { return [] }
            return [quote]
        }
    }

    static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let text = value as? String { result = Double(text) }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            result = number.doubleValue
        } else { result = nil }
        guard let result, result.isFinite else { return nil }
        return result
    }

    private static func quote(_ row: [String: Any], symbol: String,
                              priceKey: String, openKey: String, timeKey: String) -> CEXQuote? {
        guard !symbol.isEmpty, let price = number(row[priceKey]), price > 0,
              let milliseconds = number(row[timeKey]), milliseconds > 0 else { return nil }
        var change: Double?
        if let open = number(row[openKey]), open > 0 {
            let percent = (price / open - 1) * 100
            if percent.isFinite { change = percent }
        }
        return CEXQuote(symbol: symbol, price: price, change24h: change,
                        timestamp: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    private enum WireError: Error { case invalidPayload }
}
