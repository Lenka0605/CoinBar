import AppKit
import WebKit

/// 最后一招：在后台用系统 WebKit 打开 Ave 的币种页面（和用户自己用浏览器打开一样），
/// 等页面渲染完，读出这个币的图标地址。不调用 Ave 的内部接口、不处理它的 token，页面自己完成。
/// 注意：ave.ai 在中国大陆被墙，大陆网络下这一步会失败（拿到的图标会缓存，海外/代理下拿一次即可）。
@MainActor
final class AveWebIcon: NSObject, WKNavigationDelegate {
    static let shared = AveWebIcon()

    private var queue: [(chain: String, address: String, done: (URL?) -> Void)] = []
    private var busy = false
    private var webView: WKWebView?

    private static let aveChain: [String: String] = ["ethereum": "eth", "bsc": "bsc", "solana": "solana",
                                                     "base": "base", "arbitrum": "arbitrum", "polygon": "polygon"]

    func lookup(chain: String, address: String, done: @escaping (URL?) -> Void) {
        guard Self.aveChain[chain.lowercased()] != nil else { done(nil); return }
        queue.append((chain, address, done))
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        let net = Self.aveChain[job.chain.lowercased()]!
        let addr = job.address.hasPrefix("0x") ? job.address.lowercased() : job.address
        guard let url = URL(string: "https://ave.ai/token/\(addr)-\(net)") else { finish(job.done, nil); return }

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView = wv
        wv.load(URLRequest(url: url, timeoutInterval: 15))

        // 页面是前端渲染的：每秒查一次 <img>，最多等 15 秒
        let js = """
        (() => {
          const a = '\(addr.lowercased())';
          const srcs = [...document.querySelectorAll('img')].map(i => i.src || '');
          const hit = srcs.find(s => s.includes('iconaves.com') && s.toLowerCase().includes(a))
                   || srcs.find(s => s.includes('iconaves.com/token_icon_request/'));
          return hit || '';
        })()
        """
        poll(wv, js: js, triesLeft: 15, done: job.done)
    }

    private func poll(_ wv: WKWebView, js: String, triesLeft: Int, done: @escaping (URL?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            wv.evaluateJavaScript(js) { result, _ in
                MainActor.assumeIsolated {
                    if let s = result as? String, !s.isEmpty, let u = URL(string: s) {
                        self.finish(done, u)
                    } else if triesLeft > 1 {
                        self.poll(wv, js: js, triesLeft: triesLeft - 1, done: done)
                    } else {
                        self.finish(done, nil)
                    }
                }
            }
        }
    }

    private func finish(_ done: (URL?) -> Void, _ url: URL?) {
        webView?.stopLoading()
        webView = nil
        busy = false
        done(url)
        next()
    }
}
