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
    private var styleItems: [(NSMenuItem, () -> Bool)] = []
    // 轮播
    private var rotateTimer: Timer?
    private var rotateCurrent: String?
    private var rotateQueue: [String] = []
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
        Publishers.CombineLatest3(store.$rotateSeconds, store.$rotateRandom, store.$rotateCheckedOnly)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.restartRotation(); self?.refreshStyleItems() }
            }.store(in: &bag)
        Publishers.Merge3(store.$showChangeInBar, store.$showIconInBar, store.$showSymbolInBar)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshTitle(); self?.refreshStyleItems() }
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
        let shown: [Coin]
        if store.rotateSeconds > 0 {
            let pool = rotationPool()
            let cur = pool.first { $0.id == rotateCurrent } ?? pool.first
            shown = cur.map { [$0] } ?? []
        } else {
            shown = Array(store.coins.filter(\.showInMenuBar).prefix(PriceStore.maxInMenuBar))
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        let small = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let out = NSMutableAttributedString()
        if shown.isEmpty {
            out.append(NSAttributedString(string: "₿", attributes: [.font: font]))
        }
        for (i, coin) in shown.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            if store.showIconInBar {
                let att = NSTextAttachment()
                att.image = CoinIcons.shared.image(for: coin, size: 14)
                att.bounds = CGRect(x: 0, y: -2.5, width: 14, height: 14)
                out.append(NSAttributedString(attachment: att))
                out.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            let tick = store.prices[coin.id]
            let stale = store.isStale(coin)
            let price = tick.map { "$" + Fmt.price($0.priceUSD) } ?? "--"
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if stale { attrs[.foregroundColor] = NSColor.tertiaryLabelColor }
            out.append(NSAttributedString(string: store.showSymbolInBar ? "\(coin.symbol) \(price)" : price,
                                          attributes: attrs))
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
        // 菜单栏显示样式：一级菜单直接勾选
        let styleMenu = NSMenu()
        styleItems = []
        for (title, sel, get) in [
            ("显示图标", #selector(toggleIcon), { [unowned self] in self.store.showIconInBar }),
            ("显示币种代号", #selector(toggleSymbol), { [unowned self] in self.store.showSymbolInBar }),
            ("显示 24h 涨跌幅", #selector(toggleChange), { [unowned self] in self.store.showChangeInBar }),
        ] as [(String, Selector, () -> Bool)] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            styleMenu.addItem(mi)
            styleItems.append((mi, get))
        }
        styleMenu.addItem(.separator())
        let rotTitle = NSMenuItem(title: "轮播", action: nil, keyEquivalent: ""); rotTitle.isEnabled = false
        styleMenu.addItem(rotTitle)
        let rotOptions: [(String, Int)] = [("不轮播（显示勾选的币）", 0)] + PriceStore.rotateOptions.map { ("每 \($0) 秒换一个", $0) }
        for (title, sec) in rotOptions {
            let mi = NSMenuItem(title: title, action: #selector(setRotate(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = sec; mi.indentationLevel = 1
            styleMenu.addItem(mi)
            styleItems.append((mi, { [unowned self] in self.store.rotateSeconds == sec }))
        }
        styleMenu.addItem(.separator())
        for (title, sel, get) in [
            ("按列表顺序", #selector(rotateSequential), { [unowned self] in !self.store.rotateRandom }),
            ("随机顺序", #selector(rotateRandomOrder), { [unowned self] in self.store.rotateRandom }),
            ("轮播全部币种", #selector(rotateAll), { [unowned self] in !self.store.rotateCheckedOnly }),
            ("只轮播勾选的币", #selector(rotateChecked), { [unowned self] in self.store.rotateCheckedOnly }),
        ] as [(String, Selector, () -> Bool)] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self; mi.indentationLevel = 1
            styleMenu.addItem(mi)
            styleItems.append((mi, get))
        }
        let styleRoot = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        styleRoot.submenu = styleMenu
        menu.addItem(styleRoot)
        refreshStyleItems()
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
    private func refreshStyleItems() {
        for (mi, get) in styleItems { mi.state = get() ? .on : .off }
    }
    @objc private func toggleIcon() { store.showIconInBar.toggle() }
    @objc private func toggleSymbol() { store.showSymbolInBar.toggle() }
    @objc private func toggleChange() { store.showChangeInBar.toggle() }
    @objc private func setRotate(_ sender: NSMenuItem) { store.rotateSeconds = sender.tag }
    @objc private func rotateSequential() { store.rotateRandom = false }
    @objc private func rotateRandomOrder() { store.rotateRandom = true }
    @objc private func rotateAll() { store.rotateCheckedOnly = false }
    @objc private func rotateChecked() { store.rotateCheckedOnly = true }

    // MARK: 轮播
    /// 参与轮播的币：全部，或只勾选的（一个都没勾就退回全部）
    private func rotationPool() -> [Coin] {
        if store.rotateCheckedOnly {
            let checked = store.coins.filter(\.showInMenuBar)
            if !checked.isEmpty { return checked }
        }
        return store.coins
    }

    private func restartRotation() {
        rotateTimer?.invalidate(); rotateTimer = nil
        rotateQueue = []
        refreshTitle()
        guard store.rotateSeconds > 0 else { return }
        let t = Timer(timeInterval: TimeInterval(store.rotateSeconds), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceRotation() }
        }
        RunLoop.main.add(t, forMode: .common)   // 菜单展开时也继续轮播
        rotateTimer = t
    }

    private func advanceRotation() {
        let pool = rotationPool().map(\.id)
        guard pool.count > 1 else { rotateCurrent = pool.first; refreshTitle(); return }
        if store.rotateRandom {
            // 洗牌一轮放完再洗下一轮，保证每个币都轮到；新一轮第一个不与刚显示的重复
            rotateQueue.removeAll { !pool.contains($0) }
            if rotateQueue.isEmpty {
                rotateQueue = pool.shuffled()
                if rotateQueue.first == rotateCurrent { rotateQueue.append(rotateQueue.removeFirst()) }
            }
            rotateCurrent = rotateQueue.removeFirst()
        } else {
            let i = rotateCurrent.flatMap { pool.firstIndex(of: $0) } ?? -1
            rotateCurrent = pool[(i + 1) % pool.count]
        }
        refreshTitle()
    }

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
