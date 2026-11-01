# CoinBar — Mac 菜单栏实时币价

原生 Swift（SwiftPM，无需 Xcode 工程），macOS 13+，菜单栏常驻、不占 Dock。

## 数据源（大陆免翻墙优先，2026-11-01 用大陆电信/联通/移动节点实测）
大陆可直连：`api.gateio.ws`、`data-stream.binance.vision`、`data-api.binance.vision`、`api.github.com`
大陆不可用：api.binance.com / stream.binance.com / OKX / 火币 / Bitget / Bybit / CoinGecko / DexScreener / GeckoTerminal

| 场景 | 方案 | 刷新 |
|---|---|---|
| 默认 6 币及所有交易所上市币 | **主：Gate.io WebSocket** `wss://api.gateio.ws/ws/v4/` `spot.tickers`；**备：Binance 行情专用 WS** `wss://data-stream.binance.vision/ws` `<sym>usdt@miniTicker`。主源断了自动切备源，两边都要断线重连 | 推送 ~1 秒 |
| 输入合约地址 | **先查 Gate 币种表** `GET /api/v4/spot/currencies`（5600+ 币，其中 4900+ 带各链合约地址 `chains[].addr`，EVM 地址不区分大小写）→ 命中就走 Gate 实时推送；**没命中再查 DexScreener**（纯链上币，大陆需代理，UI 上提示） | 推送 / DEX 轮询 ~10 秒 |
| 只输入名称/符号 | 先在 Gate 币种表按 symbol / name 匹配；再补 DexScreener search 结果，按流动性排序让用户选 | 同上 |
| 自动更新 | api.github.com 大陆可用；github.com 附件下载约 3 成节点超时 → 自动重试 3 次 | — |

## 分工（各改各的目录，不碰别人的）
- Claude：`Package.swift`、`Sources/CoinBar/Core/*`、`Sources/CoinBar/UI/*`、`scripts/*`，整体集成/打包
- ChatGPT：`Sources/CoinBar/CEX/*` —— `CEXProvider: PriceProvider`（Gate WS 主 + Binance vision WS 备 + 断线重连）；`CEXSearch`（缓存 Gate 币种表到 ~/Library/Caches，24h 刷新）：`lookup(symbol:) async -> CoinCandidate?`、`lookup(address:) async -> [CoinCandidate]`、`search(query:) async -> [CoinCandidate]`
- DeepSeek：`Sources/CoinBar/DEX/*` —— `DEXProvider: PriceProvider`（DexScreener 每地址单独请求，每轮最多 20 个轮转，~120 次/分）+ `DEXSearch.resolve(address:) async -> [CoinCandidate]`、`DEXSearch.search(query:) async -> [CoinCandidate]`；请求失败要能区分「网络不通」（大陆被墙）并抛出明确错误，UI 好提示用户开代理

接口定义见 `Sources/CoinBar/Core/Models.swift`，要改接口先在群里说。

## 自动更新（Claude 负责）
- 发布在 GitHub Releases（公开仓库 `Lenka0605/CoinBar`），tag `vX.Y.Z`，附件 `CoinBar-X.Y.Z.zip`
- App 启动时 + 每 6 小时静默检查；菜单里有「检查更新」，有新版显示「立即更新」→ 下载 → 解压 → 校验 bundle id → 替换自身并重启
- 发版：`scripts/release.sh 1.0.1 "更新说明"`
- 首次从浏览器下载需要右键「打开」绕过 Gatekeeper（未公证）；之后 App 内自更新不会再弹

## 多源兜底原则（老板 2026-11-01 定）
能接的数据源都接上，按顺序排，一个用不了自动换下一个。价格、图标都这样。
- 交易所币价格：Gate WS → Binance vision WS → Gate REST 每 60 秒补价
- 链上币价格：Ave（需 key，大陆可用）→ DexScreener（~10s）→ GeckoTerminal（~30s）→ LI.FI（大陆可用，~5 分钟缓存）→ BSC 读链（publicnode/drpc/1rpc，大陆可用，规划中）
- 图标：内置图标 → 磁盘缓存 → `Coin.iconURL` + `Coin.altIconURLs` 依次尝试（Ave iconaves.com 大陆可用 / DexScreener / GeckoTerminal / LI.FI）→ Gate CDN → 首字母占位
- Ave key 放在 `AppConfig.aveAPIKey`，为空时自动跳过 Ave
