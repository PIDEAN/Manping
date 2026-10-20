import Foundation

public struct QRLogin: Sendable {
  public let url: URL
  public let key: String
  public let token: UInt64
}
public enum QRStatus: Sendable { case waiting, scanned, expired, success }
public actor BiliService {
  private nonisolated let credentials: any AuthCredentialStore
  private let transport: any AuthTransport
  /// The proxied path for region-locked requests (see `RegionRoute`), when a proxy is configured.
  private var proxyTransport: (any AuthTransport)?
  private var regionRoute = RegionRoute.off
  /// After a region-limited request succeeded through the proxy, related requests skip the
  /// failing direct attempt for a while.
  private var regionStickyUntil = Date.distantPast
  public private(set) var regionRetries = 0
  static let regionLimitedCodes: Set<Int> = [-10403, 6002003]
  private let now: @Sendable () -> Date
  private let localID: String
  private var jar = BiliCookieJar()
  private var appToken: AppToken?
  private var keys: (String, String)?
  /// When `keys` were fetched; Bilibili rotates the WBI keys daily, so they expire after
  /// `wbiKeyLifetime` and are fetched again before the next signed request.
  private var keysFetchedAt: Date?
  static let wbiKeyLifetime: TimeInterval = 6 * 3600
  private var wbiKeysStale: Bool {
    guard keys != nil, let fetched = keysFetchedAt else { return true }
    let age = now().timeIntervalSince(fetched)
    return age < 0 || age > Self.wbiKeyLifetime
  }
  private var authEpoch: UInt64 = 0
  private var identityRevision: UInt64 = 0
  private var requests: [UUID: Task<AuthHTTPResponse, Error>] = [:]
  #if DEBUG
  private var transportDispatchBarrierForTesting: (@Sendable (URLRequest) async -> Void)?
  func setTransportDispatchBarrierForTesting(_ barrier: (@Sendable (URLRequest) async -> Void)?) {
    transportDispatchBarrierForTesting = barrier
  }
  #endif
  private var rpcRequests: [UUID: @Sendable () -> Void] = [:]
  private var identityObservers: [UUID: AsyncStream<AuthIdentityEvent>.Continuation] = [:]
  private var refreshTask: AuthRefreshFlight?
  private var tvCodes: Set<String> = []
  /// /x/player/wbi/v2 results shared by subtitle playback and AI, per media and identity.
  var playerMetadataCache = PlayerMetadataCache()
  public init(
    session: URLSession? = nil, transport: (any AuthTransport)? = nil,
    credentials: any AuthCredentialStore = CredentialStore(),
    now: @escaping @Sendable () -> Date = { Date() },
    localID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
    webDeviceCookies: Bool = false
  ) {
    usesWebDeviceCookies = webDeviceCookies
    self.transport = transport ?? IsolatedAuthTransport(configuration: session?.configuration ?? .ephemeral)
    self.credentials = credentials
    self.now = now
    self.localID = localID
  }
  private func invalidateIdentity() {
    identityRevision &+= 1
    appToken = nil
    keys = nil
    for task in requests.values { task.cancel() }
    requests.removeAll()
    for cancel in rpcRequests.values { cancel() }
    rpcRequests.removeAll()
    refreshTask?.task.cancel()
    refreshTask = nil
  }
  private func invalidate() {
    authEpoch &+= 1
    // A new login invalidates responses without prematurely discarding the current identity.
    let current = appToken
    invalidateIdentity()
    appToken = current
    tvCodes.removeAll()
  }
  public func beginLogin() -> UInt64 {
    invalidate()
    publishIdentity()
    return authEpoch
  }
  /// Reads saved credentials without entering the actor. A Keychain read can block on the
  /// system authorization prompt; doing it here keeps every other request (anonymous browsing,
  /// playback) running while the prompt waits.
  public nonisolated func loadStoredCredentials() throws -> StoredCredentials {
    let stored = try credentials.loadAll()
    return StoredCredentials(cookies: stored.cookies, token: stored.token)
  }
  public struct StoredCredentials: @unchecked Sendable {
    public let cookies: [HTTPCookie]
    public let token: AppToken?
  }
  public func restoreCookies() throws {
    try restore(try loadStoredCredentials())
  }
  /// Applies credentials read off the actor. With `expected`, nothing changes when a logout or
  /// another login happened while the Keychain was being read: the snapshot is stale and must
  /// neither replace the new identity nor delete its token. Returns false in that case.
  @discardableResult
  public func restore(_ stored: StoredCredentials, ifUnchangedSince expected: AuthSnapshot? = nil) throws -> Bool {
    if let expected, expected.epoch != authEpoch || expected.identityRevision != identityRevision { return false }
    defer { publishIdentity() }
    invalidateIdentity()
    // Device cookies identify the browser, not the account; keep them across a restore.
    let device = jar.cookies.filter { Self.deviceCookieNames.contains($0.name) }
    jar = BiliCookieJar()
    jar.merge(device, now: now())
    jar.merge(stored.cookies, now: now())
    let token = stored.token
    if let token, !cookiesMatch(token, jar: jar) {
      appToken = nil
      try credentials.saveToken(nil)
      throw AuthFailure.invalidResponse
    }
    appToken = token
    return true
  }
  public func synchronizeCookies(_ cookies: [HTTPCookie], token: UInt64) throws -> Bool {
    try Task.checkCancellation()
    guard token == authEpoch else { return false }
    var replacement = BiliCookieJar()
    replacement.merge(cookies, now: now())
    try persistIdentity(replacement, token: nil, replacingIdentity: true)
    return true
  }
  public func logout() throws {
    defer { publishIdentity() }
    invalidate()
    jar = BiliCookieJar()
    appToken = nil
    keys = nil
    try credentials.clear()
  }
  public func loginCookies() -> [HTTPCookie] { jar.cookies }
  public func authSnapshot() -> AuthSnapshot {
    let valid = appToken.flatMap {
      $0.isComplete && $0.expiresAt > Int64(now().timeIntervalSince1970) ? $0 : nil
    }
    let web = jar.matching(URL(string: "https://www.bilibili.com/")!, now: now()).contains {
      $0.name == "SESSDATA" && !$0.value.isEmpty
    }
    return AuthSnapshot(
      epoch: authEpoch, identityRevision: identityRevision,
      state: valid != nil ? .appAuthorized : web ? .webOnly : .needsLogin,
      token: valid)
  }
  public func identityEvents() -> AsyncStream<AuthIdentityEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<AuthIdentityEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    identityObservers[id] = continuation
    continuation.yield(identityEvent())
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeIdentityObserver(id) }
    }
    return stream
  }
  private func removeIdentityObserver(_ id: UUID) {
    identityObservers.removeValue(forKey: id)
  }
  private func identityEvent() -> AuthIdentityEvent {
    let snapshot = authSnapshot()
    return AuthIdentityEvent(
      epoch: snapshot.epoch, identityRevision: snapshot.identityRevision,
      state: snapshot.state, mid: snapshot.token?.mid)
  }
  private func publishIdentity() {
    let event = identityEvent()
    for continuation in identityObservers.values { continuation.yield(event) }
  }
  deinit {
    for continuation in identityObservers.values { continuation.finish() }
  }
  // Capture and register on this actor: a refresh or account change cannot mix two identities.
  func withRPCIdentity<Value: Sendable>(
    requireToken: Bool, expectedIdentity: AuthSnapshot? = nil,
    operation: @escaping @Sendable (AuthSnapshot) async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    let epoch = authEpoch
    let revision = identityRevision
    if requireToken {
      let token = try await ensureAppToken()
      try checkIdentity(revision, epoch: epoch)
      guard authSnapshot().token == token else { throw CancellationError() }
    }
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    let snapshot = authSnapshot()
    let id = UUID()
    let task = Task {
      try Task.checkCancellation()
      return try await operation(snapshot)
    }
    rpcRequests[id] = { task.cancel() }
    defer { rpcRequests.removeValue(forKey: id) }
    do {
      let value = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      try checkIdentity(snapshot.identityRevision, epoch: snapshot.epoch)
      return value
    } catch {
      try checkIdentity(snapshot.identityRevision, epoch: snapshot.epoch)
      throw error
    }
  }
  private func checkEpoch(_ epoch: UInt64) throws {
    try Task.checkCancellation()
    guard epoch == authEpoch else { throw CancellationError() }
  }
  private func checkIdentity(_ revision: UInt64, epoch: UInt64) throws {
    try checkEpoch(epoch)
    guard revision == identityRevision else { throw CancellationError() }
  }
  private func cookiesMatch(_ token: AppToken, jar: BiliCookieJar) -> Bool {
    jar.cookies.filter { $0.name == "DedeUserID" }.allSatisfy { Int64($0.value) == token.mid }
  }
  private func persistIdentity(
    _ replacement: BiliCookieJar, token: AppToken?, replacingIdentity: Bool,
    publishingIdentity: Bool = true
  ) throws {
    defer { if publishingIdentity { publishIdentity() } }
    if replacingIdentity { invalidateIdentity() }
    appToken = nil
    // Do not write a new Cookie identity unless the old Token was reliably removed.
    try credentials.saveToken(nil)
    try credentials.save(replacement.cookies)
    jar = replacement
    if let token {
      do { try credentials.saveToken(token) } catch {
        // A failed write must never restore the old identity in memory.
        try? credentials.saveToken(nil)
        throw error
      }
      appToken = token
    }
  }
  /// A complete desktop browser user agent. The bare "Mozilla/5.0" used before trips
  /// Bilibili's risk control (HTTP 412) on several web endpoints.
  public static let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
  public nonisolated func request(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    return request
  }
  /// Web device cookies (`buvid3`/`buvid4`/`b_nut`) that Bilibili's risk control expects on
  /// api.bilibili.com. Fetched once from the public `finger/spi` endpoint when missing; they
  /// identify the device, not the account, and are never persisted with login credentials.
  private let usesWebDeviceCookies: Bool
  private var deviceCookieAttempt: Date?
  private var deviceCookieTask: Task<Void, Never>?
  static let deviceCookieNames: Set<String> = ["buvid3", "buvid4", "b_nut"]
  private func ensureDeviceCookies() async {
    guard usesWebDeviceCookies,
      !jar.matching(URL(string: "https://api.bilibili.com/")!, now: now()).contains(where: { $0.name == "buvid3" })
    else { return }
    // Concurrent first requests wait for the same fetch instead of going out without buvid.
    if let running = deviceCookieTask { await running.value; return }
    // At most one attempt a minute, so an offline start does not add a request per call.
    if let last = deviceCookieAttempt, now().timeIntervalSince(last) < 60 { return }
    deviceCookieAttempt = now()
    let task = Task { await self.fetchDeviceCookies() }
    deviceCookieTask = task
    await task.value
    deviceCookieTask = nil
  }
  private func fetchDeviceCookies() async {
    // Routed like every other API request: in `.always` the device id must not leak out directly.
    let transport = routedTransport()
    guard let response = try? await transport.send(request(URL(string: "https://api.bilibili.com/x/frontend/finger/spi")!)),
      let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let data = root["data"] as? [String: Any], let b3 = data["b_3"] as? String, !b3.isEmpty
    else { return }
    let expiry = now().addingTimeInterval(365 * 24 * 3600)
    var cookies: [HTTPCookie] = []
    for (name, value) in [("buvid3", b3), ("buvid4", data["b_4"] as? String ?? ""), ("b_nut", String(Int(now().timeIntervalSince1970)))]
    where !value.isEmpty {
      if let cookie = HTTPCookie(properties: [.name: name, .value: value, .domain: ".bilibili.com", .path: "/", .expires: expiry, .secure: "FALSE"]) {
        cookies.append(cookie)
      }
    }
    jar.merge(cookies, now: now())
  }
  private func send(
    _ base: URLRequest, epoch: UInt64, useCookies: Bool = true, receiveCookies: Bool = true,
    beforeSend: @escaping @Sendable () throws -> Void = {}
  ) async throws
    -> AuthHTTPResponse
  {
    try checkEpoch(epoch)
    let revision = identityRevision
    var request = base
    if useCookies, let url = request.url {
      request.setValue(jar.header(url, now: now()), forHTTPHeaderField: "Cookie")
    }
    let id = UUID()
    let transport = routedTransport()
    #if DEBUG
    let dispatchBarrier = transportDispatchBarrierForTesting
    #endif
    let task = Task {
      #if DEBUG
      if let dispatchBarrier { await dispatchBarrier(request) }
      #endif
      // This task may start after its caller's checks. Revalidate at the actual transport
      // handoff, after every dispatch suspension, while still isolated to this service.
      try Task.checkCancellation()
      try self.checkIdentity(revision, epoch: epoch)
      try beforeSend()
      return try await transport.send(request)
    }
    requests[id] = task
    defer { requests[id] = nil }
    let result: AuthHTTPResponse
    do {
      result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      try checkIdentity(revision, epoch: epoch)
    } catch {
      try checkIdentity(revision, epoch: epoch)
      throw error
    }
    guard (200..<300).contains(result.response.statusCode) else {
      throw BiliError.http(result.response.statusCode)
    }
    if receiveCookies { jar.receive(result.response, now: now()) }
    return result
  }
  /// The proxied path when this task asks for it (`BiliRoute.viaProxy`) or every request uses it.
  private func routedTransport() -> any AuthTransport {
    guard let proxyTransport, BiliRoute.viaProxy || regionRoute == .always else { return transport }
    return proxyTransport
  }
  /// Routes region-locked requests through `transport` (nil turns the proxy path off).
  public func setProxy(_ transport: (any AuthTransport)?, region: RegionRoute) {
    proxyTransport = transport
    regionRoute = transport == nil ? .off : region
    if transport == nil { regionStickyUntil = .distantPast }
  }

  /// Runs a request that mainland copyright may block for overseas users. In `.auto` it goes
  /// direct first and repeats through the proxy once when the API reports a region limit; after
  /// such a success, related requests use the proxy straight away for ten minutes.
  func regionAware<T>(_ body: () async throws -> T) async throws -> T {
    guard regionRoute == .auto, proxyTransport != nil, !BiliRoute.viaProxy else { return try await body() }
    if now() < regionStickyUntil { return try await BiliRoute.$viaProxy.withValue(true) { try await body() } }
    do {
      return try await body()
    } catch BiliError.api(let code, _) where Self.regionLimitedCodes.contains(code) {
      regionRetries += 1
      let value = try await BiliRoute.$viaProxy.withValue(true) { try await body() }
      regionStickyUntil = now().addingTimeInterval(600)
      return value
    }
  }

  /// A cookie the jar would send to bilibili.com (device ids, CSRF), or nil.
  public func cookieValue(_ name: String) -> String? {
    jar.matching(URL(string: "https://api.bilibili.com/")!, now: now()).first { $0.name == name && !$0.value.isEmpty }?.value
  }
  public func data(_ url: URL) async throws -> Data {
    if url.host == "api.bilibili.com" || url.host == "api.live.bilibili.com" { await ensureDeviceCookies() }
    return try await send(request(url), epoch: authEpoch).body
  }
  public func json(_ path: String, params: [String: String] = [:], signed: Bool = false)
    async throws -> [String: Any]
  {
    do {
      return try await envelope(path, params: params, signed: signed)
    } catch BiliError.api(let code, _) where signed && (code == -403 || code == -352) {
      // A signature made with keys rotated since they were fetched: fetch them again and retry once.
      keys = nil
      return try await envelope(path, params: params, signed: signed)
    }
  }
  private func envelope(_ path: String, params: [String: String], signed: Bool) async throws -> [String: Any] {
    let epoch = authEpoch
    let revision = identityRevision
    var parts = URLComponents(
      string: path.hasPrefix("https:") ? path : "https://api.bilibili.com" + path)!
    if signed {
      if wbiKeysStale { try await refreshKeys() }
      try checkIdentity(revision, epoch: epoch)
      guard let keys else { throw BiliError.invalidResponse("Missing WBI keys") }
      parts.percentEncodedQuery = try WBI.sign(params, imageKey: keys.0, subKey: keys.1)
    } else {
      parts.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    let body = try await data(parts.url!)
    try checkIdentity(revision, epoch: epoch)
    guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw BiliError.invalidResponse("Invalid JSON envelope")
    }
    let code = json["code"] as? Int ?? -1
    guard code == 0 else {
      throw BiliError.api(code, "请求失败")
    }
    guard let payload = json["data"] as? [String: Any] else {
      throw BiliError.invalidResponse("Missing data object")
    }
    return payload
  }
  /// The signed-in account for data ownership: the App token's mid, else the web login's
  /// DedeUserID while a SESSDATA cookie exists. nil when nobody is signed in.
  public func accountMid() -> Int64? {
    if let mid = authSnapshot().token?.mid, mid > 0 { return mid }
    guard cookieValue("SESSDATA") != nil, let raw = cookieValue("DedeUserID"), let mid = Int64(raw), mid > 0 else { return nil }
    return mid
  }
  /// WBI-signed GET returning the raw body, so callers can interpret non-zero envelope codes.
  func wbiSignedBody(_ path: String, params: [String: String], expectedIdentity: AuthSnapshot) async throws -> Data {
    let body = try await signedBody(path, params: params, expectedIdentity: expectedIdentity)
    // A signature made with rotated keys: fetch them again and retry once, as `json` does.
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let code = root["code"] as? Int, code == -403 || code == -352 else { return body }
    keys = nil
    return try await signedBody(path, params: params, expectedIdentity: expectedIdentity)
  }
  private func signedBody(_ path: String, params: [String: String], expectedIdentity: AuthSnapshot) async throws -> Data {
    try checkRESTIdentity(expectedIdentity)
    if wbiKeysStale { try await refreshKeys() }
    try checkRESTIdentity(expectedIdentity)
    guard let keys else { throw BiliError.invalidResponse("Missing WBI keys") }
    var parts = URLComponents(string: "https://api.bilibili.com" + path)!
    parts.percentEncodedQuery = try WBI.sign(params, imageKey: keys.0, subKey: keys.1)
    let body = try await data(parts.url!)
    try checkRESTIdentity(expectedIdentity)
    return body
  }
  public func refreshKeys() async throws {
    // Anonymous nav returns -101 but still supplies wbi_img.
    let body = try await data(URL(string: "https://api.bilibili.com/x/web-interface/nav")!)
    guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
      let payload = root["data"] as? [String: Any], let wbi = payload["wbi_img"] as? [String: Any],
      let image = wbi["img_url"] as? String, let sub = wbi["sub_url"] as? String,
      let imageURL = URL(string: image), let subURL = URL(string: sub)
    else { throw BiliError.invalidResponse("Missing WBI nav keys") }
    let first = imageURL.deletingPathExtension().lastPathComponent
    let second = subURL.deletingPathExtension().lastPathComponent
    _ = try WBI.mixinKey(imageKey: first, subKey: second)
    keys = (first, second)
    keysFetchedAt = now()
  }
  public func popular(page: Int = 1) async throws -> [Video] {
    let payload = try await json(
      "/x/web-interface/popular", params: ["pn": String(page), "ps": "24"])
    return try (payload["list"] as? [[String: Any]] ?? []).map(Video.parse)
  }
  public func detail(_ bvid: String, expectedIdentity: AuthSnapshot? = nil) async throws -> Video {
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    // The unsigned /x/web-interface/view answers HTTP 412 under risk control; the WBI-signed
    // variant is what the web player itself uses.
    let payload = try await json("/x/web-interface/wbi/view", params: ["bvid": bvid], signed: true)
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    return try Video.parse(payload)
  }
  public func playback(_ video: Video, quality: Int? = nil, expectedIdentity: AuthSnapshot? = nil) async throws -> PlaybackManifest {
    try await regionAware { try await unroutedPlayback(video, quality: quality, expectedIdentity: expectedIdentity) }
  }
  private func unroutedPlayback(_ video: Video, quality: Int?, expectedIdentity: AuthSnapshot?) async throws -> PlaybackManifest {
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    let epoch = authEpoch
    let revision = identityRevision
    let useApp = appToken != nil
    do {
      guard let cid = video.cid, cid > 0 else { throw BiliError.invalidResponse("Missing cid") }
      let payload: [String: Any]
      if useApp {
        // Authorize before resolving an AV identifier: failures must not become anonymous playback.
        _ = try await ensureAppToken()
        try checkIdentity(revision, epoch: epoch)
        let aid: Int64
        if let value = video.aid, value > 0 {
          aid = value
        } else {
          guard !video.bvid.isEmpty else { throw BiliError.invalidResponse("Missing aid/bvid") }
          let resolved = try await detail(video.bvid, expectedIdentity: expectedIdentity)
          try checkIdentity(revision, epoch: epoch)
          guard let value = resolved.aid, value > 0 else {
            throw BiliError.invalidResponse("Missing aid")
          }
          aid = value
        }
        payload = try await appObject(
          .playback,
          fields: [
            "fnver": "0", "cid": String(cid), "fourk": "1", "fnval": "4048", "qn": String(quality ?? 64),
            "oType": "json", "avid": String(aid),
          ], expectedIdentity: expectedIdentity)
      } else {
        var params = ["cid": String(cid), "qn": String(quality ?? 127), "fnval": "4048", "fourk": "1"]
        if let aid = video.aid, aid > 0 {
          params["avid"] = String(aid)
        } else if !video.bvid.isEmpty {
          params["bvid"] = video.bvid
        } else {
          throw BiliError.invalidResponse("Missing aid/bvid")
        }
        payload = try await json("/x/player/wbi/playurl", params: params, signed: true)
      }
      try checkIdentity(revision, epoch: epoch)
      return try PlaybackManifest.parse(payload)
    } catch {
      try checkIdentity(revision, epoch: epoch)
      throw error
    }
  }

  func checkRESTIdentity(_ snapshot: AuthSnapshot) throws {
    try checkIdentity(snapshot.identityRevision, epoch: snapshot.epoch)
  }

  func liveBuvid(expectedIdentity: AuthSnapshot) throws -> String {
    try checkRESTIdentity(expectedIdentity)
    return jar.matching(LiveRoute.danmuInfo.url, now: now()).first { $0.name == "buvid3" && !$0.value.isEmpty }?.value ?? ""
  }

  /// Caller-owned identity boundary for live requests, including preparation awaits.
  public func liveRequest(_ route: LiveRoute, fields: [String: String] = [:],
    expectedIdentity: AuthSnapshot, gate: LiveMutationGate = LiveMutationGate()) async throws -> LiveEnvelope {
    let prepared = try await prepareLiveRequest(route, fields: fields, expectedIdentity: expectedIdentity, gate: gate)
    return try await executeLiveRequest(prepared)
  }

  func prepareLiveRequest(_ route: LiveRoute, fields: [String: String] = [:],
    expectedIdentity: AuthSnapshot, gate: LiveMutationGate = LiveMutationGate()) async throws -> LivePreparedRequest {
    try checkRESTIdentity(expectedIdentity)
    guard gate.allows(route) else { throw LiveRouteError.mutationClosed(route) }
    var (query, body) = try route.fields(fields, timestamp: Int64(now().timeIntervalSince1970))
    // Fail missing login/CSRF before device or WBI preparation can send anything.
    let cookies = jar.matching(route.url, now: now())
    if route.isMutation {
      guard cookies.contains(where: { $0.name == "SESSDATA" && !$0.value.isEmpty }) else { throw LiveRouteError.missingWebIdentity }
      guard let csrf = cookies.first(where: { $0.name == "bili_jct" && !$0.value.isEmpty })?.value else { throw AuthFailure.missingCSRF }
      switch route.csrf {
      case .none: break
      case .query: query["csrf"] = csrf
      case .form: body["csrf"] = csrf
      case .formBoth: body["csrf"] = csrf; body["csrf_token"] = csrf
      }
      for key in ["uid"] where fields[key] != nil {
        guard fields[key] == accountMid().map(String.init) else { throw CancellationError() }
      }
    }
    await ensureDeviceCookies()
    try checkRESTIdentity(expectedIdentity)
    var target = URLComponents(url: route.url, resolvingAgainstBaseURL: false)!
    if route.signedQuery {
      if wbiKeysStale { try await refreshKeys() }
      try checkRESTIdentity(expectedIdentity)
      guard let keys else { throw BiliError.invalidResponse("Missing WBI keys") }
      target.percentEncodedQuery = try WBI.sign(query, imageKey: keys.0, subKey: keys.1, timestamp: Int(now().timeIntervalSince1970))
    } else { target.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) } }
    var outgoing = request(target.url!)
    outgoing.httpMethod = route.method
    outgoing.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
    outgoing.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
    if route.isMutation, !body.isEmpty {
      outgoing.httpBody = AppForm.encoded(body)
      outgoing.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    try checkRESTIdentity(expectedIdentity)
    return LivePreparedRequest(request: outgoing, identity: expectedIdentity)
  }

  func executeLiveRequest(_ prepared: LivePreparedRequest, beforeSend: @escaping @Sendable () throws -> Void = {}) async throws -> LiveEnvelope {
    try checkRESTIdentity(prepared.identity)
    try beforeSend()
    let response = try await send(prepared.request, epoch: prepared.identity.epoch, receiveCookies: false, beforeSend: beforeSend)
    try checkRESTIdentity(prepared.identity)
    return try LiveEnvelope.parse(response.body)
  }

  /// Refreshes expired App authorization while preserving the caller's account boundary.
  public func authorizeAppInteraction(expectedIdentity: AuthSnapshot? = nil) async throws -> AuthSnapshot {
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    let before = authSnapshot()
    _ = try await ensureAppToken()
    try checkRESTIdentity(before)
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    return authSnapshot()
  }

  public func webVideoOperationState(aid: Int64, expectedIdentity: AuthSnapshot) async throws -> VideoOperationState {
    try checkRESTIdentity(expectedIdentity)
    guard aid > 0 else { throw BiliError.invalidResponse("Invalid identifier") }
    guard jar.matching(URL(string: "https://api.bilibili.com/")!, now: now()).contains(where: {
      $0.name == "SESSDATA" && !$0.value.isEmpty
    }) else { throw BiliError.dependency("互动状态需要网页登录，当前账号没有有效的网页登录会话。") }
    // Exact PlayerClient.GetWebVideoOperationInformationAsync: WBI, cookies, no access_key.
    let payload = try await json("/x/web-interface/archive/relation", params: ["aid": String(aid)], signed: true)
    try checkRESTIdentity(expectedIdentity)
    return try VideoOperationState.parse(payload)
  }

  // Closed routes prevent a signed access_key from being attached to a caller-supplied URL.
  func appREST(
    _ route: BiliAppRoute, fields: [String: String] = [:], expectedIdentity: AuthSnapshot? = nil,
    beforeSend: @escaping @Sendable () throws -> Void = {}
  ) async throws -> Any? {
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    let epoch = authEpoch
    let revision = identityRevision
    do {
      try checkIdentity(revision, epoch: epoch)
      let token: AppToken?
      if route != .curated && route != .searchTrending && (route.requiresToken || appToken != nil) {
        token = try await ensureAppToken()
        try checkIdentity(revision, epoch: epoch)
        guard appToken == token else { throw CancellationError() }
        if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
      } else {
        token = nil
      }
      var fields = fields
      if route == .searchTrending {
        fields["csrf"] = jar.matching(URL(string: route.url)!, now: now())
          .first(where: { $0.name == "bili_jct" })?.value ?? ""
        fields["access_key"] = nil
      }
      if route == .curated {
        let cookies = jar.matching(URL(string: route.url)!, now: now())
        guard cookies.contains(where: { $0.name == "SESSDATA" && !$0.value.isEmpty }),
          let csrf = cookies.first(where: { $0.name == "bili_jct" && !$0.value.isEmpty })?.value
        else { throw BiliError.dependency("精选推荐需要网页登录，请先登录并同步网页登录会话。") }
        fields["csrf"] = csrf
        fields["access_key"] = nil
      }
      if route == .playback { fields["mid"] = token.map { String($0.mid) } }
      if [.favoriteFolders, .libraryGallery, .libraryFolders].contains(route) {
        fields["up_mid"] = token.map { String($0.mid) }
      }
      if route == .followGroupUsers { fields["mid"] = token.map { String($0.mid) } }
      if [.articleRecommend, .articleList].contains(route) { fields["mid"] = token.map { String($0.mid) } }
      let cookieMutation = [.articleLike, .articleFavoriteAdd, .articleFavoriteDelete, .danmakuSend].contains(route)
      if cookieMutation {
        let cookies = jar.matching(URL(string: route.url)!, now: now())
        guard cookies.contains(where: { $0.name == "SESSDATA" && !$0.value.isEmpty }),
          let csrf = cookies.first(where: { $0.name == "bili_jct" && !$0.value.isEmpty })?.value
        else { throw AuthFailure.missingCSRF }
        fields["csrf"] = csrf
      }
      // PGC mutations retain the fixed SDK's App-token/no-Cookie protocol.
      // Read CSRF only after token refresh and identity checks from this actor's
      // current cookie jar. Token-only identities remain valid App signers.
      if [.pgcFollowAdd, .pgcFollowDelete, .pgcLike, .pgcCoin, .pgcTriple, .pgcFavorite].contains(route) {
        let cookies = jar.matching(URL(string: route.url)!, now: now())
        fields["csrf"] = cookies.first(where: { $0.name == "bili_jct" && !$0.value.isEmpty })?.value
      }
      let form = route == .pgcPlayback ? AppForm.webAuthorized(
        fields, timestampMilliseconds: Int64(now().timeIntervalSince1970 * 1000), accessKey: token?.accessToken)
        : AppForm.authorized(
        fields, timestamp: Int64(now().timeIntervalSince1970),
        accessKey: token?.accessToken)
      var url = URLComponents(string: route.url)!
      if !route.isMutation { url.percentEncodedQuery = String(decoding: form, as: UTF8.self) }
      var request = request(url.url!)
      if route.isMutation {
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
      }
      try checkIdentity(revision, epoch: epoch)
      if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
      try beforeSend()
      let response = try await send(request, epoch: epoch,
        useCookies: cookieMutation || route == .librarySeasonContents || route == .curated, receiveCookies: false,
        beforeSend: beforeSend)
      try checkIdentity(revision, epoch: epoch)
      guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
        let code = root["code"] as? Int
      else {
        throw BiliError.invalidResponse("Invalid App response envelope")
      }
      guard code == 0 else { throw BiliError.api(code, "请求失败") }
      if [.favoriteBangumi, .favoriteCinema, .pgcTimeline, .pgcPlayback].contains(route) { return root["data"] ?? root["result"] }
      return root["data"]
    } catch {
      try checkIdentity(revision, epoch: epoch)
      throw error
    }
  }

  func appObject(
    _ route: BiliAppRoute, fields: [String: String] = [:], expectedIdentity: AuthSnapshot? = nil
  ) async throws -> [String: Any] {
    guard let object = try await appREST(route, fields: fields, expectedIdentity: expectedIdentity) as? [String: Any] else {
      throw BiliError.invalidResponse("Missing App data object")
    }
    return object
  }
  // The reader fetches inert HTML from one fixed public route; it never executes scripts.
  func articleNativeHTML(id: Int64, expectedIdentity: AuthSnapshot) async throws -> String {
    try checkRESTIdentity(expectedIdentity)
    guard id > 0 else { throw BiliError.invalidResponse("Invalid article identifier") }
    var url = URLComponents(string: "https://www.bilibili.com/read/native/")!
    url.queryItems = [URLQueryItem(name: "id", value: String(id))]
    let body = try await send(request(url.url!), epoch: expectedIdentity.epoch,
      useCookies: false, receiveCookies: false).body
    try checkRESTIdentity(expectedIdentity)
    guard body.count <= 8 * 1024 * 1024, let html = String(data: body, encoding: .utf8) else {
      throw BiliError.invalidResponse("Invalid native article HTML")
    }
    return html
  }

  func messageWebREST(_ route: BiliMessageWebRoute, fields: [String: String] = [:],
    expectedIdentity: AuthSnapshot? = nil) async throws -> Any? {
    guard route != .send else { throw BiliError.invalidResponse("Use explicit message send") }
    return try await messageWebRequest(route, fields: fields, expectedIdentity: expectedIdentity ?? authSnapshot())
  }

  func messageWebSend(fields: [String: String], expectedIdentity: AuthSnapshot) async throws -> [String: Any] {
    guard let object = try await messageWebRequest(.send, fields: fields, expectedIdentity: expectedIdentity) as? [String: Any] else {
      throw BiliError.invalidResponse("Invalid message send response")
    }
    return object
  }

  private func messageWebRequest(_ route: BiliMessageWebRoute, fields: [String: String],
    expectedIdentity: AuthSnapshot) async throws -> Any? {
    try checkRESTIdentity(expectedIdentity)
    let target = URL(string: route.url)!
    var values = fields
    values["access_key"] = nil; values["sign"] = nil; values["w_rid"] = nil
    if route == .send {
      let token = try await ensureAppToken()
      try checkRESTIdentity(expectedIdentity)
      guard values["msg[sender_uid]"] == String(token.mid),
        expectedIdentity.token?.mid == token.mid else { throw CancellationError() }

    }
    if wbiKeysStale { try await refreshKeys() }
    try checkRESTIdentity(expectedIdentity)
    guard let keys else { throw BiliError.invalidResponse("Missing WBI keys") }
    let cookies = jar.matching(target, now: now())
    guard cookies.contains(where: { $0.name == "SESSDATA" && !$0.value.isEmpty }) else {
      throw BiliError.dependency("私信需要有效的网页登录信息，请重新登录。")
    }
    if route.isPOST {
      guard let csrf = cookies.first(where: { $0.name == "bili_jct" && !$0.value.isEmpty })?.value else {
        throw AuthFailure.missingCSRF
      }
      values["csrf"] = csrf; values["csrf_token"] = csrf
    }
    let seconds = Int64(now().timeIntervalSince1970)
    values["build"] = "80200100"
    values["appkey"] = route == .users ? "aa1e74ee4874176e" : AppForm.appKey
    values["platform"] = route == .users ? "web" : "ios"
    values["mobi_app"] = route == .users ? nil : (route.isPOST && route != .send ? "web" : "iphone")
    values["ts"] = String(route == .users ? Int64(now().timeIntervalSince1970 * 1000) : seconds)
    values["wts"] = String(seconds)
    // Exact SDK GenerateRID signs raw values, preserving message punctuation in the form body.
    let query = values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
    values["w_rid"] = WBI.md5(query + (try WBI.mixinKey(imageKey: keys.0, subKey: keys.1)))
    let form = AppForm.encoded(values)
    var components = URLComponents(url: target, resolvingAgainstBaseURL: false)!
    if !route.isPOST { components.percentEncodedQuery = String(decoding: form, as: UTF8.self) }
    var request = request(components.url!)
    if route.isPOST {
      request.httpMethod = "POST"; request.httpBody = form
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    try checkRESTIdentity(expectedIdentity)
    let body = try await send(request, epoch: expectedIdentity.epoch,
      useCookies: true, receiveCookies: false).body
    try checkRESTIdentity(expectedIdentity)
    guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
      let code = root["code"] as? Int else { throw BiliError.invalidResponse("Invalid message envelope") }
    guard code == 0 else { throw BiliError.api(code, "请求失败") }
    return root["data"]
  }

  func subtitleMetadataObject(aid: Int64, cid: Int64, expectedIdentity: AuthSnapshot) async throws -> [String: Any] {
    try checkRESTIdentity(expectedIdentity)
    guard aid > 0, cid > 0 else { throw BiliError.invalidResponse("Invalid subtitle identifiers") }
    var url = URLComponents(string: "https://api.bilibili.com/x/player/wbi/v2")!
    url.percentEncodedQuery = String(decoding: AppForm.authorized(["aid": String(aid), "cid": String(cid)],
      timestamp: Int64(now().timeIntervalSince1970)), as: UTF8.self)
    let body = try await send(request(url.url!), epoch: expectedIdentity.epoch, useCookies: true, receiveCookies: false).body
    try checkRESTIdentity(expectedIdentity)
    guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any], let code = root["code"] as? Int else {
      throw BiliError.invalidResponse("Invalid subtitle metadata envelope")
    }
    guard code == 0 else { throw BiliError.api(code, "没能获取字幕信息") }
    guard let data = root["data"] as? [String: Any] else { throw BiliError.invalidResponse("Missing subtitle metadata") }
    return data
  }
  func subtitleBodyData(_ url: URL, expectedIdentity: AuthSnapshot) async throws -> Data {
    try checkRESTIdentity(expectedIdentity)
    let host = url.host?.lowercased() ?? ""
    guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
      host == "hdslb.com" || host.hasSuffix(".hdslb.com"),
      url.path.hasPrefix("/bfs/subtitle/") || url.path.hasPrefix("/bfs/ai_subtitle/") else {
      throw BiliError.invalidResponse("Untrusted subtitle URL")
    }
    let body = try await send(request(url), epoch: expectedIdentity.epoch, useCookies: false, receiveCookies: false).body
    try checkRESTIdentity(expectedIdentity)
    guard body.count <= 16 * 1024 * 1024 else { throw BiliError.invalidResponse("Subtitle file is too large") }
    return body
  }
  public func exportDanmakuXML(cid: Int64, expectedIdentity: AuthSnapshot) async throws -> Data {
    try checkRESTIdentity(expectedIdentity)
    guard cid > 0 else { throw BiliError.invalidResponse("Invalid danmaku identifier") }
    let body = try await data(URL(string: "https://api.bilibili.com/x/v1/dm/list.so?oid=\(cid)")!)
    try checkRESTIdentity(expectedIdentity)
    guard body.count <= 64 * 1024 * 1024, let xml = String(data: body, encoding: .utf8), xml.contains("<i>") || xml.contains("<i ") else {
      throw BiliError.invalidResponse("Invalid danmaku XML")
    }
    return body
  }
  public func comments(cid: Int64, expectedIdentity: AuthSnapshot? = nil) async throws -> [DanmakuComment] {
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    let body = try await data(URL(string: "https://api.bilibili.com/x/v1/dm/list.so?oid=\(cid)")!)
    if let expectedIdentity { try checkRESTIdentity(expectedIdentity) }
    return try DanmakuParser.parse(body)
  }
  private func appPost(
    _ path: String, fields: [String: String], epoch: UInt64,
    accessKey: String? = nil, useCookies: Bool = false
  ) async throws -> [String: Any] {
    var request = request(URL(string: "https://passport.bilibili.com" + path)!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = AppForm.authorized(
      fields, timestamp: Int64(now().timeIntervalSince1970), accessKey: accessKey)
    let response: AuthHTTPResponse
    do {
      response = try await send(
        request, epoch: epoch, useCookies: useCookies, receiveCookies: false)
    } catch is CancellationError { throw CancellationError() } catch BiliError.http(let status) {
      try checkEpoch(epoch)
      throw AuthFailure.rejected(status)
    } catch {
      try checkEpoch(epoch)
      throw AuthFailure.transport
    }
    guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let code = root["code"] as? Int
    else { throw AuthFailure.invalidResponse }
    guard code == 0 else { throw AuthFailure.rejected(code) }
    return root["data"] as? [String: Any] ?? [:]
  }
  private func createTVQR(epoch: UInt64) async throws -> QRLogin {
    let payload = try await appPost(
      "/x/passport-tv-login/qrcode/auth_code", fields: ["local_id": localID], epoch: epoch)
    guard let raw = payload["url"] as? String, let url = URL(string: raw), url.scheme == "https",
      let key = payload["auth_code"] as? String, !key.isEmpty
    else { throw AuthFailure.invalidResponse }
    try checkEpoch(epoch)
    tvCodes.insert(key)
    return QRLogin(url: url, key: key, token: epoch)
  }
  public func beginQR() async throws -> QRLogin {
    try await createTVQR(epoch: beginLogin())
  }
  // Retain the Web protocol entry point for callers that explicitly need it.
  public func beginWebQR() async throws -> QRLogin {
    let epoch = beginLogin()
    let payload = try await json(
      "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")
    guard let raw = payload["url"] as? String, let url = URL(string: raw),
      let key = payload["qrcode_key"] as? String
    else { throw AuthFailure.invalidResponse }
    try checkEpoch(epoch)
    return QRLogin(url: url, key: key, token: epoch)
  }
  public func pollQR(_ key: String, token: UInt64) async throws -> QRStatus {
    try checkEpoch(token)
    if !tvCodes.contains(key) {
      var parts = URLComponents(
        string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll")!
      parts.queryItems = [URLQueryItem(name: "qrcode_key", value: key)]
      let response = try await send(request(parts.url!), epoch: token, receiveCookies: false)
      guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
        let code = root["code"] as? Int
      else { throw AuthFailure.invalidResponse }
      guard code == 0 else { throw AuthFailure.rejected(code) }
      guard let payload = root["data"] as? [String: Any] else { throw AuthFailure.invalidResponse }
      try checkEpoch(token)
      switch payload["code"] as? Int {
      case 86101: return .waiting
      case 86090: return .scanned
      case 86038: return .expired
      case 0:
        var replacement = BiliCookieJar()
        replacement.receive(response.response, now: now())
        try persistIdentity(replacement, token: nil, replacingIdentity: true)
        return .success
      default: throw AuthFailure.invalidResponse
      }
    }
    do {
      let payload = try await appPost(
        "/x/passport-tv-login/qrcode/poll",
        fields: ["auth_code": key, "local_id": localID, "guid": UUID().uuidString.lowercased()],
        epoch: token)
      _ = try saveToken(payload, epoch: token)
      return .success
    } catch AuthFailure.rejected(let code) {
      switch code {
      case 86101, 86039: return .waiting
      case 86090: return .scanned
      case 86038, -3: return .expired
      default: throw AuthFailure.rejected(code)
      }
    }
  }
  public func authorizeWebCookies(token: UInt64) async throws -> AuthSnapshot {
    try checkEpoch(token)
    let confirmURL = URL(
      string: "https://passport.bilibili.com/x/passport-tv-login/h5/qrcode/confirm")!
    guard
      let csrf = jar.matching(confirmURL, now: now()).first(where: { $0.name == "bili_jct" })?
        .value, !csrf.isEmpty
    else { throw AuthFailure.missingCSRF }
    let qr = try await createTVQR(epoch: token)
    _ = try await appPost(
      "/x/passport-tv-login/h5/qrcode/confirm", fields: ["auth_code": qr.key, "csrf": csrf],
      epoch: token, useCookies: true)
    // Bounded polling: preserve Web credentials if conversion fails or never completes.
    for _ in 0..<60 {
      switch try await pollQR(qr.key, token: token) {
      case .success: return authSnapshot()
      case .expired: throw AuthFailure.expired
      case .waiting, .scanned: try await Task.sleep(for: .seconds(1))
      }
    }
    throw AuthFailure.expired
  }
  private func saveToken(_ payload: [String: Any], epoch: UInt64, refreshing: AppToken? = nil)
    throws -> AppToken
  {
    try checkEpoch(epoch)
    guard let mid = payload["mid"] as? Int64, mid > 0,
      let access = payload["access_token"] as? String, !access.isEmpty,
      let refresh = payload["refresh_token"] as? String, !refresh.isEmpty,
      let ttl = payload["expires_in"] as? Int64, ttl > 0
    else { throw AuthFailure.invalidResponse }
    let timestamp = Int64(now().timeIntervalSince1970)
    let (expiry, overflow) = timestamp.addingReportingOverflow(ttl)
    guard !overflow else { throw AuthFailure.invalidResponse }
    let token = AppToken(mid: mid, accessToken: access, refreshToken: refresh, expiresAt: expiry)
    if let refreshing, refreshing.mid != mid { throw AuthFailure.invalidResponse }
    var replacement = refreshing == nil ? BiliCookieJar() : jar
    if let info = payload["cookie_info"] as? [String: Any],
      let records = info["cookies"] as? [[String: Any]]
    {
      // Upstream cookie resolver treats token cookies as Bili-wide name/value pairs.
      let cookies = records.compactMap { record -> HTTPCookie? in
        guard let name = record["name"] as? String, let value = record["value"] as? String else {
          return nil
        }
        var properties: [HTTPCookiePropertyKey: Any] = [
          .name: name, .value: value, .domain: ".bilibili.com", .path: "/", .secure: "TRUE",
        ]
        if let expires = record["expires"] as? Double, expires > 0 {
          properties[.expires] = Date(timeIntervalSince1970: expires)
        }
        return HTTPCookie(properties: properties)
      }
      if refreshing != nil { replacement = BiliCookieJar() }
      replacement.merge(cookies, now: now())
    }
    guard cookiesMatch(token, jar: replacement) else {
      if refreshing == nil {
        defer { publishIdentity() }
        invalidateIdentity()
        try credentials.saveToken(nil)
      }
      throw AuthFailure.invalidResponse
    }
    try persistIdentity(
      replacement, token: token, replacingIdentity: refreshing == nil,
      publishingIdentity: refreshing == nil)
    return token
  }
  public func ensureAppToken() async throws -> AppToken {
    try Task.checkCancellation()
    guard let current = appToken, current.isComplete else { throw AuthFailure.needsLogin }
    if current.expiresAt > Int64(now().timeIntervalSince1970) { return current }
    let epoch = authEpoch
    let revision = identityRevision
    let waiter = UUID()
    let flight: AuthRefreshFlight
    if let existing = refreshTask, existing.tryRegister(waiter) {
      flight = existing
    } else {
      flight = AuthRefreshFlight(
        task: Task { try await self.refresh(current, epoch: epoch, revision: revision) })
      guard flight.tryRegister(waiter) else { throw CancellationError() }
      refreshTask = flight
    }
    defer {
      flight.remove(waiter, cancelIfEmpty: false)
      if refreshTask?.id == flight.id && flight.isEmpty { refreshTask = nil }
    }
    let token = try await withTaskCancellationHandler {
      try await flight.task.value
    } onCancel: {
      flight.remove(waiter, cancelIfEmpty: true)
    }
    try checkIdentity(revision, epoch: epoch)
    return token
  }

  private func refresh(_ current: AppToken, epoch: UInt64, revision: UInt64) async throws
    -> AppToken
  {
    // Upstream refresh is a single POST. Retry one transport failure only, never a server rejection.
    for attempt in 0..<2 {
      do {
        try checkIdentity(revision, epoch: epoch)
        let payload = try await appPost(
          "/api/oauth2/refreshToken",
          fields: ["access_token": current.accessToken, "refresh_token": current.refreshToken],
          epoch: epoch, accessKey: current.accessToken)
        try checkIdentity(revision, epoch: epoch)
        let token = try saveToken(payload, epoch: epoch, refreshing: current)
        publishIdentity()
        return token
      } catch AuthFailure.transport where attempt == 0 {
        try checkIdentity(revision, epoch: epoch)
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        try checkIdentity(revision, epoch: epoch)
        defer { publishIdentity() }
        appToken = nil
        // Token failure invalidates RPC results, without cancelling this refresh or its waiters.
        identityRevision &+= 1
        for cancel in rpcRequests.values { cancel() }
        rpcRequests.removeAll()
        try credentials.saveToken(nil)
        throw error
      }
    }
    throw AuthFailure.needsLogin
  }
  public func appRESTParameters(_ fields: [String: String]) async throws -> Data {
    let token = try await ensureAppToken()
    return AppForm.authorized(
      fields, timestamp: Int64(now().timeIntervalSince1970), accessKey: token.accessToken)
  }
  public func accountName() async throws -> String {
    try await json("/x/web-interface/nav")["uname"] as? String ?? "已登录"
  }
}
