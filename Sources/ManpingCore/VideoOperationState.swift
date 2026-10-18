import BiliProtocol
import Foundation
import GRPCCore

public struct VideoOperationState: Sendable, Equatable {
  public let liked: Bool
  public let following: Bool
  public let favorited: Bool
  public let coined: Bool
  public init(liked: Bool, following: Bool, favorited: Bool, coined: Bool = false) {
    self.liked = liked; self.following = following; self.favorited = favorited; self.coined = coined
  }
  static func parse(_ data: [String: Any]) throws -> VideoOperationState {
    guard let liked = data["like"] as? Bool, let following = data["attention"] as? Bool,
      let favorited = data["favorite"] as? Bool, let coin = data["coin"] as? Int else {
      throw BiliError.invalidResponse("Missing video operation state")
    }
    return VideoOperationState(liked: liked, following: following, favorited: favorited, coined: coin > 0)
  }
}

/// Exact SDK View/View ReqUser is authenticated with App token, including TV-only sessions.
public actor VideoOperationStateSource {
  private let auth: BiliService
  private var transport: (any BiliRPCTransport)?
  private let ownsTransport: Bool
  private let metadata: BiliRPCMetadata
  public init(auth: BiliService, transport: (any BiliRPCTransport)? = nil,
              installationID: String = UUID().uuidString) {
    self.auth = auth; self.transport = transport; ownsTransport = transport == nil
    metadata = BiliRPCMetadata(installationID: installationID)
  }
  public func load(aid: Int64, expectedIdentity: AuthSnapshot) async throws -> VideoOperationState {
    guard aid > 0 else { throw BiliRPCError.invalidArgument }
    do {
      if transport == nil { transport = try NativeBiliRPCTransport() }
      guard let transport else { throw BiliRPCError.unavailable }
      let metadata = self.metadata
      var request = Bilibili_App_View_V1_ViewReq()
      request.aid = aid; request.fnval = 16
      let value = request
      return try await auth.withRPCIdentity(requireToken: true, expectedIdentity: expectedIdentity) { snapshot in
        let reply = try await transport.unary(value, response: Bilibili_App_View_V1_ViewReply.self,
          descriptor: MethodDescriptor(fullyQualifiedService: "bilibili.app.view.v1.View", method: "View", type: .unary),
          metadata: metadata.build(snapshot))
        guard reply.hasReqUser, reply.hasArc, reply.arc.aid == aid else {
          throw BiliRPCError.invalidPayload("view.req_user")
        }
        return VideoOperationState(liked: reply.reqUser.like == 1, following: reply.reqUser.attention > 0,
          favorited: reply.reqUser.favorite == 1, coined: reply.reqUser.coin > 0)
      }
    } catch is CancellationError { throw CancellationError() }
    catch {
      // Web fallback requires a real Web session; anonymous false flags are never accepted.
      return try await auth.webVideoOperationState(aid: aid, expectedIdentity: expectedIdentity)
    }
  }
  public func shutdown() async {
    if ownsTransport, let transport { await transport.shutdown(grace: .seconds(2)) }
    transport = nil
  }
}
