import CryptoKit
import Foundation
import IOKit
import Security

/// The Bilibili login, the proxy password and AI credentials, sealed with AES-GCM in files under
/// Application Support. Replaces the Keychain from 0.1.3: the app is self-signed, and the Keychain
/// authorized each build separately, so every update asked for the login password again (once at
/// launch for the account, once more at the first AI request).
///
/// The folder is private to this user (0700, files 0600) and excluded from backups. The sealing
/// key is random, kept beside the data, and bound to this Mac's hardware UUID, so a copied folder
/// or a stray backup does not open elsewhere. Like any per-user file it does not protect against
/// software already running as this user.
public final class LocalSecretVault: @unchecked Sendable {
  /// Where an entry lived in the Keychain before 0.1.3.
  public struct LegacyItem: Sendable, Hashable {
    public let service: String
    public let account: String
    public init(service: String, account: String) { self.service = service; self.account = account }
  }
  /// Keychain access for the one-time migration; injected in tests.
  public struct Keychain: Sendable {
    let read: @Sendable (LegacyItem) throws -> Data?
    /// Best effort and never interactive: an item that would need authorization stays behind.
    let delete: @Sendable (LegacyItem) -> Void
    public init(read: @escaping @Sendable (LegacyItem) throws -> Data?, delete: @escaping @Sendable (LegacyItem) -> Void) {
      self.read = read; self.delete = delete
    }
  }
  public struct KeychainStatus: Error, Equatable, Sendable { public let status: OSStatus }

  public enum Failure: Error, LocalizedError, Equatable, Sendable {
    case invalidName, deviceUnavailable, unwritable, keyUnreadable
    /// A Keychain item that still has to be moved over could not be read for now (for example
    /// a locked keychain); nothing was changed and the next read tries again.
    case keychainUnavailable(OSStatus)
    public var errorDescription: String? {
      switch self {
      case .invalidName: "本地加密存储的项目名称无效。"
      case .deviceUnavailable: "无法读取本机硬件标识，本地加密存储暂不可用。"
      case .unwritable: "无法写入本地加密存储，请检查磁盘空间与「应用程序支持」目录权限。"
      case .keyUnreadable: "本地加密存储的密钥文件无法读取。请检查「应用程序支持/Manping/Secrets」的权限；若文件已损坏，删除该目录后重新登录。"
      case .keychainUnavailable(let status): "暂时无法从钥匙串读取旧版本保存的凭据（\(status)），请稍后重试。"
      }
    }
  }

  private let directory: URL?
  /// Names whose Keychain item is no longer consulted. Kept outside `directory`, so deleting
  /// the folder to clear every secret cannot bring old Keychain items back.
  private let retiredURL: URL?
  private let keychain: Keychain?
  private let deviceID: @Sendable () -> String?
  private let lock = NSLock()
  private var memory: [String: Data] = [:]
  private var memoryRetired: Set<String> = []
  private var key: SymmetricKey?

