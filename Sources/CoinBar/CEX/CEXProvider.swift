import Foundation

/// Gate 优先；断线或单个币超过 12 秒未收到行情时，按币种补订 Binance 行情专用源。
/// Gate 在后台重连，恢复有效行情后自动移除对应的 Binance 订阅。
/// 启动/新增订阅时立即用 Gate REST 补价，之后每 60 秒全量核验一次。
/// REST 的 tick.timestamp 表示本次核验起点，并非该币最后一笔成交的时间。
/// 备用仅覆盖 Binance 已上市的现货交易对，界面可依据 tick.timestamp 标明陈旧行情。
/// 官方协议：github.com/binance/binance-spot-api-docs/blob/master/web-socket-streams.md
///          www.gate.com/docs/developers/apiv4/ws/en/
final class CEXProvider: PriceProvider {
    private let queue = DispatchQueue(label: "CoinBar.CEX")
    private let callbackLock = NSLock()
    private var callback: ((PriceTick) -> Void)?
    var onTick: ((PriceTick) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return callback }
        set { callbackLock.lock(); callback = newValue; callbackLock.unlock() }
    }

    private var coins: [String: Coin] = [:]
    private var lastPrimary: [String: TimeInterval] = [:]
    private var lastEmitted: [String: Date] = [:]
    private var subscriptions: [String: UUID] = [:]
    private var primaryFailed = false
    private var running = false
    private var timer: DispatchSourceTimer?
    private var snapshotTimer: DispatchSourceTimer?
    private var snapshotTask: URLSessionDataTask?
    private var snapshotRequestID: UUID?
    private var snapshotPending = false
    private let gateURL: URL
    private let binanceURL: URL
    private let restSession: URLSession
    private let snapshotInterval: TimeInterval
    private lazy var primary = makeSocket(.gate)
    private lazy var backup = makeSocket(.binance)

    init(gateURL: URL = CEXExchange.gate.webSocketURL,
         binanceURL: URL = CEXExchange.binance.webSocketURL,
         restSession: URLSession = .shared, snapshotInterval: TimeInterval = 60) {
        self.gateURL = gateURL
        self.binanceURL = binanceURL
        self.restSession = restSession
        self.snapshotInterval = max(0.1, snapshotInterval)
    }

    func setCoins(_ coins: [Coin]) {
        queue.async { [weak self] in
            guard let self else { return }
            var next: [String: Coin] = [:]
            for coin in coins {
                guard case .cex(let input) = coin.source,
                      let symbol = CEXSymbol.normalize(input) else { continue }
                next[symbol] = coin
            }
            let now = ProcessInfo.processInfo.systemUptime
            let added = Set(next.keys).subtracting(self.coins.keys)
            self.lastPrimary = self.lastPrimary.filter { next[$0.key] != nil }
            self.lastEmitted = self.lastEmitted.filter { next[$0.key] != nil }
            self.subscriptions = self.subscriptions.filter { next[$0.key] != nil }
            for symbol in added { self.subscriptions[symbol] = UUID() }
            for symbol in next.keys where self.coins[symbol] == nil { self.lastPrimary[symbol] = now }
            self.coins = next
            guard self.running else { return }
            self.primary.setSymbols(Set(next.keys))
            self.updateBackup()
            if next.isEmpty { self.stopSnapshots() }
            else {
                self.startSnapshotTimer()
                if !added.isEmpty { self.requestSnapshot() }
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.primaryFailed = false
            let now = ProcessInfo.processInfo.systemUptime
            self.lastPrimary = self.coins.mapValues { _ in now }
            self.lastEmitted.removeAll()
            self.primary.setSymbols(Set(self.coins.keys))
            self.startSnapshotTimer()
            self.requestSnapshot()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.updateBackup() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            self.primary.setSymbols([])
            self.backup.setSymbols([])
            self.stopSnapshots()
            self.lastPrimary.removeAll()
            self.lastEmitted.removeAll()
        }
    }

    deinit {
        timer?.cancel()
        snapshotTimer?.cancel()
        snapshotTask?.cancel()
    }

    private func startSnapshotTimer() {
        guard snapshotTimer == nil, running, !coins.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + snapshotInterval, repeating: snapshotInterval)
        timer.setEventHandler { [weak self] in self?.requestSnapshot() }
        snapshotTimer = timer
        timer.resume()
    }

    private func stopSnapshots() {
        snapshotTimer?.cancel()
        snapshotTimer = nil
        snapshotRequestID = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotPending = false
    }

    private func requestSnapshot() {
        guard running, !coins.isEmpty else { return }
        guard snapshotTask == nil else {
            // 在途请求期间新增订阅只合并成一轮补查，不为每个币单独发请求。
            snapshotPending = true
            return
        }
        let requestID = UUID()
        let subscribed = subscriptions
        // 接口没有逐币时间戳：用请求起点保守排序，避免覆盖在途期间的新推送。
        let timestamp = Date()
        let url = URL(string: "https://api.gateio.ws/api/v4/spot/tickers")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        snapshotRequestID = requestID
        let task = restSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.running, self.snapshotRequestID == requestID else { return }
                self.snapshotTask = nil
                self.snapshotRequestID = nil
                if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let data, let quotes = try? CEXWire.restQuotes(from: data, timestamp: timestamp) {
                    for quote in quotes where subscribed[quote.symbol] != nil
                        && self.subscriptions[quote.symbol] == subscribed[quote.symbol] {
                        // REST 成功不代表 WebSocket 恢复，保持其重连与备用判断独立。
                        self.emit(quote)
                    }
                }
                if self.snapshotPending {
                    self.snapshotPending = false
                    self.requestSnapshot()
                }
            }
        }
        snapshotTask = task
        task.resume()
    }

    private func makeSocket(_ exchange: CEXExchange) -> CEXSocket {
        CEXSocket(exchange: exchange, url: exchange == .gate ? gateURL : binanceURL,
                  queue: queue, onQuote: { [weak self] quote in
            self?.received(quote, from: exchange)
        }, onFailure: { [weak self] in
            guard let self, self.running, exchange == .gate else { return }
            self.primaryFailed = true
            self.updateBackup()
        })
    }

    private func updateBackup() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        backup.setSymbols(Set(coins.keys.filter {
            primaryFailed || now - (lastPrimary[$0] ?? now) >= 12
        }))
    }

    private func received(_ quote: CEXQuote, from exchange: CEXExchange) {
        guard running, coins[quote.symbol] != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if exchange == .gate {
            lastPrimary[quote.symbol] = now
            primaryFailed = false
            updateBackup()
        } else if !primaryFailed && now - (lastPrimary[quote.symbol] ?? 0) < 12 {
            return
        }
        emit(quote)
    }

    private func emit(_ quote: CEXQuote) {
        guard running, let coin = coins[quote.symbol] else { return }
        // 切换数据源时不允许较旧的数据覆盖已经显示的较新数据。
        guard quote.timestamp >= (lastEmitted[quote.symbol] ?? .distantPast) else { return }
        lastEmitted[quote.symbol] = quote.timestamp
        let tick = PriceTick(coinId: coin.id, priceUSD: quote.price,
                             change24h: quote.change24h, timestamp: quote.timestamp)
        onTick?(tick)
    }
}

