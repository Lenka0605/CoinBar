# CoinBar

Mac 菜单栏实时币价。默认 BTC / ETH / SOL / BNB / DOGE / XRP，可按名称或合约地址添加任意币种。

- **中国大陆免翻墙**：行情走 Gate.io 与 Binance 行情专用域名（大陆实测可直连），约 1 秒推送一次
- **自定义币种**：输入币名/代号，或粘贴合约地址自动识别所在链；交易所没上的链上币通过 DexScreener 获取（大陆需代理），约 10 秒刷新
- **一键更新**：菜单里「检查更新 / 立即更新」，自动下载安装并重启

## 安装
1. 在 [Releases](https://github.com/Lenka0605/CoinBar/releases/latest) 下载 `CoinBar-x.y.z.zip`，解压后把 `CoinBar.app` 拖进「应用程序」
2. 首次打开：右键 CoinBar.app →「打开」→ 再点「打开」（App 未经苹果公证，只需这一次）
3. 之后在菜单栏点击价格即可添加币种、设置开机启动、检查更新

系统要求：macOS 13 及以上，Apple 芯片与 Intel 均可。

## 开发
```bash
swift build                              # 编译
scripts/bundle.sh 1.0.0                  # 打包 dist/CoinBar.app + zip
scripts/release.sh 1.0.1 "更新说明"       # 打包并发布到 GitHub Releases
```
