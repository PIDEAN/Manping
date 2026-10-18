import Foundation
import Security

public protocol AISecretStore: Sendable {
  func load(_ provider: AIProvider) throws -> AIProviderSecrets?
  func save(_ secrets: AIProviderSecrets, for provider: AIProvider) throws
  func delete(_ provider: AIProvider) throws
}

/// AI credentials use separate per-provider Keychain records, never the Bilibili account cookie store.
public final class AIKeychainSecretStore: AISecretStore, Sendable {
  private let service: String
  public init(service: String = "io.github.pidean.manping.ai.provider.v1") { self.service = service }
  private func query(_ provider: AIProvider) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: provider.rawValue]
  }
  public func load(_ provider: AIProvider) throws -> AIProviderSecrets? {
    var query = query(provider)
    query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw AIConfigurationError.keychain(status) }
    guard let data = result as? Data, data.count <= 256 * 1024,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String], let key = object["key"] else {
      throw AIConfigurationError.corruptConfiguration
    }
    var secrets = AIProviderSecrets(key: key, secret: object["secret"], codestralKey: object["codestral_key"])
    secrets.configurationBinding = object["configuration_binding"]
    return secrets
  }
  public func save(_ secrets: AIProviderSecrets, for provider: AIProvider) throws {
    var object = ["key": secrets.key]
    object["secret"] = secrets.secret; object["codestral_key"] = secrets.codestralKey
    object["configuration_binding"] = secrets.configurationBinding
    let data = try JSONSerialization.data(withJSONObject: object)
    let query = query(provider)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query; item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw AIConfigurationError.keychain(added) }
    } else if status != errSecSuccess { throw AIConfigurationError.keychain(status) }
  }
  public func delete(_ provider: AIProvider) throws {
    let status = SecItemDelete(query(provider) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw AIConfigurationError.keychain(status) }
  }
}

/// In-memory fixture storage is intentionally independent of UserDefaults, Keychain and real configuration files.
public final class AIMemorySecretStore: AISecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [AIProvider: AIProviderSecrets]
  public init(values: [AIProvider: AIProviderSecrets] = [:]) { self.values = values }
  public func load(_ provider: AIProvider) throws -> AIProviderSecrets? {
    lock.lock(); defer { lock.unlock() }; return values[provider]
  }
  public func save(_ secrets: AIProviderSecrets, for provider: AIProvider) throws {
    lock.lock(); defer { lock.unlock() }; values[provider] = secrets
  }
  public func delete(_ provider: AIProvider) throws {
    lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: provider)
  }
}
