import AppKit
import Combine

/// 币种图标：
/// 1. 交易所币：App 内置图标（市值前 500，大陆免网络）→ 磁盘缓存 → 在线拉 Gate 图标 CDN（大陆被墙，海外可用）
/// 2. 链上币：Coin.iconURL（DexScreener 提供）→ 磁盘缓存
/// 3. 都没有：按代号首字母生成彩色圆形占位图
@MainActor
final class CoinIcons: ObservableObject {
    static let shared = CoinIcons()

    /// 有新图标加载完成时 +1，界面据此刷新
    @Published private(set) var version = 0

    private var memory: [String: NSImage] = [:]
    private var inFlight = Set<String>()
    private var failed = Set<String>()

    private let bundledDir: URL? = {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("CoinIcons"),
           FileManager.default.fileExists(atPath: r.path) { return r }
        // swift run 调试时从项目目录读
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/CoinIcons")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }()

    private let cacheDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoinBar/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 同步返回一个可用图标（可能是占位图），真图标加载好后 version 变化
    func image(for coin: Coin, size: CGFloat = 16) -> NSImage {
        let key = cacheKey(coin)
        if let img = memory[key] { return sized(img, size) }

        if case .cex(let sym) = coin.source,
           let url = bundledDir?.appendingPathComponent("\(sym.uppercased()).png"),
           let img = NSImage(contentsOf: url) {
            memory[key] = img
            return sized(img, size)
        }
        let file = cacheDir.appendingPathComponent(key + ".png")
        if let img = NSImage(contentsOf: file) {
            memory[key] = img
            return sized(img, size)
        }
        if let remote = remoteURL(coin) { fetch(remote, key: key, to: file) }
        return placeholder(coin.symbol, size: size)
    }

    private func cacheKey(_ coin: Coin) -> String {
        coin.id.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
    }

    private func remoteURL(_ coin: Coin) -> URL? {
        if let s = coin.iconURL, let u = URL(string: s) { return u }
        if case .cex(let sym) = coin.source {
            return URL(string: "https://icon.gateimg.com/images/coin_icon/64/\(sym.lowercased()).png")
        }
        return nil
    }

    private func fetch(_ url: URL, key: String, to file: URL) {
        guard !inFlight.contains(key), !failed.contains(key) else { return }
        inFlight.insert(key)
        Task {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("Mozilla/5.0 CoinBar", forHTTPHeaderField: "User-Agent")
            let data = try? await URLSession.shared.data(for: req).0
            await MainActor.run {
                self.inFlight.remove(key)
                if let data, let img = NSImage(data: data), img.isValid {
                    try? data.write(to: file)
                    self.memory[key] = img
                    self.version += 1
                } else {
                    self.failed.insert(key)   // 本次运行不再重试（大陆网络下避免反复超时）
                }
            }
        }
    }

    private func sized(_ img: NSImage, _ size: CGFloat) -> NSImage {
        let out = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            img.draw(in: rect)
            return true
        }
        return out
    }

    private var placeholders: [String: NSImage] = [:]

    /// 首字母占位图，颜色由代号决定（同一个币颜色固定）
    func placeholder(_ symbol: String, size: CGFloat) -> NSImage {
        let k = "\(symbol)@\(size)"
        if let p = placeholders[k] { return p }
        let hue = CGFloat(symbol.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let letter = String(symbol.trimmingCharacters(in: CharacterSet(charactersIn: "$")).prefix(1)).uppercased()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.55, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let s = NSAttributedString(string: letter, attributes: attrs)
            let b = s.size()
            s.draw(at: NSPoint(x: rect.midX - b.width / 2, y: rect.midY - b.height / 2))
            return true
        }
        placeholders[k] = img
        return img
    }
}
