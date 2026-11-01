import Foundation

enum AppConfig {
    /// GitHub 仓库（必须是公开仓库，App 才能匿名读取 Releases）
    static let githubOwner = "Lenka0605"
    static let githubRepo  = "CoinBar"

    /// Ave.ai 行情 API key（大陆可直连）。为空时自动跳过 Ave，走其他数据源
    static let aveAPIKey = ""

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
