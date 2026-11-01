import AppKit
import Foundation

/// 基于 GitHub Releases 的自更新：
/// 1. 查 releases/latest，tag 形如 v1.2.0，附件里要有 CoinBar-*.zip（内含 CoinBar.app）
/// 2. 比版本号，有新版就下载 → 解压 → 校验 bundle id → 后台脚本等本进程退出后替换 .app 并重启
/// 用 URLSession 下载的文件不会带隔离属性，所以不签名公证也能直接替换运行。
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release {
        let version: String
        let notes: String
        let zipURLs: [URL]   // 按顺序尝试
        let pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String)
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var latest: Release?
    private var progressObs: NSKeyValueObservation?

    // MARK: 检查更新
    func check(silent: Bool = false) async {
        if case .downloading = state { return }
        if state == .installing { return }
        state = .checking
        do {
            let rel = try await fetchLatest()
            latest = rel
            if Self.compare(rel.version, AppConfig.currentVersion) == .orderedDescending {
                state = .available(version: rel.version, notes: rel.notes)
            } else {
                state = silent ? .idle : .upToDate
            }
        } catch {
            state = silent ? .idle : .failed("检查更新失败：\(error.localizedDescription)")
        }
    }

    private func fetchLatest() async throws -> Release {
        let api = URL(string: "https://api.github.com/repos/\(AppConfig.githubOwner)/\(AppConfig.githubRepo)/releases/latest")!
        var req = URLRequest(url: api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CoinBar/\(AppConfig.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.msg("无响应") }
        if http.statusCode == 404 { throw UpdateError.msg("还没有发布任何版本") }
        guard http.statusCode == 200 else { throw UpdateError.msg("GitHub 返回 \(http.statusCode)") }

        struct Asset: Decodable { let name: String; let url: URL; let browser_download_url: URL }
        struct GHRelease: Decodable { let tag_name: String; let body: String?; let html_url: URL; let assets: [Asset] }
        let r = try JSONDecoder().decode(GHRelease.self, from: data)
        guard let zip = r.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw UpdateError.msg("新版本没有附带安装包")
        }
        let ver = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        // 先走 api.github.com 的附件接口（大陆实测 10/10 可达），再走 github.com 直链（约 7/10）
        return Release(version: ver, notes: r.body ?? "", zipURLs: [zip.url, zip.browser_download_url], pageURL: r.html_url)
    }

    // MARK: 下载并安装
    func downloadAndInstall() async {
        guard let rel = latest else { return }
        state = .downloading(progress: 0)
        do {
            // 两个地址轮流试，共 4 次
            var zipFile: URL?
            var lastErr: Error?
            for attempt in 1...4 {
                let url = rel.zipURLs[(attempt - 1) % rel.zipURLs.count]
                do { zipFile = try await download(url); break }
                catch { lastErr = error; state = .downloading(progress: 0)
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            }
            guard let zipFile else { throw lastErr ?? UpdateError.msg("下载失败") }
            state = .installing
            let newApp = try unzip(zipFile)
            try install(newApp)
        } catch {
            state = .failed("更新失败：\(error.localizedDescription)")
        }
    }

    func openReleasePage() {
        if let url = latest?.pageURL { NSWorkspace.shared.open(url) }
    }

    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            req.setValue("CoinBar/\(AppConfig.currentVersion)", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.downloadTask(with: req) { tmp, resp, err in
                if let err { cont.resume(throwing: err); return }
                guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    cont.resume(throwing: UpdateError.msg("下载失败")); return
                }
                // 临时文件回调结束就会被删，先挪走
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("CoinBar-update-\(UUID().uuidString).zip")
                do { try FileManager.default.moveItem(at: tmp, to: dest); cont.resume(returning: dest) }
                catch { cont.resume(throwing: error) }
            }
            progressObs = task.progress.observe(\.fractionCompleted) { p, _ in
                Task { @MainActor in
                    if case .downloading = self.state { self.state = .downloading(progress: p.fractionCompleted) }
                }
            }
            task.resume()
        }
    }

    private func unzip(_ zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoinBar-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.msg("安装包里没找到 .app")
        }
        guard let newID = Bundle(url: app)?.bundleIdentifier, newID == Bundle.main.bundleIdentifier else {
            throw UpdateError.msg("安装包校验失败（bundle id 不匹配）")
        }
        return app
    }

    private func install(_ newApp: URL) throws {
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else {
            throw UpdateError.msg("当前不是以 .app 方式运行，无法自动替换")
        }
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            throw UpdateError.msg("没有权限写入 \(parent.path)，已在访达中打开新版本，请手动拖入替换")
        }
        // 后台脚本：等当前进程退出 → 替换 → 去隔离属性 → 重新打开
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(current.path).old"
        mv "\(current.path)" "\(current.path).old" && \
        mv "\(newApp.path)" "\(current.path)" && rm -rf "\(current.path).old" || \
        { [ -d "\(current.path).old" ] && [ ! -d "\(current.path)" ] && mv "\(current.path).old" "\(current.path)"; }
        xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null
        open "\(current.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.msg("\(exe) 退出码 \(p.terminationStatus)") }
        return p.terminationStatus
    }

    /// 语义化版本比较："1.10.0" > "1.9.3"
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    enum UpdateError: LocalizedError {
        case msg(String)
        var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
    }
}
