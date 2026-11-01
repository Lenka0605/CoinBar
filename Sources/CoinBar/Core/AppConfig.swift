import Foundation

enum AppConfig {
    /// GitHub 仓库（必须是公开仓库，App 才能匿名读取 Releases）
    static let githubOwner = "Lenka0605"
    static let githubRepo  = "CoinBar"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
