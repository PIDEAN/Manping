import Foundation

// A UI may observe identity invalidation without receiving or retaining account credentials.
public struct AuthIdentityEvent: Sendable, Equatable {
  public let epoch: UInt64
  public let identityRevision: UInt64
  public let state: AuthorizationState
  public let mid: Int64?
}
