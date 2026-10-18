import Foundation
import Security

public protocol AuthCredentialStore: Sendable {
  func save(_ cookies: [HTTPCookie]) throws
  func load() throws -> [HTTPCookie]
  func saveToken(_ token: AppToken?) throws
  func loadToken() throws -> AppToken?
  func clear() throws
  /// Cookies and token in one read. Stores that keep both in one Keychain item override this,
  /// so a new app signature triggers a single authorization prompt instead of one per item.
  func loadAll() throws -> (cookies: [HTTPCookie], token: AppToken?)
}

extension AuthCredentialStore {
  public func loadAll() throws -> (cookies: [HTTPCookie], token: AppToken?) { (try load(), try loadToken()) }
}

public final class CredentialStore: AuthCredentialStore, Sendable {
  /// The Keychain items this store uses.
  enum Item: Sendable { case session, legacyCookies, legacyToken }
  /// One item holds cookies and token. macOS authorizes Keychain access per item and per app
  /// signature, so the earlier two-item layout asked for the password twice after every update.
  private static var session: [String: Any] { [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "io.github.pidean.manping.session.v2", kSecAttrAccount as String: "bilibili",
  ] }
  /// Pre-2026-10-18 layout: read once to migrate, removed on logout.
  private static var legacyCookies: [String: Any] { [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "io.github.pidean.manping.cookies", kSecAttrAccount as String: "bilibili",
  ] }
  private static var legacyToken: [String: Any] { [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "io.github.pidean.manping.token.v1", kSecAttrAccount as String: "bilibili",
  ] }
  fileprivate struct Session: Codable {
    var cookies: Data
    var token: AppToken?
    /// The proxy password shares this item, so adding a proxy costs no extra Keychain prompt.
    var proxySecret: String?
  }
  /// Raw item access; the Keychain in the app, memory in tests.
  struct Storage: Sendable {
    let read: @Sendable (Item) throws -> Data?
    let write: @Sendable (Item, Data) throws -> Void
    let delete: @Sendable (Item) throws -> Void
  }
  /// State shared by every store on the same storage. `lock` serializes each read-modify-write
  /// (and the cache update) across instances: the session item holds the account and the proxy
  /// password, so two unserialized writers could put back an account that was just signed out.
  final class Shared: @unchecked Sendable {
    let storage: Storage
    fileprivate let lock = NSRecursiveLock()
    /// The last session read or written by any instance; later reads in the same launch (the
    /// proxy password after the account) then need no second authorization.
    fileprivate var session: Session?
    init(storage: Storage) { self.storage = storage }
  }
  private static let keychain = Shared(storage: Storage(
    read: { try CredentialStore.read(CredentialStore.query($0)) },
    write: { try CredentialStore.write(CredentialStore.query($0), data: $1) },
    delete: { try CredentialStore.delete(CredentialStore.query($0)) }))
  private let shared: Shared

  public init() { shared = Self.keychain }
  init(shared: Shared) { self.shared = shared }

  public func loadAll() throws -> (cookies: [HTTPCookie], token: AppToken?) {
    let session = try shared.lock.withLock { try readSession() ?? migrate() }
    let token = session.token.flatMap { $0.isComplete ? $0 : nil }
    return (try Self.decodeCookies(session.cookies), token)
  }
  public func load() throws -> [HTTPCookie] { try loadAll().cookies }
  public func loadToken() throws -> AppToken? { try loadAll().token }

  public func save(_ cookies: [HTTPCookie]) throws {
    let encoded = try Self.encodeCookies(cookies)
    try update { $0.cookies = encoded }
  }
  public func saveToken(_ token: AppToken?) throws {
    try update { $0.token = token }
  }
  /// The proxy password, or nil. Uses the session already read this launch when there is one.
  public func proxySecret() throws -> String? {
    try shared.lock.withLock {
      if let cached = shared.session { return cached.proxySecret }
      return try readSession()?.proxySecret
    }
  }
  public func saveProxySecret(_ value: String?) throws {
    let secret = (value ?? "").isEmpty ? nil : value
    try update { $0.proxySecret = secret }
  }