/// 所有状态及回调都限于 provider 的串行队列；过期 socket 的回调按任务身份丢弃。
private final class CEXSocket {
    private let exchange: CEXExchange
    private let url: URL
    private let queue: DispatchQueue
    private let onQuote: (CEXQuote) -> Void
    private let onFailure: () -> Void
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var desired: Set<String> = []
    private var sent: Set<String> = []
    private var timer: DispatchSourceTimer?
    private var reconnect: DispatchWorkItem?
    private var flush: DispatchWorkItem?
    private var attempts = 0
    private var requestID = 0
    private var opened = false
    private var startedAt: TimeInterval = 0
    private var lastReceived: TimeInterval = 0
    private var lastSent: TimeInterval = 0
    private var lastPing: TimeInterval = 0
    private var waitingForPong: TimeInterval?

    init(exchange: CEXExchange, url: URL, queue: DispatchQueue,
         onQuote: @escaping (CEXQuote) -> Void, onFailure: @escaping () -> Void) {
        self.exchange = exchange
        self.url = url
        self.queue = queue
        self.onQuote = onQuote
        self.onFailure = onFailure
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: config)
    }

    deinit {
        timer?.cancel()
        reconnect?.cancel()
        flush?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    func setSymbols(_ symbols: Set<String>) {
        guard desired != symbols else { return }
        desired = symbols
        if symbols.isEmpty {
            reconnect?.cancel()
            reconnect = nil
            disconnect()
            attempts = 0
        } else if socket == nil && reconnect == nil {
            connect()
        } else {
            scheduleFlush()
        }
    }

    private func connect() {
        guard !desired.isEmpty, socket == nil else { return }
        reconnect = nil
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1_048_576
        socket = task
        opened = false
        sent.removeAll()
        startedAt = ProcessInfo.processInfo.systemUptime
        lastReceived = startedAt
        lastSent = 0
        lastPing = startedAt
        waitingForPong = nil
        task.resume()
        receive(task)
        scheduleFlush()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        self.timer = timer
        timer.resume()
    }

    private func disconnect() {
        timer?.cancel()
        timer = nil
        flush?.cancel()
        flush = nil
        let previous = socket
        socket = nil
        previous?.cancel(with: .goingAway, reason: nil)
        sent.removeAll()
        waitingForPong = nil
    }

    private func failed(_ task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        disconnect()
        guard !desired.isEmpty else { return }
        onFailure()
        attempts = min(attempts + 1, 6)
        let delay = min(pow(2, Double(attempts - 1)), 30) + Double.random(in: 0...0.5)
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnect = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleFlush() {
        guard flush == nil, socket != nil, desired != sent else { return }
        let delay = max(0.35, lastSent + 0.4 - ProcessInfo.processInfo.systemUptime)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flush = nil
            self.flushSubscriptions()
        }
        flush = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flushSubscriptions() {
        guard let task = socket else { return }
        let removed = sent.subtracting(desired)
        let subscribe = removed.isEmpty
        let delta = subscribe ? desired.subtracting(sent) : removed
        guard !delta.isEmpty else { return }
        // 每批一个控制消息，并合并快速连续的 setCoins，避免触发交易所频率限制。
        let batch = Array(delta.sorted().prefix(100))
        requestID += 1
        let object = exchange.subscription(symbols: batch, subscribe: subscribe, id: requestID)
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        if subscribe { sent.formUnion(batch) } else { sent.subtract(batch) }
        send(text, through: task)
        scheduleFlush()
    }

    private func send(_ text: String, through task: URLSessionWebSocketTask) {
        lastSent = ProcessInfo.processInfo.systemUptime
        task.send(.string(text)) { [weak self, weak task] error in
            guard let self, let task else { return }
            self.queue.async { [weak self] in
                guard let self, self.socket === task else { return }
                if error != nil { self.failed(task) }
                else { self.opened = true }
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            self.queue.async { [weak self] in
                guard let self, self.socket === task else { return }
                switch result {
                case .failure: self.failed(task)
                case .success(let message):
                    self.opened = true
                    self.lastReceived = ProcessInfo.processInfo.systemUptime
                    let data: Data
                    switch message {
                    case .string(let text):
                        data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default:
                        self.receive(task)
                        return
                    }
                    if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        if self.exchange == .binance, object["code"] != nil {
                            self.failed(task)
                            return
                        }
                        if self.exchange == .gate {
                            if object["channel"] as? String == "spot.pong" {
                                self.waitingForPong = nil
                            }
                            if object["channel"] as? String == "spot.system",
                               let result = object["result"] as? [String: Any],
                               result["type"] as? String == "upgrade" {
                                self.failed(task)
                                return
                            }
                            // 无效交易对不会拖垮同一连接里的其他订阅；缺价币由备用源补齐。
                            if object["error"] is [String: Any] {
                                self.receive(task)
                                return
                            }
                        }
                        if object["e"] as? String == "serverShutdown" {
                            self.failed(task)
                            return
                        }
                        for quote in CEXWire.quotes(from: object, exchange: self.exchange)
                            where self.desired.contains(quote.symbol) {
                            self.attempts = 0
                            self.onQuote(quote)
                        }
                    }
                    self.receive(task)
                }
            }
        }
    }

    private func heartbeat() {
        guard let task = socket else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !opened && now - startedAt >= 12 {
            failed(task)
            return
        }
        if let ping = waitingForPong, now - ping >= 10 {
            failed(task)
            return
        }
        guard opened, waitingForPong == nil else { return }
        if exchange == .gate {
            if now - lastPing >= 15 && now - lastSent >= 0.4 {
                lastPing = now
                waitingForPong = now
                let ping: [String: Any] = ["time": Int(Date().timeIntervalSince1970), "channel": "spot.ping"]
                if let data = try? JSONSerialization.data(withJSONObject: ping),
                   let text = String(data: data, encoding: .utf8) { send(text, through: task) }
            }
        } else if now - lastPing >= 15 && now - lastSent >= 0.4 {
            lastPing = now
            waitingForPong = now
            task.sendPing { [weak self, weak task] error in
                guard let self, let task else { return }
                self.queue.async { [weak self] in
                    guard let self, self.socket === task else { return }
                    if error != nil { self.failed(task) }
                    else { self.waitingForPong = nil }
                }
            }
        }
    }
}
