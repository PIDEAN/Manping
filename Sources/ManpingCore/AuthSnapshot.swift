import Foundation

public enum AuthFailure: Error, LocalizedError, Sendable {
  case needsLogin, missingCSRF
  case rejected(Int)
  case invalidResponse, transport, expired
  public var errorDescription: String? {
    switch self {
    case .needsLogin: return "需要重新登录"
    case .missingCSRF: return "网页登录信息不完整，请重新登录"
    case .rejected(let code): return "认证请求失败（\(code)）"
    case .invalidResponse: return "认证响应无效"
    case .transport: return "认证网络请求失败，请重试"
    case .expired: return "二维码已过期，请重新获取"
    }
  }
}

public struct AppToken: Codable, Sendable, Equatable {
  public let mid: Int64
  public let accessToken: String
  public let refreshToken: String
  public let expiresAt: Int64
  public init(mid: Int64, accessToken: String, refreshToken: String, expiresAt: Int64) {
    self.mid = mid
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
  public var isComplete: Bool {
    mid > 0 && !accessToken.isEmpty && !refreshToken.isEmpty && expiresAt > 0
  }
}

public enum AuthorizationState: String, Sendable { case needsLogin, webOnly, appAuthorized }
public struct AuthSnapshot: Sendable {
  public let epoch: UInt64
  public let identityRevision: UInt64
  public let state: AuthorizationState
  public let token: AppToken?
  /// Stable ownership for local playback checkpoints. Zero is the signed-out profile.
  var storedMID: Int64? = nil
  var webMID: Int64? = nil
  public var playbackOwner: Int64? { token?.mid ?? storedMID ?? webMID ?? (state == .needsLogin ? 0 : nil) }
  // An expired, complete token can still be refreshed by the signed report route.
  public var canAttemptHistoryReport: Bool { state != .needsLogin || storedMID != nil }
  /// The same login and the same identity revision: results captured under `other` still apply.
  public func sameIdentity(as other: AuthSnapshot) -> Bool {
    epoch == other.epoch && identityRevision == other.identityRevision
  }
  // Token headers only; BiliRPCMetadata builds the binary gRPC headers from this same snapshot.
  public var tokenHeaders: [String: String] {
    guard let token, state == .appAuthorized else { return [:] }
    return ["authorization": "identify_v1 \(token.accessToken)", "x-bili-mid": String(token.mid)]
  }
}
