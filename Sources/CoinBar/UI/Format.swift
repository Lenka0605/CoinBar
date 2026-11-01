import Foundation

enum Fmt {
    /// 价格：≥1000 不带小数加千分位；≥1 两位小数；<1 保留 4 位有效数字
    static func price(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        switch abs(v) {
        case 1000...: f.maximumFractionDigits = 0
        case 1..<1000: f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        case 0: return "0"
        default:
            f.usesSignificantDigits = true
            f.maximumSignificantDigits = 4
            f.minimumSignificantDigits = 4
        }
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func change(_ v: Double?) -> String {
        guard let v else { return "" }
        return String(format: "%@%.2f%%", v >= 0 ? "+" : "", v)
    }

    static func usd(_ v: Double) -> String {
        switch v {
        case 1e9...: return String(format: "$%.2fB", v / 1e9)
        case 1e6...: return String(format: "$%.2fM", v / 1e6)
        case 1e3...: return String(format: "$%.1fK", v / 1e3)
        default: return String(format: "$%.0f", v)
        }
    }
}
