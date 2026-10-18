import Foundation
import Network
import CryptoKit

/// 内置 Shadowsocks 客户端：在本机回环地址上开一个 SOCKS5 入口，每个连接经 AEAD 加密直连云服务器。
/// 代理会话（URLSession 的 SOCKS 代理）直接指向这个入口。
/// 移植自作者另一个 macOS 项目里的同名实现；入口重建与状态变化
/// 改由回调通知，不再依赖那边的全局网络层和日志。
///
/// 协议：Shadowsocks AEAD（SIP004）
/// - 主密钥 = EVP_BytesToKey(MD5, 密码)；每个方向一个随机盐，子密钥 = HKDF-SHA1(主密钥, 盐, "ss-subkey")
/// - 数据分块：[加密的 2 字节长度 + 16 字节标签][加密的负载 + 16 字节标签]，负载不超过 0x3FFF
/// - Nonce 为 12 字节小端计数器，每次加/解密后加一
/// - 首块负载以目标地址开头（格式与 SOCKS5 地址相同：类型 + 地址 + 端口）
public final class ShadowsocksTunnel: @unchecked Sendable {
    public init() {}

    public enum Cipher: String, Codable, CaseIterable, Sendable, Identifiable {
        case chacha20 = "chacha20-ietf-poly1305"
        case aes256gcm = "aes-256-gcm"
        case aes128gcm = "aes-128-gcm"
        public var id: String { rawValue }
        var keySize: Int { self == .aes128gcm ? 16 : 32 }
    }

    public struct Config: Equatable, Sendable {
        public var server: String
        public var port: Int
        public var password: String
        public var cipher: Cipher
        public init(server: String, port: Int, password: String, cipher: Cipher) {
            self.server = server; self.port = port; self.password = password; self.cipher = cipher
        }
    }

    /// 运行统计（诊断用）
    public struct Stats: Sendable {
        public var active = 0
        public var total = 0
        public var failed = 0
        public var bytesDown: Int64 = 0
        public var bytesUp: Int64 = 0
        public var lastError: String?
        /// 最近一次连上服务器用的时间（毫秒）
        public var lastConnectMs: Double?
    }

