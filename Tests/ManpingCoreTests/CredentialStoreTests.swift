import Foundation
import XCTest

@testable import ManpingCore

/// In-memory items for `CredentialStore` (tests never touch the Keychain). `holdNextSessionRead`
/// parks the next session read, after it read the value, until `release` is signalled.
private final class MemoryItems: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [CredentialStore.Item: Data] = [:]
  private var hold = false
  let reached = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)

  func holdNextSessionRead() { lock.withLock { hold = true } }

  var storage: CredentialStore.Storage {
    CredentialStore.Storage(
      read: { item in
        // The value is read before parking, like a Keychain read that returns and then loses the CPU.
        let (value, parked) = self.lock.withLock { () -> (Data?, Bool) in
          let parked = item == .session && self.hold
          if parked { self.hold = false }
          return (self.items[item], parked)
        }
        if parked { self.reached.signal(); self.release.wait() }
        return value
      },
      write: { item, data in self.lock.withLock { self.items[item] = data } },
      delete: { item in _ = self.lock.withLock { self.items.removeValue(forKey: item) } })
  }
}

final class CredentialStoreTests: XCTestCase {
  private func account() throws -> HTTPCookie {
    try XCTUnwrap(HTTPCookie(properties: [
      .name: "SESSDATA", .value: "account-a", .domain: ".bilibili.com", .path: "/",
      .expires: Date().addingTimeInterval(3600), .secure: "TRUE",
    ]))
  }

  func testProxySecretWriteCannotBringBackASignedOutAccount() throws {
    // F1: the proxy password write reads the session, a logout runs in between, then the password
    // write puts back the whole session. Serialized, the logout wins and the password stays.
    let memory = MemoryItems()
    let shared = CredentialStore.Shared(storage: memory.storage)
    try CredentialStore(shared: shared).save([try account()])
    memory.holdNextSessionRead()
    let writer = CredentialStore(shared: shared)
    let logout = CredentialStore(shared: shared)
    let wrote = DispatchSemaphore(value: 0), cleared = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { try? writer.saveProxySecret("proxy-pw"); wrote.signal() }
    XCTAssertEqual(memory.reached.wait(timeout: .now() + 5), .success)
    DispatchQueue.global().async { try? logout.clear(); cleared.signal() }
    // Give an unserialized logout time to finish while the password write is parked.
    Thread.sleep(forTimeInterval: 0.3)
    memory.release.signal()
    XCTAssertEqual(wrote.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(cleared.wait(timeout: .now() + 5), .success)

    // A fresh shared state reads the stored item, not a cache.
    let fresh = CredentialStore(shared: CredentialStore.Shared(storage: memory.storage))
    XCTAssertTrue(try fresh.loadAll().cookies.isEmpty, "the signed-out account stays signed out")
    XCTAssertEqual(try fresh.proxySecret(), "proxy-pw", "the proxy password survives the logout")
    XCTAssertTrue(try CredentialStore(shared: shared).loadAll().cookies.isEmpty, "the shared cache agrees")
  }

  func testAccountAndProxyWritesKeepEachOthersFields() throws {
    let shared = CredentialStore.Shared(storage: MemoryItems().storage)
    let first = CredentialStore(shared: shared), second = CredentialStore(shared: shared)
    try first.saveProxySecret("pw")
    try second.save([try account()])
    XCTAssertEqual(try first.proxySecret(), "pw")
    XCTAssertEqual(try first.loadAll().cookies.map(\.value), ["account-a"])
    try second.saveProxySecret(nil)
    XCTAssertNil(try first.proxySecret())
    XCTAssertEqual(try first.loadAll().cookies.map(\.value), ["account-a"])
  }
}
