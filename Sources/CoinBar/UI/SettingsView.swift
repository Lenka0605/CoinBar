import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store = PriceStore.shared
    @ObservedObject var icons = CoinIcons.shared
    @State private var query = ""
    @State private var searching = false
    @State private var result = CoinResolver.Result()
    @State private var searched = false
    @State private var dexLoading = false
    @State private var searchSeq = 0
    @State private var limitHint = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            addSection
            Divider()
            listSection
            Divider()
            HStack(spacing: 14) {
                Text("菜单栏显示：")
                Toggle("图标", isOn: $store.showIconInBar)
                Toggle("代号", isOn: $store.showSymbolInBar)
                Toggle("24h 涨跌幅", isOn: $store.showChangeInBar)
                Spacer()
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            .font(.callout)
        }
        .padding(18)
        .frame(width: 520, height: 600)
        // 窗口是复用的：每次重新成为前台窗口时，同步一下系统里的开机启动状态
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: 添加
    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("添加币种").font(.headline)
            HStack {
                TextField("输入币名 / 代号（如 PEPE）或粘贴合约地址", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button(searching ? "搜索中…" : "搜索", action: search)
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("合约地址会自动识别所在链；交易所上市的币走实时推送（约 1 秒），纯链上币约 10 秒刷新。")
                .font(.caption).foregroundStyle(.secondary)

            if let notice = result.dexNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if dexLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在搜索链上 DEX…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if searched && !searching && !dexLoading && result.candidates.isEmpty && result.dexNotice == nil {
                Text("没有找到匹配的币").font(.caption).foregroundStyle(.secondary)
            }
            if !result.candidates.isEmpty {
                List(result.candidates) { c in candidateRow(c) }
                    .frame(height: 170)
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
        }
    }

    private func candidateRow(_ c: CoinCandidate) -> some View {
        HStack {
            Image(nsImage: icons.image(for: c.coin, size: 24)).id(icons.version)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.coin.symbol).fontWeight(.semibold)
                    Text(c.coin.name).foregroundStyle(.secondary).lineLimit(1)
                    if case .cex = c.coin.source {
                        Text("实时").font(.caption2).padding(.horizontal, 4)
                            .background(Color.green.opacity(0.2)).cornerRadius(3)
                    }
                }
                HStack(spacing: 8) {
                    Text(c.detail)
                    if let liq = c.liquidityUSD { Text("流动性 \(Fmt.usd(liq))") }
                    if case .dex(_, let addr) = c.coin.source {
                        Text(addr.count > 14 ? "\(addr.prefix(6))…\(addr.suffix(4))" : addr)
                            .textSelection(.enabled)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = c.priceUSD { Text("$" + Fmt.price(p)).monospacedDigit() }
            if store.contains(c.coin.id) {
                Text("已添加").foregroundStyle(.secondary)
            } else {
                Button("添加") { store.add(c.coin) }
            }
        }
        .padding(.vertical, 2)
    }

    /// 先出交易所结果（本地缓存，秒回），链上结果回来再追加；序号用来丢弃过期的搜索
    private func search() {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty, !searching else { return }
        searchSeq += 1
        let seq = searchSeq
        searching = true
        dexLoading = true
        result = CoinResolver.Result()
        Task { @MainActor in
            let cexList = await CoinResolver.cex(q)
            guard seq == searchSeq else { return }
            result.candidates = cexList
            searching = false
            searched = true
            let (dexList, notice) = await CoinResolver.dex(q, cexFound: !cexList.isEmpty)
            guard seq == searchSeq else { return }
            let seen = Set(result.candidates.map(\.id))
            result.candidates += dexList.filter { !seen.contains($0.id) }
            result.dexNotice = notice
            dexLoading = false
        }
    }

    // MARK: 已关注
    private var listSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("我的币种").font(.headline)
                Spacer()
                Text(limitHint ? "菜单栏最多显示 \(PriceStore.maxInMenuBar) 个，先取消一个" : "勾选的显示在菜单栏（最多 \(PriceStore.maxInMenuBar) 个），可拖动排序")
                    .font(.caption).foregroundStyle(limitHint ? .orange : .secondary)
            }
            List {
                ForEach(store.coins) { coin in coinRow(coin) }
                .onMove { store.move(from: $0, to: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private func coinRow(_ coin: Coin) -> some View {
        let tick = store.prices[coin.id]
        let stale = store.isStale(coin)
        let up = (tick?.change24h ?? 0) >= 0
        let changeColor: Color = stale ? .secondary : (up ? .green : .red)
        return HStack {
            Toggle("", isOn: Binding(get: { coin.showInMenuBar },
                                     set: { _ in limitHint = !store.toggleMenuBar(coin.id) }))
                .labelsHidden()
            Image(nsImage: icons.image(for: coin, size: 20)).id(icons.version)
            Text(coin.symbol).fontWeight(.semibold).frame(width: 64, alignment: .leading)
            Text(sourceText(coin)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(tick.map { "$" + Fmt.price($0.priceUSD) } ?? "")
                .monospacedDigit()
                .foregroundStyle(stale ? Color.secondary : Color.primary)
                .frame(width: 100, alignment: .trailing)
            Text(tick == nil ? "连接中…" : (stale ? "已断开" : Fmt.change(tick?.change24h)))
                .monospacedDigit()
                .foregroundStyle(tick == nil ? Color.secondary : changeColor)
                .frame(width: 64, alignment: .trailing)
            Button { store.remove(coin.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }

    private func sourceText(_ coin: Coin) -> String {
        switch coin.source {
        case .cex: return coin.name + " · 交易所实时"
        case .dex(let chain, _): return coin.name + " · " + DexCandidates.chainDisplayName(chain) + " 链上"
        }
    }
}
