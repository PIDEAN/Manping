import Foundation

/// The preference operations used by the app, without requiring a persistent domain.
public protocol PreferencesStore: AnyObject, Sendable {
  func object(forKey defaultName: String) -> Any?
  func string(forKey defaultName: String) -> String?
  func data(forKey defaultName: String) -> Data?
  func integer(forKey defaultName: String) -> Int
  func float(forKey defaultName: String) -> Float
  func double(forKey defaultName: String) -> Double
  func bool(forKey defaultName: String) -> Bool
  func url(forKey defaultName: String) -> URL?
  func set(_ value: Any?, forKey defaultName: String)
  func set(_ value: Int, forKey defaultName: String)
  func set(_ value: Float, forKey defaultName: String)
  func set(_ value: Double, forKey defaultName: String)
  func set(_ value: Bool, forKey defaultName: String)
  func set(_ url: URL?, forKey defaultName: String)
  func removeObject(forKey defaultName: String)
  func register(defaults registrationDictionary: [String: Any])
}

extension UserDefaults: PreferencesStore {}

/// Fixture preferences have no UserDefaults backing and cannot create or alter a domain.
public final class MemoryPreferences: PreferencesStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Any]
  private var registered: [String: Any] = [:]

  public init(values: [String: Any] = [:]) { self.values = values }
  public func object(forKey defaultName: String) -> Any? {
    lock.withLock { values[defaultName] ?? registered[defaultName] }
  }
  public func string(forKey defaultName: String) -> String? {
    let value = object(forKey: defaultName)
    return value as? String ?? (value as? NSNumber)?.stringValue
  }
  public func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
  public func integer(forKey defaultName: String) -> Int {
    (object(forKey: defaultName) as? NSNumber)?.intValue
      ?? (object(forKey: defaultName) as? NSString)?.integerValue ?? 0
  }
  public func float(forKey defaultName: String) -> Float {
    (object(forKey: defaultName) as? NSNumber)?.floatValue
      ?? (object(forKey: defaultName) as? NSString)?.floatValue ?? 0
  }
  public func double(forKey defaultName: String) -> Double {
    (object(forKey: defaultName) as? NSNumber)?.doubleValue
      ?? (object(forKey: defaultName) as? NSString)?.doubleValue ?? 0
  }
  public func bool(forKey defaultName: String) -> Bool {
    (object(forKey: defaultName) as? NSNumber)?.boolValue
      ?? (object(forKey: defaultName) as? NSString)?.boolValue ?? false
  }
  public func url(forKey defaultName: String) -> URL? {
    if let url = object(forKey: defaultName) as? URL { return url }
    guard let string = object(forKey: defaultName) as? String else { return nil }
    return string.hasPrefix("/") ? URL(fileURLWithPath: string) : URL(string: string)
  }
  public func set(_ value: Any?, forKey defaultName: String) {
    lock.withLock { values[defaultName] = value }
    notifyChange()
  }
  public func set(_ value: Int, forKey defaultName: String) {
    set(NSNumber(value: value), forKey: defaultName)
  }
  public func set(_ value: Float, forKey defaultName: String) {
    set(NSNumber(value: value), forKey: defaultName)
  }
  public func set(_ value: Double, forKey defaultName: String) {
    set(NSNumber(value: value), forKey: defaultName)
  }
  public func set(_ value: Bool, forKey defaultName: String) {
    set(NSNumber(value: value), forKey: defaultName)
  }
  public func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }
  public func removeObject(forKey defaultName: String) { set(nil as Any?, forKey: defaultName) }
  public func register(defaults registrationDictionary: [String: Any]) {
    lock.withLock {
      registered.merge(registrationDictionary, uniquingKeysWith: { _, value in value })
    }
    notifyChange()
  }
  private func notifyChange() {
    if Thread.isMainThread {
      NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    } else {
      DispatchQueue.main.async { [self] in
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
      }
    }
  }

}