    private let queue = DispatchQueue(label: "ss.tunnel", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var config: Config?
    private var masterKey = Data()
    private var _port: UInt16 = 0
    private var _stats = Stats()
    private var sessions: [ObjectIdentifier: SSSession] = [:]

    // 健康状态：连续 3 次连不上云服务器 → 不健康（代理路由临时让位给直连），后台探测到恢复后自动回来。
    // 同一瞬间（1 秒内）的多次失败只算一次：并发的几条连接、URLSession 对同一请求的自动重试会同时失败
    private var connectFailures = 0
    private var lastFailureAt: Date?
    static let failureBurst: TimeInterval = 1
    // 不健康时的快速探测（1、2、4、8 秒…最长 10 秒一次），不只靠每 10 秒一次的维护
    private var probeDelay: Double = 1
    private var probeScheduled = false
    /// 探测排程的代数：网络变化时作废还在等的长间隔探测，按 1 秒重新起步
    private var probeGen = 0
    private var runID = 0
    // 本机入口的恢复：入口在运行中失效、或启动 / 重建失败时，按 1、2、4…最长 30 秒退避重建，
    // 直到入口恢复，或者设置改了 / 关闭了内置隧道（start / stop 会作废还在等的重建）
    /// 调用方要求运行的配置（start 设置、stop 清除；启动失败时保留，供重建使用）
    private var desired: Config?
    private var rebuildDelay: Double = 1
    private var rebuildScheduled = false
    private var rebuildGen = 0
    static let rebuildMaxDelay: Double = 30
    /// 串行化 start / stop / 重建：后台的重建不会和设置页的启动交错，旧配置的重建也不会盖掉新配置
    private let opLock = NSRecursiveLock()
    // 预热连接池：提前握手好的 TCP 连接，新代理连接省掉一次到服务器的往返（约 70ms）
    public var prewarm = true
    public var poolSize = 2
    private var pool: [(conn: NWConnection, at: Date)] = []
    private var pending: [ObjectIdentifier: NWConnection] = [:]
    private var maintainer: DispatchSourceTimer?
    private static let warmMaxAge: TimeInterval = 45

    /// 本机 SOCKS5 入口端口（未启动时为 0）
    public var port: UInt16 { lock.withLock { _port } }
    public var stats: Stats { lock.withLock { _stats } }
    public var isRunning: Bool { lock.withLock { listener != nil && _port != 0 } }
    /// 本机入口自动重建成功：代理会话要改指向新端口。带上重建所用的配置，
    /// 接收方据此丢弃旧配置迟到的通知（通知在 opLock 之外发出，可能晚于新配置的 start）
    public var onRebuilt: (@Sendable (Config, UInt16) -> Void)?
    /// 状态变化（不健康、恢复、入口失效与重建），供界面和诊断显示
    public var onEvent: (@Sendable (String) -> Void)?
    /// 当前的本机入口（自检模拟入口失效用）
    var currentListener: NWListener? { lock.withLock { listener } }
    /// 云服务器可达（连续 3 次连不上判为不可达）
    public var healthy: Bool { lock.withLock { connectFailures < 3 } }
    private var unhealthyLocked: Bool { connectFailures >= 3 }
    public var warmCount: Int { lock.withLock { pool.count } }

    /// 启动（配置相同则复用），返回本机入口端口
    @discardableResult
    public func start(_ c: Config) throws -> UInt16 {
        opLock.lock()
        defer { opLock.unlock() }
        let reuse: Bool = lock.withLock {
            desired = c
            // 显式启动作废还在等的重建（失败时下面会重新排）
            rebuildGen += 1
            rebuildScheduled = false
            return config == c && listener != nil && _port != 0
        }
        if reuse { return port }
        teardown()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            // 入口建不起来：与启动超时 / 失败一样，稍后按退避自动重建
            scheduleRebuild(c)
            throw error
        }
        let ready = DispatchSemaphore(value: 0)
        let startup = StartupState()
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if startup.markReady() { ready.signal() }
            case .failed(let e):
                // 运行中入口失效：没人处理的话 isRunning 仍为真，经代理的请求全部被拒绝
                if startup.isReady { self?.listenerFailed(l, e) } else { startup.fail(e); ready.signal() }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        lock.withLock {
            config = c
            masterKey = Self.evpBytesToKey(c.password, keySize: c.cipher.keySize)
            listener = l
        }
        l.start(queue: queue)
        let timedOut = ready.wait(timeout: .now() + 3) == .timedOut
        let failure = startup.failure
        if timedOut || failure != nil {
            l.cancel()
            lock.withLock { if listener === l { listener = nil; config = nil } }
            // 本机入口起不来（多半是网络栈暂时异常）：稍后按退避自动重建，不要求用户改设置或重启
            scheduleRebuild(c)
            throw failure ?? ShadowsocksError.timeout
        }
        let p = l.port?.rawValue ?? 0
        lock.withLock { _port = p; connectFailures = 0; lastFailureAt = nil; probeDelay = 1; runID += 1; rebuildDelay = 1 }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 10)
        t.setEventHandler { [weak self] in self?.maintain() }
        t.resume()
        lock.withLock { maintainer = t }
        return p
    }

    public func stop() {
        opLock.lock()
        defer { opLock.unlock() }
        lock.withLock {
            desired = nil
            rebuildGen += 1
            rebuildScheduled = false
            rebuildDelay = 1
        }
        teardown()
    }

    /// 关掉入口、会话与预热连接（不改 desired：start 重建时也用）
    private func teardown() {
        let (l, ss, warm, m): (NWListener?, [SSSession], [NWConnection], DispatchSourceTimer?) = lock.withLock {
            let r = (listener, Array(sessions.values), pool.map(\.conn) + Array(pending.values), maintainer)
            // 被清掉的会话之后结束时已查不到自己，不会再扣减计数：这里一并扣掉
            _stats.active = max(0, _stats.active - sessions.count)
            listener = nil; _port = 0; config = nil; sessions = [:]
            pool = []; pending = [:]; maintainer = nil; connectFailures = 0
            lastFailureAt = nil; probeDelay = 1; probeScheduled = false; runID += 1
            return r
        }
        m?.cancel()
        l?.cancel()
        ss.forEach { $0.close() }
        warm.forEach { $0.cancel() }
    }

    // MARK: 预热 / 健康探测

    /// 新建一条到云服务器的 TCP 连接（与 SSSession 相同的参数）
    static func makeRemote(_ c: Config) -> NWConnection? {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .responsiveData
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: c.port)) else { return nil }
        return NWConnection(host: NWEndpoint.Host(c.server), port: port, using: params)
    }

    /// 每 10 秒：淘汰过旧的预热连接并补足；不健康时发起一次探测
    private func maintain() {
        let (cfg, stale, need): (Config?, [NWConnection], Int) = lock.withLock {
            guard let c = config else { return (nil, [], 0) }
            let now = Date()
            let old = pool.filter { now.timeIntervalSince($0.at) > Self.warmMaxAge }.map(\.conn)
            pool.removeAll { now.timeIntervalSince($0.at) > Self.warmMaxAge }
            let target = prewarm ? poolSize : (unhealthyLocked ? 1 : 0)
            var n = max(0, target - pool.count - pending.count)
            // 不健康时池子满了也要探测：池里的空闲连接说明不了服务器现在能不能连上
            if unhealthyLocked && pending.isEmpty { n = max(n, 1) }
            return (c, old, n)
        }
        stale.forEach { $0.cancel() }
        guard let cfg, need > 0 else { return }
        for _ in 0..<need { warmUp(cfg) }
    }

    private func warmUp(_ c: Config) {
        guard let conn = Self.makeRemote(c) else { return }
        let id = ObjectIdentifier(conn)
        let t0 = Date()
        lock.withLock { pending[id] = conn }
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            guard let self, let conn else { return }
            switch st {
            case .ready:
                self.connected(ms: Date().timeIntervalSince(t0) * 1000)
                let keep: Bool = self.lock.withLock {
                    guard self.pending.removeValue(forKey: id) != nil, self.config != nil else { return false }
                    if self.prewarm && self.pool.count < self.poolSize { self.pool.append((conn, Date())); return true }
                    return false
                }
                if !keep { conn.cancel() }
            case .failed(let e), .waiting(let e):
                let wasPending: Bool = self.lock.withLock { self.pending.removeValue(forKey: id) != nil }
                if wasPending { self.connectFailed("连不上服务器：\(e)") }
                // 已进入预热池的连接失效：从池里移除
                self.lock.withLock { self.pool.removeAll { $0.conn === conn } }
                conn.cancel()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    /// 取一条已握手好的连接（没有则返回 nil，调用方自己新建）
    fileprivate func takeWarm() -> NWConnection? {
        let c: NWConnection? = lock.withLock {
            let now = Date()
            while let first = pool.first {
                pool.removeFirst()
                if now.timeIntervalSince(first.at) <= Self.warmMaxAge, first.conn.state == .ready { return first.conn }
                first.conn.cancel()
            }
            return nil
        }
        // 取走一条就立刻补上，连续新建连接时也能一直用上预热的
        queue.async { [weak self] in self?.maintain() }
        return c
    }

    func connectFailed(_ msg: String) {
        let becameUnhealthy: Bool = lock.withLock {
            _stats.lastError = msg
            let now = Date()
            if let last = lastFailureAt, now.timeIntervalSince(last) < Self.failureBurst { return false }
            lastFailureAt = now
            connectFailures += 1
            return connectFailures == 3
        }
        if becameUnhealthy {
            onEvent?("代理服务器连续 3 次连接失败，暂时改走直连：\(msg)")
            scheduleProbe()
        }
    }

    /// 不健康期间按 1、2、4、8…（最长 10 秒）的间隔探测，服务器恢复后尽快回到原路由
    private func scheduleProbe() {
        let plan: (Double, Int, Int)? = lock.withLock {
            guard config != nil, unhealthyLocked, !probeScheduled else { return nil }
            probeScheduled = true
            let d = probeDelay
            probeDelay = min(10, probeDelay * 2)
            return (d, runID, probeGen)
        }
        guard let (delay, id, pg) = plan else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let go: Bool = self.lock.withLock {
                guard self.runID == id, self.probeGen == pg else { return false }
                self.probeScheduled = false
                return self.unhealthyLocked
            }
            guard go else { return }
            self.maintain()
            self.scheduleProbe()
        }
    }

    /// 网络变化（换 Wi-Fi、断开后恢复、在线时换了网卡）：预热池和还在握手的都是旧网络上的连接，丢掉重建。
    /// 已判为不健康的不因网络变化直接改回健康（服务器可能真的连不上，乐观改回会让代理请求打进坏掉的隧道
    /// 十几秒）：立即重新探测，连上时由 connected() 恢复；还健康时清掉断网期间攒下的零星失败。
    /// 恢复在线时本机入口没在运行（启动或重建失败过）：立即重新排一次重建
    public func networkChanged(online: Bool) {
        let (drop, wasUnhealthy, rebuild): ([NWConnection], Bool, Config?) = lock.withLock {
            var rb: Config?
            if online, let d = desired, !(listener != nil && _port != 0) {
                // 作废还在等的长间隔重建，从 1 秒重新起步
                rebuildGen += 1
                rebuildScheduled = false
                rebuildDelay = 1
                rb = d
            }
            guard config != nil else { return ([], false, rb) }
            let d = pool.map(\.conn) + Array(pending.values)
            pool = []
            pending = [:]
            let unhealthy = unhealthyLocked
            if online {
                if !unhealthy { connectFailures = 0 }
                lastFailureAt = nil
                probeDelay = 1
                probeGen += 1
                probeScheduled = false
            }
            return (d, unhealthy, rb)
        }
        drop.forEach { $0.cancel() }
        if let rebuild { scheduleRebuild(rebuild) }
        guard online else { return }
        queue.async { [weak self] in
            // 不健康时 maintain 至少发一条探测；之后按 1 秒起步继续探测，直到连上
            self?.maintain()
            if wasUnhealthy { self?.scheduleProbe() }
        }
    }

    /// 入口在运行中失效：标记为未运行（经代理的请求临时直连，而不是全部被拒绝），稍后重建入口并让代理会话指向新端口
    func listenerFailed(_ l: NWListener, _ e: NWError) {
        let cfg: Config? = lock.withLock {
            guard listener === l else { return nil }
            _port = 0
            return desired ?? config
        }
        guard let cfg else { return }
        onEvent?("代理隧道的本机入口失效（\(e)），正在重建")
        scheduleRebuild(cfg)
    }

    /// 按退避间隔排一次重建（已有排程时不重复排）
    private func scheduleRebuild(_ c: Config) {
        let plan: (Double, Int)? = lock.withLock {
            guard desired == c, !rebuildScheduled else { return nil }
            rebuildScheduled = true
            let d = rebuildDelay
            rebuildDelay = min(Self.rebuildMaxDelay, rebuildDelay * 2)
            return (d, rebuildGen)
        }
        guard let (delay, gen) = plan else { return }
        // start 最长阻塞 3 秒，不能放在主线程或隧道队列上
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.rebuild(c, gen: gen)
        }
    }

    /// 重建本机入口：期间 start / stop 过（代数变了）、配置不再是 c、或入口已经在运行时什么都不做。
    /// 失败时 start 会按更长的间隔再排一次
    private func rebuild(_ c: Config, gen: Int) {
        let port: UInt16?
        do {
            opLock.lock()
            defer { opLock.unlock() }
            let go: Bool = lock.withLock {
                guard rebuildGen == gen else { return false }
                rebuildScheduled = false
                return desired == c && !(listener != nil && _port != 0)
            }
            guard go else { return }
            do {
                port = try start(c)
            } catch {
                let next = lock.withLock { rebuildScheduled ? rebuildDelay / 2 : 0 }
                onEvent?("代理隧道的本机入口重建失败（\(error)）\(next > 0 ? "，\(Int(next)) 秒后再试" : "")")
                port = nil
            }
        }
        guard let port else { return }
        onEvent?("代理隧道的本机入口已重建（127.0.0.1:\(port)）")
        // 代理会话还指向旧端口（或启动失败时的拒绝端口）：改指向新入口
        onRebuilt?(c, port)
    }

    private func accept(_ client: NWConnection) {
        guard let c = lock.withLock({ config }) else { client.cancel(); return }
        let key = lock.withLock { masterKey }
        let s = SSSession(client: client, config: c, masterKey: key, queue: queue, tunnel: self)
        lock.withLock {
            sessions[ObjectIdentifier(s)] = s
            _stats.active += 1
            _stats.total += 1
        }
        s.start()
    }

    fileprivate func finished(_ s: SSSession, error: String?) {
        lock.withLock {
            guard sessions.removeValue(forKey: ObjectIdentifier(s)) != nil else { return }
            _stats.active -= 1
            if let error { _stats.failed += 1; _stats.lastError = error }
        }
    }

    fileprivate func count(down: Int = 0, up: Int = 0) {
        lock.withLock { _stats.bytesDown += Int64(down); _stats.bytesUp += Int64(up) }
    }

    fileprivate func connected(ms: Double) {
        let recovered: Bool = lock.withLock {
            let was = unhealthyLocked
            _stats.lastConnectMs = ms
            connectFailures = 0
            lastFailureAt = nil
            probeDelay = 1
            return was
        }
        if recovered { onEvent?(String(format: "代理服务器已恢复（连接用了 %.0f ms）", ms)) }
    }

    // MARK: 密钥

    static func evpBytesToKey(_ password: String, keySize: Int) -> Data {
        let pw = Data(password.utf8)
        var out = Data(), prev = Data()
        while out.count < keySize {
            prev = Data(Insecure.MD5.hash(data: prev + pw))
            out += prev
        }
        return out.prefix(keySize)
    }

    static func subkey(master: Data, salt: Data, size: Int) -> SymmetricKey {
        HKDF<Insecure.SHA1>.deriveKey(inputKeyMaterial: SymmetricKey(data: master), salt: salt,
                                      info: Data("ss-subkey".utf8), outputByteCount: size)
    }
}

