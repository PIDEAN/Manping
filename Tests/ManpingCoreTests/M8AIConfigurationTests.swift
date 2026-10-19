import Foundation
import XCTest
@testable import ManpingCore

final class M8AIConfigurationTests: XCTestCase {
  func testRegisteredProvidersAndSourceModelCatalogue() {
    XCTAssertEqual(AIProvider.sourceProviders.count, 22)
    XCTAssertEqual(Array(AIProvider.allCases.suffix(2)), [.chatGPTPlan, .appleLocal])
    XCTAssertEqual(AIProvider.allCases.prefix(4).map(\.rawValue), ["openai", "azure_openai", "azure_ai", "xai"])
    XCTAssertEqual(AIProvider.azureOpenAI.predefinedModels, [])
    XCTAssertEqual(AIProvider.azureAI.predefinedModels, [])
    XCTAssertEqual(AIProvider.ollama.predefinedModels, [])
    XCTAssertEqual(AIProvider.doubao.predefinedModels, [])
    XCTAssertEqual(AIProvider.openAI.predefinedModels.count, 16)
    XCTAssertEqual(AIProvider.zhiPu.predefinedModels.count, 14)
    XCTAssertEqual(AIProvider.openAI.predefinedModels.first?.id, "gpt-5")
    XCTAssertEqual(AIProvider.anthropic.predefinedModels.first?.id, "claude-opus-5-5")
    XCTAssertEqual(AIProvider.gemini.predefinedModels.first?.id, "gemini-2.5-pro")
    for provider in AIProvider.allCases {
      XCTAssertEqual(Set(provider.predefinedModels.map(\.id)).count, provider.predefinedModels.count)
    }
    XCTAssertNil(AIProvider.azureOpenAI.defaultEndpoint)
    XCTAssertEqual(AIProvider.qwen.defaultEndpoint, "https://dashscope.aliyuncs.com/compatible-mode/v1")
    XCTAssertEqual(AIProvider.ollama.defaultEndpoint, "http://localhost:11434")
  }
  func testPublicJSONUsesSourceNamesAndNoCredentials() throws {
    var config = AIProviderConfiguration(endpoint: "https://fixture.invalid/v1", models: [AIModel(id: "custom", name: "Custom")],
      organization: "fixture-org", useCodestral: true, apiVersion: "fixture-version")
    config.keyConfigured = true
    let data = try AIConfigurationStore.encodePublicConfiguration([.openAI: config])
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    let fields = try XCTUnwrap(object["openai"])
    XCTAssertEqual(fields["organization"] as? String, "fixture-org")
    XCTAssertEqual(fields["use_codestral"] as? Bool, true)
    XCTAssertEqual(fields["mac_key_configured"] as? Bool, true)
    XCTAssertNil(fields["key"]); XCTAssertNil(fields["secret"]); XCTAssertNil(fields["codestral_key"])
    let decoded = try AIConfigurationStore.decodePublicConfiguration(data)
    XCTAssertEqual(decoded[.openAI], config)
  }
  func testOriginalPublicModelFieldsAreOptionalAndSecretFieldsAreRejected() throws {
    let data = Data(#"{"openai":{"models":[{"id":"fixture-model","name":"Fixture"}],"organization":"fixture-org"}}"#.utf8)
    let config = try XCTUnwrap(AIConfigurationStore.decodePublicConfiguration(data)[.openAI])
    XCTAssertEqual(config.models.first?.toolSupport, false)
    XCTAssertEqual(config.models.first?.visionSupport, false)
    for key in ["key", "secret", "codestral_key"] {
      let object = ["openai": [key: "fixture-secret"]]
      let data = try JSONSerialization.data(withJSONObject: object)
      XCTAssertThrowsError(try AIConfigurationStore.decodePublicConfiguration(data)) { error in
        guard case AIConfigurationError.plaintextSecretsForbidden = error else { return XCTFail("Wrong error") }
      }
    }
    XCTAssertFalse(String(describing: AIProviderSecrets(key: "fixture-secret")).contains("fixture-secret"))
  }
  func testEndpointAndModelValidationPreventsCredentialsInURLs() async throws {
    let store = AIConfigurationStore.fixture()
    for endpoint in ["https://user:fixture-secret@fixture.invalid/v1", "https://fixture.invalid/v1?key=fixture-secret",
      "http://remote.fixture.invalid/v1", "file:///tmp/fixture", "https://fixture.invalid/v1#key"] {
      do {
        try await store.save(provider: .openAI, configuration: AIProviderConfiguration(endpoint: endpoint))
        XCTFail("Invalid endpoint accepted")
      } catch AIConfigurationError.invalidConfiguration {} catch { XCTFail("Wrong error") }
    }
    try await store.save(provider: .ollama, configuration: AIProviderConfiguration(endpoint: "http://127.0.0.1:11434",
      models: [AIModel(id: "fixture-model", name: "Fixture")]))
    let snapshot = try await store.snapshot(for: .ollama)
    XCTAssertEqual(snapshot.secrets.key, "")
    do {
      try await store.save(provider: .openAI, configuration: AIProviderConfiguration(models: [AIModel(id: "same", name: "A"), AIModel(id: "same", name: "B")]))
      XCTFail("Duplicate models accepted")
    } catch AIConfigurationError.invalidConfiguration {}
  }
  func testFixtureSaveRetainsCredentialsAndDeletionChangesRevision() async throws {
    let store = AIConfigurationStore.fixture()
    var iterator = await store.changes().makeAsyncIterator()
    let initialRevision = await iterator.next()
    XCTAssertEqual(initialRevision, 0)
    try await store.save(provider: .openAI, configuration: AIProviderConfiguration(), secrets: AIProviderSecrets(key: "fixture-key"))
    let firstRevision = await iterator.next()
    XCTAssertEqual(firstRevision, 1)
    try await store.save(provider: .openAI, configuration: AIProviderConfiguration(organization: "fixture-org"))
    let snapshot = try await store.snapshot(for: .openAI)
    XCTAssertEqual(snapshot.secrets.key, "fixture-key")
    XCTAssertTrue(snapshot.configuration.keyConfigured)
    XCTAssertEqual(snapshot.configuration.organization, "fixture-org")
    try await store.delete(provider: .openAI)
    let config = try await store.configuration(for: .openAI)
    let secret = try await store.secrets(for: .openAI)
    XCTAssertNil(config); XCTAssertNil(secret)
    let revision = await store.revision
    XCTAssertEqual(revision, 3)
  }
  func testKeychainIsNotReadForConfigurationRendering() async throws {
    let credentials = CountingAISecretStore()
    let store = AIConfigurationStore(fileURL: nil, credentials: credentials)
    _ = try await store.configuration(for: .openAI)
    _ = try await store.allConfigurations()
    _ = try await store.configuredProviders()
    XCTAssertEqual(credentials.readCount, 0)
    try await store.save(provider: .openAI, configuration: AIProviderConfiguration())
    XCTAssertEqual(credentials.readCount, 0)
    let configuration = try await store.configuration(for: .openAI)
    XCTAssertFalse(configuration?.keyConfigured ?? true)
  }
  func testErnieAndCodestralNeedTheirIndependentCredentials() async throws {
    let store = AIConfigurationStore.fixture()
    try await store.save(provider: .ernie, configuration: AIProviderConfiguration(), secrets: AIProviderSecrets(key: "fixture-key"))
    do { _ = try await store.snapshot(for: .ernie); XCTFail("Ernie secret required") }
    catch AIConfigurationError.missingCredentials {}
    try await store.save(provider: .ernie, configuration: AIProviderConfiguration(),
      secrets: AIProviderSecrets(key: "fixture-key", secret: "fixture-secret"))
    _ = try await store.snapshot(for: .ernie)
    try await store.save(provider: .mistral, configuration: AIProviderConfiguration(useCodestral: true),
      secrets: AIProviderSecrets(key: "fixture-key"))
    do { _ = try await store.snapshot(for: .mistral); XCTFail("Codestral key required") }
    catch AIConfigurationError.missingCredentials {}
    try await store.save(provider: .mistral, configuration: AIProviderConfiguration(useCodestral: true),
      secrets: AIProviderSecrets(key: "", codestralKey: "fixture-codestral"))
    let codestral = try await store.snapshot(for: .mistral)
    XCTAssertTrue(codestral.configuration.isConfigured(for: .mistral))
  }
  func testConfigurationFailureRollsBackSecretWrite() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M8AIFixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let secretStore = AIMemorySecretStore(values: [.openAI: AIProviderSecrets(key: "fixture-old")])
    let blockedParent = directory.appendingPathComponent("file-not-directory")
    try Data("fixture".utf8).write(to: blockedParent)
    let store = AIConfigurationStore(fileURL: blockedParent.appendingPathComponent("ChatClientConfiguration.json"), credentials: secretStore)
    do {
      try await store.save(provider: .openAI, configuration: AIProviderConfiguration(), secrets: AIProviderSecrets(key: "fixture-new"))
      XCTFail("Persistence should fail")
    } catch AIConfigurationError.persistence {}
    XCTAssertEqual(try secretStore.load(.openAI)?.key, "fixture-old")
    let revision = await store.revision
    XCTAssertEqual(revision, 0)
  }
  func testFailedCredentialRollbackIsQuarantinedAcrossRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M8BindingFixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("ChatClientConfiguration.json")
    let credentials = FailingBindingSecretStore()
    let store = AIConfigurationStore(fileURL: file, credentials: credentials)
    try await store.save(provider: .openAI, configuration: .init(endpoint: "https://old.example.invalid/v1"),
      secrets: AIProviderSecrets(key: "fixture-old-binding-key"))
    let original = try Data(contentsOf: file)
    let before = await store.revision
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    credentials.failNextRollback()
    do {
      try await store.save(provider: .openAI, configuration: .init(endpoint: "https://new.example.invalid/v1"),
        secrets: AIProviderSecrets(key: "fixture-new-binding-key"))
      XCTFail("Expected failed persistence and failed key rollback")
    } catch AIConfigurationError.rollback {}
    let revision = await store.revision
    XCTAssertGreaterThan(revision, before)
    do { _ = try await store.snapshot(for: .openAI); XCTFail("Quarantined provider was sendable") }
    catch AIConfigurationError.credentialsChanged {}
    try FileManager.default.removeItem(at: file)
    try original.write(to: file, options: .atomic)
    let restarted = AIConfigurationStore(fileURL: file, credentials: credentials)
    do { _ = try await restarted.snapshot(for: .openAI); XCTFail("Old endpoint and new key were combined after restart") }
    catch AIConfigurationError.credentialsChanged {}
    try await restarted.save(provider: .openAI, configuration: .init(endpoint: "https://new.example.invalid/v1"),
      secrets: AIProviderSecrets(key: "fixture-recovered-key"))
    let recovered = try await restarted.snapshot(for: .openAI)
    XCTAssertEqual(recovered.secrets.key, "fixture-recovered-key")
    XCTAssertEqual(recovered.configuration.endpoint, "https://new.example.invalid/v1")
  }
  func testCommittedPublicEndpointIsBoundToTheStoredCredential() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M8EndpointBinding-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("ChatClientConfiguration.json")
    let credentials = AIMemorySecretStore()
    let store = AIConfigurationStore(fileURL: file, credentials: credentials)
    try await store.save(provider: .openAI, configuration: .init(), secrets: AIProviderSecrets(key: "fixture-key"))
    var publicConfiguration = try AIConfigurationStore.decodePublicConfiguration(Data(contentsOf: file))
    publicConfiguration[.openAI]?.endpoint = "https://uncommitted.example.invalid/v1"
    try AIConfigurationStore.encodePublicConfiguration(publicConfiguration).write(to: file, options: .atomic)
    let restarted = AIConfigurationStore(fileURL: file, credentials: credentials)
    do { _ = try await restarted.snapshot(for: .openAI); XCTFail("Uncommitted endpoint accepted") }
    catch AIConfigurationError.credentialsChanged {}
  }
}

private final class FailingBindingSecretStore: AISecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [AIProvider: AIProviderSecrets] = [:]
  private var saves = 0
  private var failure: Int?
  func failNextRollback() { lock.withLock { failure = saves + 2 } }
  func load(_ provider: AIProvider) throws -> AIProviderSecrets? { lock.withLock { values[provider] } }
  func save(_ secrets: AIProviderSecrets, for provider: AIProvider) throws {
    try lock.withLock {
      saves += 1
      if saves == failure { throw LocalSecretVault.Failure.unwritable }
      values[provider] = secrets
    }
  }
  func delete(_ provider: AIProvider) throws { lock.withLock { _ = values.removeValue(forKey: provider) } }
}

private final class CountingAISecretStore: AISecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var readCount: Int { lock.lock(); defer { lock.unlock() }; return count }
  func load(_ provider: AIProvider) throws -> AIProviderSecrets? {
    lock.lock(); defer { lock.unlock() }; count += 1; return nil
  }
  func save(_ secrets: AIProviderSecrets, for provider: AIProvider) throws {}
  func delete(_ provider: AIProvider) throws {}
}
