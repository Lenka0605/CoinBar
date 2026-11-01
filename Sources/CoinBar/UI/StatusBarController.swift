import AppKit
import Combine

/// 菜单栏标题 + 下拉菜单
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let store = PriceStore.shared
    private let updater = Updater.shared
    private var bag = Set<AnyCancellable>()
    private var rowItems: [String: NSMenuItem] = [:]
    private var updateItem = NSMenuItem()
    private var menuOpen = false
    var openSettings: () -> Void = {}

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        rebuildMenu()
        refreshTitle()

        store.$prices.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshTitle()
            if self?.menuOpen == true { self?.refreshRows() }   // 菜单没打开就不重建行
        }.store(in: &bag)
        store.$coins.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu(); self?.refreshTitle() }
        }.store(in: &bag)
        store.$dexError.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu() }
        }.store(in: &bag)
        store.$showChangeInBar.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshTitle() }
        }.store(in: &bag)
        CoinIcons.shared.$version.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshTitle(); self?.refreshRows() }
        }.store(in: &bag)
        updater.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshUpdateItem() }
        }.store(in: &bag)
    }

    // MARK: 菜单栏标题
    private func refreshTitle() {
        guard let button = item.button else { return }
        let shown = store.coins.filter(\.showInMenuBar)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        let small = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let out = NSMutableAttributedString()
        if shown.isEmpty {
            out.append(NSAttributedString(string: "₿", attributes: [.font: font]))
        }
        for (i, coin) in shown.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            let att = NSTextAttachment()
            att.image = CoinIcons.shared.image(for: coin, size: 14)
            att.bounds = CGRect(x: 0, y: -2.5, width: 14, height: 14)
            out.append(NSAttributedString(attachment: att))
            out.append(NSAttributedString(string: " ", attributes: [.font: font]))
            let tick = store.prices[coin.id]
            let stale = store.isStale(coin)
            let price = tick.map { Fmt.price($0.priceUSD) } ?? "--"
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if stale { attrs[.foregroundColor] = NSColor.tertiaryLabelColor }
            out.append(NSAttributedString(string: "\(coin.symbol) \(price)", attributes: attrs))
            if store.showChangeInBar, !stale, let ch = tick?.change24h {
                out.append(NSAttributedString(string: " \(Fmt.change(ch))",
                    attributes: [.font: small, .foregroundColor: ch >= 0 ? NSColor.systemGreen : NSColor.systemRed]))
            }
        }
        button.attributedTitle = out
    }

    // MARK: 下拉菜单
    private func rebuildMenu() {
        menu.removeAllItems()
        rowItems.removeAll()

        let header = NSMenuItem(title: "点击币种可切换是否显示在菜单栏", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for coin in store.coins {
            let mi = NSMenuItem(title: coin.symbol, action: #selector(toggleCoin(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = coin.id
            rowItems[coin.id] = mi
            menu.addItem(mi)
        }
        refreshRows()

        if store.hasDexCoins, let err = store.dexError {
            let warn = NSMenuItem(title: err == .network ? "⚠︎ 链上数据源连不上（中国大陆需开代理）"
                                                         : "⚠︎ 链上数据源暂时不可用", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        menu.addItem(.separator())
        add("添加币种 / 管理…", #selector(showSettings), ",")
        menu.addItem(.separator())
        updateItem = add("检查更新", #selector(updateAction), "")
        refreshUpdateItem()
        let ver = NSMenuItem(title: "CoinBar v\(AppConfig.currentVersion)", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        add("退出", #selector(quit), "q")
    }

    @discardableResult
    private func add(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        menu.addItem(mi)
        return mi
    }

    private func refreshRows() {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 70),
                         NSTextTab(textAlignment: .right, location: 230),
                         NSTextTab(textAlignment: .right, location: 310)]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let gray = NSFont.systemFont(ofSize: 11)
        for coin in store.coins {
            guard let mi = rowItems[coin.id] else { continue }
            let tick = store.prices[coin.id]
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: coin.symbol, attributes: [.font: bold]))
            let tag: String
            if case .dex(let chain, _) = coin.source { tag = DexCandidates.chainDisplayName(chain) } else { tag = "" }
            s.append(NSAttributedString(string: "\t\(String((tag.isEmpty ? coin.name : tag).prefix(12)))",
                                        attributes: [.font: gray, .foregroundColor: NSColor.secondaryLabelColor]))
            let stale = store.isStale(coin)
            s.append(NSAttributedString(string: "\t$" + (tick.map { Fmt.price($0.priceUSD) } ?? "--"),
                attributes: [.font: font, .foregroundColor: stale ? NSColor.tertiaryLabelColor : NSColor.labelColor]))
            let ch = tick?.change24h
            let chText = tick == nil ? "连接中" : (stale ? "已断开" : Fmt.change(ch))
            s.append(NSAttributedString(string: "\t" + chText, attributes: [.font: stale ? gray : font,
                .foregroundColor: stale ? NSColor.secondaryLabelColor
                                        : ((ch ?? 0) >= 0 ? NSColor.systemGreen : NSColor.systemRed)]))
            s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
            mi.attributedTitle = s
            mi.image = CoinIcons.shared.image(for: coin, size: 18)
            mi.state = coin.showInMenuBar ? .on : .off
        }
    }

    private func refreshUpdateItem() {
        switch updater.state {
        case .idle, .upToDate, .failed: updateItem.title = "检查更新"; updateItem.isEnabled = true
        case .checking: updateItem.title = "正在检查更新…"; updateItem.isEnabled = false
        case .available(let v, _): updateItem.title = "⬆︎ 立即更新到 v\(v)"; updateItem.isEnabled = true
        case .downloading(let p): updateItem.title = "正在下载更新 \(Int(p * 100))%"; updateItem.isEnabled = false
        case .installing: updateItem.title = "正在安装…"; updateItem.isEnabled = false
        }
    }

    // MARK: 动作
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; refreshRows() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc private func toggleCoin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if !store.toggleMenuBar(id) {
            alert("菜单栏最多显示 \(PriceStore.maxInMenuBar) 个币", "先取消勾选一个，再勾选新的。")
        }
    }
    @objc private func showSettings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func updateAction() {
        Task { @MainActor in
            if case .available(let v, let notes) = updater.state {
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "发现新版本 v\(v)"
                a.informativeText = (notes.isEmpty ? "" : notes + "\n\n") + "更新会自动下载并重启 CoinBar。"
                a.addButton(withTitle: "立即更新")
                a.addButton(withTitle: "稍后")
                if a.runModal() == .alertFirstButtonReturn {
                    await updater.downloadAndInstall()
                    if case .failed(let m) = updater.state { alert("更新失败", m) }
                }
            } else {
                await updater.check()
                NSApp.activate(ignoringOtherApps: true)
                switch updater.state {
                case .upToDate: alert("已是最新版本", "当前版本 v\(AppConfig.currentVersion)")
                case .failed(let m): alert("检查更新失败", m)
                case .available: updateAction()
                default: break
                }
            }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}
