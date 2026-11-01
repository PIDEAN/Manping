import Foundation
import XCTest

extension XCTestCase {
  /// A throwaway `UserDefaults` whose backing plist lives in a private temporary directory.
  ///
  /// A plain named suite is written to ~/Library/Preferences, and `removePersistentDomain` leaves
  /// an empty `<suite>.plist` there: cfprefsd re-creates the file asynchronously, seconds after
  /// any client-side delete, so it cannot be cleaned up reliably. An absolute-path domain keeps
  /// the file under the temp directory instead, where the teardown removes the whole directory.
  /// The file is named `<prefix>.plist`, so the prefix still identifies the test that owns it.
  func scratchDefaults(_ prefix: String) -> UserDefaults {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ManpingScratchDefaults-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("cannot create \(directory.path): \(error)")
    }
    let suite = directory.appendingPathComponent(prefix).path
    guard let defaults = UserDefaults(suiteName: suite) else {
      preconditionFailure("UserDefaults(suiteName:) returned nil for \(suite)")
    }
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suite)
      defaults.synchronize()
      try? FileManager.default.removeItem(at: directory)
    }
    return defaults
  }
}