  public func clear() throws {
    try shared.lock.withLock {
      // Attempt every removal even if one item requires OS authorization.
      var failure: Error?
      // An empty session item stops a later launch from migrating old items that could not be
      // deleted, which would bring back the account the user just signed out of. Signing out of
      // Bilibili keeps the proxy password.
      let proxySecret = (try? readSession())?.proxySecret
      do { try write(Session(cookies: Data("[]".utf8), token: nil, proxySecret: proxySecret)) } catch { failure = error }
      for item in [Item.legacyToken, .legacyCookies] {
        do { try shared.storage.delete(item) } catch { failure = error }
      }
      if let failure { throw failure }
    }
  }

  /// One read-modify-write of the session item. Account writes change only their field, so the
  /// proxy password (and the account, for proxy writes) carries over.
  private func update(_ change: (inout Session) -> Void) throws {
    try shared.lock.withLock {
      var session = try readSession() ?? Session(cookies: Data("[]".utf8), token: nil)
      change(&session)
      try write(session)
    }
  }
  /// Call with `shared.lock` held.
  private func readSession() throws -> Session? {
    guard let data = try shared.storage.read(.session) else { return nil }
    // Unreadable contents count as signed out; the next save replaces them.
    let session = (try? JSONDecoder().decode(Session.self, from: data)) ?? Session(cookies: Data("[]".utf8), token: nil)
    shared.session = session
    return session
  }
  /// First launch after the layout change: read the two old items once and write the new one.
  /// Call with `shared.lock` held.
  private func migrate() throws -> Session {
    let cookies = try shared.storage.read(.legacyCookies) ?? Data("[]".utf8)
    let token = try shared.storage.read(.legacyToken).flatMap { try? JSONDecoder().decode(AppToken.self, from: $0) }
    let session = Session(cookies: cookies, token: token)
    if token != nil || cookies != Data("[]".utf8) { try? write(session) }
    return session
  }
  /// Call with `shared.lock` held.
  private func write(_ session: Session) throws {
    try shared.storage.write(.session, try JSONEncoder().encode(session))
    shared.session = session
  }

  private static func query(_ item: Item) -> [String: Any] {
    switch item {
    case .session: session
    case .legacyCookies: legacyCookies
    case .legacyToken: legacyToken
    }
  }
  private static func write(_ base: [String: Any], data: Data) throws {
    let result = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if result == errSecItemNotFound {
      var item = base
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw BiliError.dependency("无法保存到钥匙串（\(added)）") }
    } else if result != errSecSuccess {
      throw BiliError.dependency("无法更新钥匙串（\(result)）")
    }
  }
  private static func read(_ base: [String: Any]) throws -> Data? {
    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let result = SecItemCopyMatching(query as CFDictionary, &value)
    if result == errSecItemNotFound { return nil }
    guard result == errSecSuccess, let data = value as? Data else {
      throw BiliError.dependency("无法读取钥匙串（\(result)）")
    }
    return data
  }
  private static func delete(_ query: [String: Any]) throws {
    let result = SecItemDelete(query as CFDictionary)
    guard result == errSecSuccess || result == errSecItemNotFound else {
      throw BiliError.dependency("无法删除钥匙串中的项目（\(result)）")
    }
  }

  public static func encodeCookies(_ cookies: [HTTPCookie]) throws -> Data {
    let allowed = cookies.filter {
      $0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com")
    }
    let records = allowed.map { cookie -> [String: String] in
      var record = [
        "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
        "secure": cookie.isSecure ? "TRUE" : "FALSE",
      ]
      if let expiry = cookie.expiresDate {
        record["expires"] = String(expiry.timeIntervalSince1970)
      }
      return record
    }
    return try JSONEncoder().encode(records)
  }
  public static func decodeCookies(_ data: Data) throws -> [HTTPCookie] {
    let records = try JSONDecoder().decode([[String: String]].self, from: data)
    return records.compactMap { record in
      var properties: [HTTPCookiePropertyKey: Any] = [
        .name: record["name"] ?? "", .value: record["value"] ?? "", .domain: record["domain"] ?? "",
        .path: record["path"] ?? "/", .secure: record["secure"] ?? "TRUE",
      ]
      if let raw = record["expires"], let expiry = Double(raw) {
        properties[.expires] = Date(timeIntervalSince1970: expiry)
      }
      return HTTPCookie(properties: properties)
    }.filter {
      ($0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com"))
        && ($0.expiresDate ?? .distantFuture) > Date()
    }
  }
}