/// 单个方向的 AEAD 状态（子密钥 + 递增 nonce）
struct SSAEAD {
    let key: SymmetricKey
    let cipher: ShadowsocksTunnel.Cipher
    private var counter: UInt64 = 0

    init(key: SymmetricKey, cipher: ShadowsocksTunnel.Cipher) {
        self.key = key
        self.cipher = cipher
    }

    private mutating func nextNonce() -> Data {
        var n = Data(count: 12)
        var c = counter.littleEndian
        withUnsafeBytes(of: &c) { n.replaceSubrange(0..<8, with: $0) }
        counter &+= 1
        return n
    }

    mutating func seal(_ plain: Data) throws -> Data {
        let nonce = nextNonce()
        switch cipher {
        case .chacha20:
            let box = try ChaChaPoly.seal(plain, using: key, nonce: ChaChaPoly.Nonce(data: nonce))
            return box.ciphertext + box.tag
        case .aes256gcm, .aes128gcm:
            let box = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: nonce))
            return box.ciphertext + box.tag
        }
    }

    mutating func open(_ sealed: Data) throws -> Data {
        let nonce = nextNonce()
        let ct = sealed.prefix(sealed.count - 16), tag = sealed.suffix(16)
        switch cipher {
        case .chacha20:
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ct, tag: tag), using: key)
        case .aes256gcm, .aes128gcm:
            return try AES.GCM.open(AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct, tag: tag), using: key)
        }
    }

    /// 把任意长度数据切成 AEAD 块
    mutating func encryptChunks(_ data: Data) throws -> Data {
        var out = Data()
        out.reserveCapacity(data.count + (data.count / 0x3FFF + 1) * 34)
        var i = data.startIndex
        while i < data.endIndex {
            let j = min(i + 0x3FFF, data.endIndex)
            let part = data[i..<j]
            let len = UInt16(part.count)
            out += try seal(Data([UInt8(len >> 8), UInt8(len & 0xFF)]))
            out += try seal(Data(part))
            i = j
        }
        return out
    }
}

