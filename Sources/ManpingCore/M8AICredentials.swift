import Foundation

public protocol AISecretStore: Sendable {
  func load(_ provider: AIProvider) throws -> AIProviderSecrets?
  func save(_ secrets: AIProviderSecrets, for provider: AIProvider) throws
  func delete(_ provider: AIProvider) throws
}

/// AI credentials use separate per-provider entries in `LocalSecretVault`, never the Bilibili
/// account entry. Before 0.1.3 they were Keychain items; each moves over on its first read.
public final class AILocalSecretStore: AISecretStore, Sendable {
  private let vault: LocalSecretVault
  public init(vault: LocalSecretVault = .shared) { self.vault = vault }
  private func entry(_ provider: AIProvider) -> (name: String, legacy: LocalSecretVault.LegacyItem) {
    ("ai.provider." + provider.rawValue, .init(service: "io.github.pidean.manping.ai.provider.v1", account: provider.rawValue))
  }
  public func load(_ provider: AIProvider) throws -> AIProviderSecrets? {
    let entry = entry(provider)
    guard let data = try vault.read(entry.name, legacy: entry.legacy) else { return nil }
    guard data.count <= 256 * 1024,
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
    let entry = entry(provider)
    try vault.write(entry.name, try JSONSerialization.data(withJSONObject: object), legacy: entry.legacy)
  }
  public func delete(_ provider: AIProvider) throws {
    let entry = entry(provider)
    try vault.delete(entry.name, legacy: entry.legacy)
  }
}

/// In-memory fixture storage is intentionally independent of UserDefaults, the local vault and real configuration files.
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
