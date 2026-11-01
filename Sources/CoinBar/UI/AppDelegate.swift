import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var settingsWindow: NSWindow?
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 调试：COINBAR_RESOLVE="PEPE" 打印搜索结果后退出
        if let q = ProcessInfo.processInfo.environment["COINBAR_RESOLVE"] {
            Task {
                let r = await CoinResolver.resolve(q)
                print("notice:", r.dexNotice ?? "-")
                for c in r.candidates.prefix(8) {
                    print(c.coin.id, c.coin.symbol, c.coin.name, "|", c.detail, "|", c.priceUSD ?? -1, c.liquidityUSD ?? -1)
                }
                if ProcessInfo.processInfo.environment["COINBAR_SUBSCRIBE"] != nil {
                    let picks = Array(r.candidates.prefix(2)).map(\.coin)
                    picks.forEach { PriceStore.shared.add($0) }
                    PriceStore.shared.start()
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    picks.forEach { PriceStore.shared.remove($0.id) }
                }
                exit(0)
            }
            return
        }
        MainMenu.install()
        PriceStore.shared.start()
        statusBar = StatusBarController()
        statusBar.openSettings = { [weak self] in self?.showSettings() }

        if ProcessInfo.processInfo.environment["COINBAR_OPEN_SETTINGS"] != nil { showSettings() }
        // 调试：COINBAR_SELFUPDATE=1 启动即检查并自动安装更新（用于验证自更新链路）
        if ProcessInfo.processInfo.environment["COINBAR_SELFUPDATE"] != nil {
            Task {
                await Updater.shared.check()
                print("update state:", Updater.shared.state)
                if case .available = Updater.shared.state { await Updater.shared.downloadAndInstall() }
                print("update state:", Updater.shared.state)
            }
        }
        // 启动 5 秒后静默检查一次，之后每 6 小时一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Task { await Updater.shared.check(silent: true) } }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { await Updater.shared.check(silent: true) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { PriceStore.shared.stop() }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "CoinBar 设置"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
