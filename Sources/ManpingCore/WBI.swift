import CMpv
import Foundation

public enum WBI {
  private static let table = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29,
    28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25,
    54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
  ]
  public static func mixinKey(imageKey: String, subKey: String) throws -> String {
    let bytes = Array((imageKey + subKey).utf8)
    guard bytes.count == 64 else { throw BiliError.invalidResponse("Invalid WBI keys") }
    return String(bytes: table.prefix(32).map { bytes[$0] }, encoding: .utf8)!
  }
  public static func sign(
    _ values: [String: String], imageKey: String, subKey: String,
    timestamp: Int = Int(Date().timeIntervalSince1970)
  ) throws -> String {
    let key = try mixinKey(imageKey: imageKey, subKey: subKey)
    var params = values
    params.removeValue(forKey: "w_rid")
    params["wts"] = String(timestamp)
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
    let query = params.keys.sorted().map { name -> String in
      let value = params[name]!.filter { !"!'()*".contains($0) }
      return name.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
        + value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }.joined(separator: "&")
    return query + "&w_rid=" + md5(query + key)
  }
  public static func md5(_ text: String) -> String {
    let data = Array(text.utf8)
    var digest = [UInt8](repeating: 0, count: 16)
    data.withUnsafeBytes { bytes in bili_md5(bytes.baseAddress, UInt(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
