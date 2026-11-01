import AppKit
import Combine

/// 币种图标，多来源依次尝试，一个不行换下一个：
/// 内置图标（市值前 500，交易所币，大陆免网络）→ 磁盘缓存 → 数据源给的各个 logo 地址（Ave / DexScreener /
/// GeckoTerminal / LI.FI…，按顺序）→ Gate 图标 CDN（交易所币）→ 首字母彩色圆形占位图
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
        let remotes = remoteURLs(coin)
        if !remotes.isEmpty || isDex(coin) { fetch(remotes, key: key, to: file, coin: coin) }
        return placeholder(coin.symbol, size: size)
    }

    private func cacheKey(_ coin: Coin) -> String {
        coin.id.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
    }

    private func remoteURLs(_ coin: Coin) -> [URL] {
        var list: [URL] = coin.allIconURLs.compactMap { raw in
            guard var c = URLComponents(string: raw) else { return nil }
            // DexScreener 图片默认 800px，图标只需要 64px
            if c.host?.contains("dexscreener") == true {
                c.queryItems = [URLQueryItem(name: "width", value: "64"), URLQueryItem(name: "height", value: "64"),
                                URLQueryItem(name: "format", value: "png")]
            }
            return c.url
        }
        if case .cex(let sym) = coin.source,
           let gate = URL(string: "https://icon.gateimg.com/images/coin_icon/64/\(sym.lowercased()).png") {
            list.append(gate)
        }
        // 链上币：按链 + 地址推出公开图标库的地址。旧版本添加的币没存图标地址，也能用上
        if case .dex(let chain, let address) = coin.source {
            list += Self.derivedIconURLs(chain: chain, address: address).filter { !list.contains($0) }
        }
        // 大陆实测可直连的图标站排前面（海外同样可用），被墙的放后面，避免大陆用户每个币先等一轮超时
        let reachableInCN = ["iconaves.com", "static.debank.com"]
        let preferred = list.filter { u in reachableInCN.contains { u.host?.hasSuffix($0) == true } }
        return preferred + list.filter { !preferred.contains($0) }
    }

    private static func download(_ url: URL) async -> (Data, NSImage)? {
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Mozilla/5.0 CoinBar", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = NSImage(data: data), img.isValid else { return nil }
        return (data, img)
    }

    /// 不需要 key 的公开图标库（Ave 图标 CDN 大陆可直连；DexScreener 海外可用）
    static func derivedIconURLs(chain: String, address: String) -> [URL] {
        let isEVM = address.hasPrefix("0x")
        let addr = isEVM ? address.lowercased() : address      // Solana 地址区分大小写
        let aveNet: [String: String] = ["ethereum": "eth", "bsc": "bsc", "solana": "solana", "base": "base",
                                        "arbitrum": "arbitrum", "polygon": "polygon"]
        var out: [URL] = []
        if let net = aveNet[chain.lowercased()],
           let u = URL(string: "https://www.iconaves.com/token_icon/\(net)/\(addr).png") { out.append(u) }
        if let u = URL(string: "https://dd.dexscreener.com/ds-data/tokens/\(chain.lowercased())/\(addr).png") { out.append(u) }
        return out
    }

    /// 依次尝试每个地址，拿到第一张有效图片就停
    private func isDex(_ coin: Coin) -> Bool { if case .dex = coin.source { return true }; return false }

    private func fetch(_ urls: [URL], key: String, to file: URL, coin: Coin) {
        guard !inFlight.contains(key), !failed.contains(key) else { return }
        inFlight.insert(key)
        Task {
            var got: (Data, NSImage)?
            for url in urls {
                if let r = await Self.download(url) { got = r; break }
            }
            // 公开图标库都没有：后台打开 Ave 网页读图标地址（链上币才做，每个币成功一次后走磁盘缓存）
            if got == nil, case .dex(let chain, let address) = coin.source {
                let found: URL? = await withCheckedContinuation { cont in
                    Task { @MainActor in AveWebIcon.shared.lookup(chain: chain, address: address) { cont.resume(returning: $0) } }
                }
                if let found { got = await Self.download(found) }
            }
            await MainActor.run {
                self.inFlight.remove(key)
                if let (data, img) = got {
                    try? data.write(to: file)
                    self.memory[key] = img
                    self.version += 1
                } else {
                    self.failed.insert(key)   // 全部失败：本次运行不再重试，显示首字母占位
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