/// 一个 SOCKS5 连接 ⇄ 一个 Shadowsocks 连接
final class SSSession: @unchecked Sendable {
    private let client: NWConnection
    private var remote: NWConnection?
    private let config: ShadowsocksTunnel.Config
    private let masterKey: Data
    private let queue: DispatchQueue
    private weak var tunnel: ShadowsocksTunnel?

    private var inBuf = Data()            // 客户端 SOCKS 握手缓冲
    private var enc: SSAEAD?
    private var dec: SSAEAD?
    private var downBuf = Data()           // 服务器方向待解密缓冲
    private var pendingLen: Int?           // 已解出、负载还没收齐的块长度
    private var pendingUp = Data()         // 远端就绪前客户端发来的数据
    private var targetHeader = Data()
    private var remoteReady = false
    private var headerSent = false
    private var closed = false
    private var closedByTunnel = false
    private var connectStart = Date()
    /// 客户端放弃时远端已经等了这么久还没连上：服务器被丢包 / 黑洞时不会有连接失败回调，按一次失败计
    private static let slowConnect: TimeInterval = 3

    init(client: NWConnection, config: ShadowsocksTunnel.Config, masterKey: Data, queue: DispatchQueue, tunnel: ShadowsocksTunnel) {
        self.client = client
        self.config = config
        self.masterKey = masterKey
        self.queue = queue
        self.tunnel = tunnel
    }

