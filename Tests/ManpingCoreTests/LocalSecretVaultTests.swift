import Foundation
import XCTest

@testable import ManpingCore

/// A fake login keychain: counts reads (each one would be a system prompt) and deletions.
private final class FakeKeychain: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [LocalSecretVault.LegacyItem: Data] = [:]
  private var failure: OSStatus?
  private(set) var reads = 0
  private(set) var deleted: [LocalSecretVault.LegacyItem] = []

  func put(_ data: Data, _ item: LocalSecretVault.LegacyItem) { lock.withLock { items[item] = data } }
  func failReads(_ status: OSStatus?) { lock.withLock { failure = status } }
  var keychain: LocalSecretVault.Keychain {
    LocalSecretVault.Keychain(
      read: { item in
        try self.lock.withLock {
          self.reads += 1
          if let status = self.failure { throw LocalSecretVault.KeychainStatus(status: status) }
          return self.items[item]
        }
      },
      delete: { item in self.lock.withLock { self.items.removeValue(forKey: item); self.deleted.append(item) } })
  }
}

final class LocalSecretVaultTests: XCTestCase {
  private var root: URL!
  private var directory: URL!
  private let legacy = LocalSecretVault.LegacyItem(service: "io.github.pidean.manping.session.v2", account: "bilibili")

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-" + UUID().uuidString, isDirectory: true)
    directory = root.appendingPathComponent("Secrets", isDirectory: true)
  }
  override func tearDownWithError() throws {
    _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try? FileManager.default.removeItem(at: root)
  }

  private func vault(device: String = "DEVICE-A", keychain: FakeKeychain? = nil) -> LocalSecretVault {
    LocalSecretVault(directory: directory, keychain: keychain?.keychain, deviceID: { device })
  }

  func testSealedOwnerOnlyFilesAndRoundTripAcrossInstances() throws {
    let secret = Data("SESSDATA=secret-value".utf8)
    try vault().write("bilibili.session", secret)
    XCTAssertEqual(try vault().read("bilibili.session"), secret, "a new launch reads it back")

    let file = directory.appendingPathComponent("bilibili.session.sealed")
    let stored = try Data(contentsOf: file)
    XCTAssertNil(stored.range(of: Data("secret-value".utf8)), "never stored in plain text")
    let mode = { (url: URL) in (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue }
    XCTAssertEqual(try mode(file), 0o600)
    XCTAssertEqual(try mode(directory.appendingPathComponent("vault.key")), 0o600)
    XCTAssertEqual(try mode(directory), 0o700)
    XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
    XCTAssertEqual(leftovers, [])

    try vault().delete("bilibili.session")
    XCTAssertNil(try vault().read("bilibili.session"))
    XCTAssertNoThrow(try vault().delete("bilibili.session"), "deleting an absent entry is fine")
  }

  func testAnotherMacOrARenamedFileReadsAsAbsent() throws {
    try vault().write("ai.provider.openai", Data("key-a".utf8))
    XCTAssertNil(try vault(device: "DEVICE-B").read("ai.provider.openai"), "bound to the hardware UUID")

    try vault().write("ai.provider.deepseek", Data("key-b".utf8))
    let from = directory.appendingPathComponent("ai.provider.deepseek.sealed")
    let to = directory.appendingPathComponent("ai.provider.openai.sealed")
    try FileManager.default.removeItem(at: to)
    try FileManager.default.moveItem(at: from, to: to)
    XCTAssertNil(try vault().read("ai.provider.openai"), "an entry cannot stand in for another")

    try vault().write("ai.provider.openai", Data("key-c".utf8))
    XCTAssertEqual(try vault().read("ai.provider.openai"), Data("key-c".utf8), "the next save replaces it")
  }

  func testMissingDeviceIdentifierFailsInsteadOfUsingAnotherKey() throws {
    try vault().write("bilibili.session", Data("a".utf8))
    let broken = LocalSecretVault(directory: directory, keychain: nil, deviceID: { nil })
    XCTAssertThrowsError(try broken.read("bilibili.session")) { XCTAssertEqual($0 as? LocalSecretVault.Failure, .deviceUnavailable) }
    XCTAssertThrowsError(try broken.write("bilibili.session", Data("b".utf8)))
    XCTAssertEqual(try vault().read("bilibili.session"), Data("a".utf8), "nothing was overwritten")
  }

  func testKeychainItemMovesOverOnceAndIsRemoved() throws {
    let keychain = FakeKeychain()
    keychain.put(Data("old-session".utf8), legacy)
    XCTAssertEqual(try vault(keychain: keychain).read("bilibili.session", legacy: legacy), Data("old-session".utf8))
    XCTAssertEqual(keychain.reads, 1)
    XCTAssertEqual(keychain.deleted, [legacy])

    // Later launches read the file only: no Keychain access, so no prompt.
    XCTAssertEqual(try vault(keychain: keychain).read("bilibili.session", legacy: legacy), Data("old-session".utf8))
    XCTAssertEqual(keychain.reads, 1)
  }

  func testSignedOutAccountDoesNotComeBackFromAnItemThatCouldNotBeDeleted() throws {
    let keychain = FakeKeychain()
    let stuck = LocalSecretVault.Keychain(read: keychain.keychain.read, delete: { _ in })  // deletion needs authorization
    keychain.put(Data("old-session".utf8), legacy)
    let first = LocalSecretVault(directory: directory, keychain: stuck, deviceID: { "DEVICE-A" })
    XCTAssertNotNil(try first.read("bilibili.session", legacy: legacy))
    try first.delete("bilibili.session", legacy: legacy)

    let next = LocalSecretVault(directory: directory, keychain: stuck, deviceID: { "DEVICE-A" })
    XCTAssertNil(try next.read("bilibili.session", legacy: legacy))
    XCTAssertEqual(keychain.reads, 1, "the leftover item is never read again")
  }

  func testWritesSupersedeAnUnreadKeychainItem() throws {
    let keychain = FakeKeychain()
    keychain.put(Data("old-key".utf8), legacy)
    try vault(keychain: keychain).write("bilibili.session", Data("new".utf8), legacy: legacy)
    XCTAssertEqual(keychain.deleted, [legacy])
    try vault(keychain: keychain).delete("bilibili.session", legacy: legacy)
    XCTAssertNil(try vault(keychain: keychain).read("bilibili.session", legacy: legacy))
    XCTAssertEqual(keychain.reads, 0)
  }

  func testRefusedPromptIsNotRepeatedButALockedKeychainIsRetried() throws {
    let keychain = FakeKeychain()
    keychain.put(Data("old".utf8), legacy)
    keychain.failReads(errSecInteractionNotAllowed)
    XCTAssertThrowsError(try vault(keychain: keychain).read("bilibili.session", legacy: legacy)) {
      XCTAssertEqual($0 as? LocalSecretVault.Failure, .keychainUnavailable(errSecInteractionNotAllowed), "never read as absent")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bilibili.session.sealed").path))
    keychain.failReads(nil)
    XCTAssertEqual(try vault(keychain: keychain).read("bilibili.session", legacy: legacy), Data("old".utf8), "tried again")

    let other = LocalSecretVault.LegacyItem(service: "io.github.pidean.manping.ai.chatgpt.v1", account: "registration")
    keychain.put(Data("token".utf8), other)
    keychain.failReads(errSecUserCanceled)
    XCTAssertNil(try vault(keychain: keychain).read("ai.chatgpt.registration", legacy: other))
    let reads = keychain.reads
    keychain.failReads(nil)
    XCTAssertNil(try vault(keychain: keychain).read("ai.chatgpt.registration", legacy: other), "starts signed out instead")
    XCTAssertEqual(keychain.reads, reads, "no second prompt")
  }

  func testAbsentItemsAreLookedUpOnce() throws {
    let keychain = FakeKeychain()
    XCTAssertNil(try vault(keychain: keychain).read("ai.chatgpt.host", legacy: legacy))
    XCTAssertNil(try vault(keychain: keychain).read("ai.chatgpt.host", legacy: legacy))
    XCTAssertEqual(keychain.reads, 1)
  }

  func testNamesAreValidated() {
    for name in ["", ".hidden", "../escape", "a/b", "中文", String(repeating: "a", count: 97)] {
      XCTAssertThrowsError(try vault().write(name, Data())) { XCTAssertEqual($0 as? LocalSecretVault.Failure, .invalidName) }
    }
    XCTAssertNoThrow(try vault().write("ai.provider.azure_openai", Data()))
  }

  func testMemoryVaultNeverTouchesDisk() throws {
    let memory = LocalSecretVault(directory: nil, keychain: nil)
    try memory.write("bilibili.session", Data("a".utf8))
    XCTAssertEqual(try memory.read("bilibili.session"), Data("a".utf8))
    try memory.delete("bilibili.session")
    XCTAssertNil(try memory.read("bilibili.session"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testStoresUseTheVault() async throws {
    let shared = vault()
    let ai = AILocalSecretStore(vault: shared)
    var secrets = AIProviderSecrets(key: "sk-test", secret: "s")
    secrets.configurationBinding = "binding"
    try ai.save(secrets, for: .openAI)
    let loaded = try XCTUnwrap(try AILocalSecretStore(vault: vault()).load(.openAI))
    XCTAssertEqual(loaded.key, "sk-test"); XCTAssertEqual(loaded.secret, "s"); XCTAssertEqual(loaded.configurationBinding, "binding")
    try ai.delete(.openAI)
    XCTAssertNil(try ai.load(.openAI))

    let plan = ChatGPTPlanLocalStore(vault: shared)
    try plan.saveHostID("urn:uuid:host")
    try plan.savePendingClientID("client-1")
    XCTAssertEqual(try ChatGPTPlanLocalStore(vault: vault()).loadHostID(), "urn:uuid:host")
    XCTAssertEqual(try plan.loadPendingClientID(), "client-1")
    try plan.savePendingClientID(nil)
    XCTAssertNil(try plan.loadPendingClientID())
  }

  func testThisMacHasAHardwareIdentifier() {
    XCTAssertFalse((LocalSecretVault.platformUUID() ?? "").isEmpty)
  }

  func testTestProcessesDoNotUseTheUsersFolder() throws {
    // `swift test` runs outside the app bundle: the shared vault must stay in memory.
    try LocalSecretVault.shared.write("test.probe", Data("x".utf8))
    let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Manping/Secrets/test.probe.sealed")
    XCTAssertFalse(FileManager.default.fileExists(atPath: real.path))
    try LocalSecretVault.shared.delete("test.probe")
  }
  func testInstancesSharingAFolderAgreeOnTheKeyAndTheRetiredList() throws {
    let instances = (0..<4).map { _ in vault(keychain: FakeKeychain()) }
    DispatchQueue.concurrentPerform(iterations: 16) { index in
      let item = LocalSecretVault.LegacyItem(service: "s", account: "a\(index)")
      try? instances[index % 4].write("entry\(index)", Data("value\(index)".utf8), legacy: item)
    }
    let fresh = vault()
    for index in 0..<16 { XCTAssertEqual(try fresh.read("entry\(index)"), Data("value\(index)".utf8)) }
    let retired = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("Secrets-retired-keychain-items.json")))
    XCTAssertEqual(Set(retired), Set((0..<16).map { "entry\($0)" }), "no instance overwrote another's names")
  }

  func testUnsavedRetirementIsNotTreatedAsDone() throws {
    let keychain = FakeKeychain()
    keychain.put(Data("old".utf8), legacy)
    let instance = vault(keychain: keychain)
    try instance.write("other", Data("x".utf8))  // creates the folder and key
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)  // the list cannot be saved
    XCTAssertThrowsError(try instance.read("bilibili.session", legacy: legacy))
    XCTAssertThrowsError(try instance.delete("bilibili.session", legacy: legacy), "no false success")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try instance.delete("bilibili.session", legacy: legacy)
    XCTAssertNil(try vault(keychain: keychain).read("bilibili.session", legacy: legacy))
  }

  func testUnreadableKeyIsNeverReplaced() throws {
    try vault().write("bilibili.session", Data("a".utf8))
    let keyURL = directory.appendingPathComponent("vault.key")
    let original = try Data(contentsOf: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keyURL.path)
    XCTAssertThrowsError(try vault().read("bilibili.session")) { XCTAssertEqual($0 as? LocalSecretVault.Failure, .keyUnreadable) }
    XCTAssertThrowsError(try vault().write("ai.provider.openai", Data("b".utf8)))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    XCTAssertEqual(try Data(contentsOf: keyURL), original)
    XCTAssertEqual(try vault().read("bilibili.session"), Data("a".utf8))
  }

  func testDeletingTheFolderDoesNotBringKeychainItemsBack() throws {
    let keychain = FakeKeychain()
    let stuck = LocalSecretVault.Keychain(read: keychain.keychain.read, delete: { _ in })
    keychain.put(Data("old-session".utf8), legacy)
    let first = LocalSecretVault(directory: directory, keychain: stuck, deviceID: { "DEVICE-A" })
    XCTAssertNotNil(try first.read("bilibili.session", legacy: legacy))
    try FileManager.default.removeItem(at: directory)
    let next = LocalSecretVault(directory: directory, keychain: stuck, deviceID: { "DEVICE-A" })
    XCTAssertNil(try next.read("bilibili.session", legacy: legacy))
    XCTAssertEqual(keychain.reads, 1)
  }

  func testDebugAndToolsDoNotShareTheReleaseAIConfiguration() {
    XCTAssertNil(LocalSecretVault.appVariant, "test processes are not the app")
    XCTAssertEqual(AIConfigurationStore.defaultFileURL.lastPathComponent, "ChatClientConfiguration.json")
  }
}
