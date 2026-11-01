import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store = PriceStore.shared
    @State private var query = ""
    @State private var searching = false
    @State private var result = CoinResolver.Result()
    @State private var searched = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            addSection
            Divider()
            listSection
            Divider()
            HStack {
                Toggle("菜单栏显示 24h 涨跌幅", isOn: $store.showChangeInBar)
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
                    .keyboardShortcut(.defaultAction)
            }
            Text("合约地址会自动识别所在链；交易所上市的币走实时推送（约 1 秒），纯链上币约 10 秒刷新。")
                .font(.caption).foregroundStyle(.secondary)

            if let notice = result.dexNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if searched && !searching && result.candidates.isEmpty && result.dexNotice == nil {
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

    private func search() {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        Task {
            let r = await CoinResolver.resolve(q)
            await MainActor.run { result = r; searching = false; searched = true }
        }
    }

    // MARK: 已关注
    private var listSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("我的币种").font(.headline)
                Spacer()
                Text("勾选的显示在菜单栏，可拖动排序").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(store.coins) { coin in
                    HStack {
                        Toggle("", isOn: Binding(get: { coin.showInMenuBar },
                                                 set: { _ in store.toggleMenuBar(coin.id) }))
                            .labelsHidden()
                        Text(coin.symbol).fontWeight(.semibold).frame(width: 64, alignment: .leading)
                        Text(sourceText(coin)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if let t = store.prices[coin.id] {
                            Text("$" + Fmt.price(t.priceUSD)).monospacedDigit()
                            Text(Fmt.change(t.change24h)).monospacedDigit().frame(width: 64, alignment: .trailing)
                                .foregroundStyle((t.change24h ?? 0) >= 0 ? .green : .red)
                        } else {
                            Text("连接中…").foregroundStyle(.secondary)
                        }
                        Button { store.remove(coin.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private func sourceText(_ coin: Coin) -> String {
        switch coin.source {
        case .cex: return coin.name + " · 交易所实时"
        case .dex(let chain, _): return coin.name + " · " + DexCandidates.chainDisplayName(chain) + " 链上"
        }
    }
}