    func start() {
        client.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { self?.fail("客户端：\(e)") }
        }
        client.start(queue: queue)
        readGreeting()
    }

    func close() {
        queue.async { [self] in
            closedByTunnel = true
            finish(nil)
        }
    }

    private func fail(_ msg: String) { finish(msg) }

    private func finish(_ error: String?) {
        guard !closed else { return }
        closed = true
        if error == nil, !closedByTunnel, !remoteReady, remote != nil,
           Date().timeIntervalSince(connectStart) > Self.slowConnect {
            tunnel?.connectFailed(String(format: "连接服务器 %.0f 秒没有响应", Date().timeIntervalSince(connectStart)))
        }
        client.cancel()
        remote?.cancel()
        tunnel?.finished(self, error: error)
    }

    // MARK: SOCKS5 握手（只支持无认证 + CONNECT）

    private func need(_ n: Int, _ then: @escaping () -> Void) {
        if inBuf.count >= n { then(); return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.inBuf += data }
            if err != nil || (done && self.inBuf.count < n) { self.fail("SOCKS 握手中断"); return }
            self.need(n, then)
        }
    }

    private func readGreeting() {
        need(2) { [self] in
            let b = [UInt8](inBuf.prefix(2))
            // 不是 SOCKS5（例如本机其他工具对新端口做的 HTTP 健康检查）：直接关闭，不算失败
            guard b[0] == 5 else { finish(nil); return }
            let n = Int(b[1])
            need(2 + n) { [self] in
                inBuf.removeFirst(2 + n)
                client.send(content: Data([5, 0]), completion: .contentProcessed { _ in })
                readRequest()
            }
        }
    }

    private func readRequest() {
        need(5) { [self] in
            let b = [UInt8](inBuf.prefix(5))
            guard b[0] == 5, b[1] == 1 else {
                client.send(content: Data([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { [weak self] _ in self?.fail("不支持的 SOCKS 命令") })
                return
            }
            let atyp = b[3]
            let addrLen: Int
            switch atyp {
            case 1: addrLen = 4
            case 4: addrLen = 16
            case 3: addrLen = 1 + Int(b[4])
            default: fail("未知地址类型"); return
            }
            let total = 4 + addrLen + 2
            need(total) { [self] in
                targetHeader = Data(inBuf[inBuf.startIndex + 3 ..< inBuf.startIndex + total])   // 类型 + 地址 + 端口
                inBuf.removeFirst(total)
                pendingUp = inBuf
                inBuf = Data()
                connectRemote()
                // 先回应成功，客户端可立即发出 HTTP 请求（与服务器握手并行）
                client.send(content: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in })
                pumpClient()
            }
        }
    }

    // MARK: 远端

    private func connectRemote() {
        // 优先用预热好的连接：直接发盐与目标地址，省一次握手
        if let warm = tunnel?.takeWarm() {
            remote = warm
            warm.stateUpdateHandler = { [weak self] st in
                guard let self, !self.closed else { return }
                if case .failed(let e) = st { self.fail("服务器连接中断：\(e)") }
            }
            remoteReady = true
            flushUp()
            pumpRemote()
            return
        }
        guard let r = ShadowsocksTunnel.makeRemote(config) else { fail("端口无效"); return }
        remote = r
        connectStart = Date()
        r.stateUpdateHandler = { [weak self] st in
            guard let self, !self.closed else { return }
            switch st {
            case .ready:
                self.tunnel?.connected(ms: Date().timeIntervalSince(self.connectStart) * 1000)
                self.remoteReady = true
                self.flushUp()
                self.pumpRemote()
            case .failed(let e):
                self.tunnel?.connectFailed("连不上服务器：\(e)")
                self.fail("连不上服务器：\(e)")
            case .waiting(let e):
                self.tunnel?.connectFailed("服务器不可达：\(e)")
                self.fail("服务器不可达：\(e)")
            default: break
            }
        }
        r.start(queue: queue)
    }

    /// 发送客户端数据（首次附带盐 + 目标地址）
    /// then：本批数据交给系统发送完成后调用（上行背压：发完再读下一批）；没有要发的数据时立即调用
    private func flushUp(then: (() -> Void)? = nil) {
        guard remoteReady, let r = remote else { then?(); return }
        do {
            var out = Data()
            if !headerSent {
                var salt = Data(count: config.cipher.keySize)
                _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, config.cipher.keySize, $0.baseAddress!) }
                enc = SSAEAD(key: ShadowsocksTunnel.subkey(master: masterKey, salt: salt, size: config.cipher.keySize), cipher: config.cipher)
                out += salt
                out += try enc!.encryptChunks(targetHeader + pendingUp)
                headerSent = true
            } else if !pendingUp.isEmpty {
                out += try enc!.encryptChunks(pendingUp)
            }
            tunnel?.count(up: pendingUp.count)
            pendingUp = Data()
            guard !out.isEmpty else { then?(); return }
            r.send(content: out, completion: .contentProcessed { [weak self] err in
                if let err { self?.fail("发往服务器失败：\(err)"); return }
                then?()
            })
        } catch {
            fail("加密失败：\(error)")
        }
    }

    /// 客户端 → 服务器
    private func pumpClient() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if err != nil || done {
                if let data, !data.isEmpty { self.pendingUp += data; self.flushUp() }
                self.finish(nil)
                return
            }
            guard let data, !data.isEmpty else { self.pumpClient(); return }
            self.pendingUp += data
            // 远端未就绪时先攒着（连接建立后统一发出）；就绪后等本批发完再读下一批
            if self.remoteReady {
                self.flushUp { [weak self] in
                    guard let self, !self.closed else { return }
                    self.pumpClient()
                }
            } else {
                self.pumpClient()
            }
        }
    }

    /// 服务器 → 客户端（解密后转发；等客户端收下再读下一批，形成背压）
    private func pumpRemote() {
        remote?.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.downBuf += data }
            let plain: Data
            do { plain = try self.drainDown() } catch { self.fail("解密失败（密码或加密方式不对？）"); return }
            let finishAfter = err != nil || done
            if plain.isEmpty {
                if finishAfter { self.finish(nil) } else { self.pumpRemote() }
                return
            }
            self.tunnel?.count(down: plain.count)
            self.client.send(content: plain, completion: .contentProcessed { [weak self] e in
                guard let self, !self.closed else { return }
                if e != nil || finishAfter { self.finish(nil); return }
                self.pumpRemote()
            })
        }
    }

    private func drainDown() throws -> Data {
        var out = Data()
        let ks = config.cipher.keySize
        if dec == nil {
            guard downBuf.count >= ks else { return out }
            dec = SSAEAD(key: ShadowsocksTunnel.subkey(master: masterKey, salt: Data(downBuf.prefix(ks)), size: ks), cipher: config.cipher)
            downBuf.removeFirst(ks)
        }
        while true {
            if pendingLen == nil {
                guard downBuf.count >= 18 else { break }
                let l = try dec!.open(Data(downBuf.prefix(18)))
                let len = Int(l[l.startIndex]) << 8 | Int(l[l.startIndex + 1])
                guard len > 0, len <= 0x3FFF else { throw ShadowsocksError.badFrame }
                downBuf.removeFirst(18)
                pendingLen = len
            }
            guard let len = pendingLen, downBuf.count >= len + 16 else { break }
            out += try dec!.open(Data(downBuf.prefix(len + 16)))
            downBuf.removeFirst(len + 16)
            pendingLen = nil
        }
        return out
    }
}

/// Listener start-up result shared with the state handler (which runs on the tunnel queue).
private final class StartupState: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var error: Error?
    var isReady: Bool { lock.withLock { ready } }
    var failure: Error? { lock.withLock { error } }
    /// True the first time only.
    func markReady() -> Bool { lock.withLock { defer { ready = true }; return !ready } }
    func fail(_ value: Error) { lock.withLock { error = value } }
}

public enum ShadowsocksError: Error, Equatable {
    case timeout
    case badFrame
}
