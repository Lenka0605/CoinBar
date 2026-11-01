import Foundation

enum Fmt {
    private static let subscripts: [Character] = ["₀","₁","₂","₃","₄","₅","₆","₇","₈","₉"]

    /// 价格显示：
    /// ≥1000 → 77,958 ；1~1000 → 95.24 ；0.01~1 → 0.07575（4 位有效数字，去尾零）
    /// 0.0001~0.01 → 0.002345（4 位有效数字）；更小 → 0.0₅2938（下标表示小数点后连续 0 的个数）
    static func price(_ v: Double) -> String {
        let a = abs(v)
        if a == 0 { return "0" }
        if a >= 1000 { return decimal(v, maxFrac: 0) }
        if a >= 1 { return decimal(v, minFrac: 2, maxFrac: 2) }
        if a >= 0.01 {                                  // 4 位有效数字，去尾零：0.07575、0.5
            let f = NumberFormatter()
            f.locale = Locale(identifier: "en_US")
            f.usesSignificantDigits = true
            f.maximumSignificantDigits = 4
            return f.string(from: NSNumber(value: v)) ?? "\(v)"
        }
        // 小数点后连续 0 的个数
        var zeros = Int(ceil(-log10(a))) - 1
        var sig = Int((a * pow(10, Double(zeros + 4))).rounded())     // 4 位有效数字
        if sig >= 10000 { zeros -= 1; sig = Int((a * pow(10, Double(zeros + 4))).rounded()) }
        if sig < 1000 { zeros += 1; sig = Int((a * pow(10, Double(zeros + 4))).rounded()) }
        var digits = String(sig)
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
        let sign = v < 0 ? "-" : ""
        if zeros < 4 { return sign + "0." + String(repeating: "0", count: zeros) + digits }
        let sub = String(String(zeros).map { subscripts[Int(String($0))!] })
        return sign + "0.0" + sub + digits
    }

    private static func decimal(_ v: Double, minFrac: Int = 0, maxFrac: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = minFrac
        f.maximumFractionDigits = maxFrac
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