  /// `directory` nil keeps everything in memory. `keychain` nil skips the migration.
  public init(directory: URL?, retiredURL: URL? = nil, keychain: Keychain?,
    deviceID: @escaping @Sendable () -> String? = LocalSecretVault.platformUUID) {
    self.directory = directory; self.keychain = keychain; self.deviceID = deviceID
    self.retiredURL = retiredURL ?? directory.map {
      $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + "-retired-keychain-items.json")
    }
  }

  /// "" for the release app, "-debug" (and so on) for other Manping builds, nil outside the app.
  public static let appVariant: String? = {
    let identifier = Bundle.main.bundleIdentifier ?? ""
    if identifier == "io.github.pidean.manping" { return "" }
    guard identifier.hasPrefix("io.github.pidean.manping.") else { return nil }
    return "-" + identifier.dropFirst("io.github.pidean.manping.".count)
  }()

  /// The release app uses `Application Support/Manping/Secrets` and migrates its Keychain items.
  /// Other Manping builds (Debug) get their own folder and never read the release Keychain items;
  /// anything else (tests, tools) stays in memory and never touches the user's files.
  public static let shared: LocalSecretVault = {
    guard let variant = appVariant else { return LocalSecretVault(directory: nil, keychain: nil) }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Manping", isDirectory: true)
    return LocalSecretVault(directory: base.appendingPathComponent("Secrets" + variant, isDirectory: true),
      keychain: variant.isEmpty ? .system : nil)
  }()

  // MARK: Entries

  /// The entry, or nil. The first read of a name that still has a Keychain item moves it here
  /// (this may show the Keychain prompt one last time) and removes the item when that needs no
  /// further authorization.
  public func read(_ name: String, legacy: LegacyItem? = nil) throws -> Data? {
    try Self.validate(name)
    return try exclusive {
      if let data = try load(name) { return data }
      guard let legacy, let keychain, try !retiredNames().contains(name) else { return nil }
      let data: Data?
      do { data = try keychain.read(legacy) } catch let error as KeychainStatus {
        // Refused or cancelled: start signed out rather than asking again at every launch.
        guard [errSecUserCanceled, errSecAuthFailed].contains(error.status) else {
          // Anything else (a locked keychain) changes nothing and is tried again next time,
          // so a caller never builds on a partial migration.
          throw Failure.keychainUnavailable(error.status)
        }
        try retire(name)
        return nil
      }
      if let data { try store(name, data) }
      try retire(name)
      keychain.delete(legacy)
      return data
    }
  }
  public func write(_ name: String, _ data: Data, legacy: LegacyItem? = nil) throws {
    try Self.validate(name)
    try exclusive {
      try store(name, data)
      try supersede(name, legacy)
    }
  }
  public func delete(_ name: String, legacy: LegacyItem? = nil) throws {
    try Self.validate(name)
    try exclusive {
      // Retire first: if that cannot be saved, the entry stays and the delete reports failure.
      try supersede(name, legacy)
      if let directory {
        let url = directory.appendingPathComponent(name + ".sealed")
        if unlink(url.path) != 0, errno != ENOENT { throw Failure.unwritable }
      } else { memory.removeValue(forKey: name) }
    }
  }

  // MARK: Storage

  /// Serializes this instance and, through a lock file, other processes using the same folder.
  private func exclusive<T>(_ body: () throws -> T) throws -> T {
    try lock.withLock {
      guard let directory else { return try body() }
      try prepare(directory)
      let descriptor = open(directory.appendingPathComponent("vault.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw Failure.unwritable }
      defer { close(descriptor) }
      guard flock(descriptor, LOCK_EX) == 0 else { throw Failure.unwritable }
      defer { flock(descriptor, LOCK_UN) }
      return try body()
    }
  }

  // Call the rest with `exclusive` held.
  private func supersede(_ name: String, _ legacy: LegacyItem?) throws {
    guard let legacy, let keychain, try !retiredNames().contains(name) else { return }
    try retire(name)
    keychain.delete(legacy)
  }
  private func load(_ name: String) throws -> Data? {
    guard let directory else { return memory[name] }
    guard let sealed = try? Data(contentsOf: directory.appendingPathComponent(name + ".sealed")) else { return nil }
    let key = try sealingKey()
    // Sealed on another Mac or renamed from another entry: treated as absent (signed out);
    // the next save replaces it.
    guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
    return try? AES.GCM.open(box, using: key, authenticating: Data(name.utf8))
  }
  private func store(_ name: String, _ data: Data) throws {
    guard let directory else { memory[name] = data; return }
    guard let sealed = try AES.GCM.seal(data, using: try sealingKey(), authenticating: Data(name.utf8)).combined else {
      throw Failure.unwritable
    }
    try atomicWrite(sealed, to: directory.appendingPathComponent(name + ".sealed"))
  }
  /// Read from disk every time (another process may have added names); saved before it counts.
  private func retiredNames() throws -> Set<String> {
    guard let retiredURL else { return memoryRetired }
    do {
      return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: retiredURL)))
    } catch CocoaError.fileReadNoSuchFile {
      return []
    } catch {
      // An unreadable list must not reopen migration of items the user already signed out of.
      throw Failure.unwritable
    }
  }
  private func retire(_ name: String) throws {
    var names = try retiredNames()
    guard names.insert(name).inserted else { return }
    guard let retiredURL else { memoryRetired = names; return }
    try atomicWrite(try JSONEncoder().encode(names.sorted()), to: retiredURL)
  }

  /// The random key file combined with this Mac's hardware UUID.
  private func sealingKey() throws -> SymmetricKey {
    if let key { return key }
    guard let directory else { throw Failure.unwritable }
    guard let device = deviceID(), !device.isEmpty else { throw Failure.deviceUnavailable }
    let url = directory.appendingPathComponent("vault.key")
    let raw: Data
    do {
      raw = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.unwritable }
      try atomicWrite(Data(bytes), to: url)
      raw = Data(bytes)
    } catch {
      // Never replace a key that exists but cannot be read now: that would lose every entry.
      throw Failure.keyUnreadable
    }
    guard raw.count == 32 else { throw Failure.keyUnreadable }
    let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(device.utf8),
      info: Data("io.github.pidean.manping secret vault v1".utf8), outputByteCount: 32)
    key = derived
    return derived
  }
  private func prepare(_ directory: URL) throws {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      var values = URLResourceValues(); values.isExcludedFromBackup = true
      var folder = directory; try folder.setResourceValues(values)
    } catch { throw Failure.unwritable }
  }
  /// Owner-only file, replaced in one rename so a crash never leaves half an entry.
  private func atomicWrite(_ data: Data, to url: URL) throws {
    let folder = url.deletingLastPathComponent()
    if folder == directory { try prepare(folder) }
    let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw Failure.unwritable
    }
    guard rename(temporary.path, url.path) == 0 else { unlink(temporary.path); throw Failure.unwritable }
  }

  static func validate(_ name: String) throws {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !name.isEmpty, name.count <= 96, !name.hasPrefix("."), name.allSatisfy(allowed.contains) else { throw Failure.invalidName }
  }

  public static func platformUUID() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
  }
}

extension LocalSecretVault.Keychain {
  /// The login keychain items written by 0.1.2 and earlier.
  public static let system = LocalSecretVault.Keychain(
    read: { item in
      var query = Self.query(item)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var value: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &value)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = value as? Data else { throw LocalSecretVault.KeychainStatus(status: status) }
      return data
    },
    delete: { item in
      var query = Self.query(item)
      // Never a second prompt just to tidy up; an item that needs one is left for the user.
      query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
      _ = SecItemDelete(query as CFDictionary)
    })
  private static func query(_ item: LocalSecretVault.LegacyItem) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: item.service, kSecAttrAccount as String: item.account]
  }
}
