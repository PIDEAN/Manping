import BiliProtocol
import Foundation
import GRPCCore
import SwiftProtobuf

/// The fixed SDK uses Feed/DynamicThumb with the app.dynamic.v2 request wire schema.
public actor MomentOperationsService {
  private let auth: BiliService
  private let transport: any BiliRPCTransport
  private let metadata: BiliRPCMetadata
  private let ownsTransport: Bool
  private var closed = false

  public init(auth: BiliService, transport: any BiliRPCTransport, installationID: String) {
    self.auth = auth; self.transport = transport; ownsTransport = false
    metadata = BiliRPCMetadata(installationID: installationID)
  }
  public init(auth: BiliService, installationID: String) throws {
    self.auth = auth; transport = try NativeBiliRPCTransport(); ownsTransport = true
    metadata = BiliRPCMetadata(installationID: installationID)
  }
  public func setLiked(dynamicID: Int64, authorID: Int64, liked: Bool, expectedIdentity: AuthSnapshot)
    async throws {
    guard !closed else { throw BiliRPCError.shutdown }
    guard dynamicID > 0, authorID > 0 else { throw BiliRPCError.invalidArgument }
    var request = Bilibili_App_Dynamic_V2_DynThumbReq()
    request.dynID = dynamicID; request.uid = authorID; request.type = liked ? .thumb : .cancel
    let descriptor = MethodDescriptor(fullyQualifiedService: "bilibili.main.dynamic.feed.v1.Feed",
      method: "DynamicThumb", type: .unary)
    let payload = request
    let transport = self.transport; let metadata = self.metadata
    do {
      _ = try await auth.withRPCIdentity(requireToken: true, expectedIdentity: expectedIdentity) { snapshot in
        try await transport.unary(payload, response: Bilibili_App_Dynamic_V2_NoReply.self,
          descriptor: descriptor, metadata: metadata.build(snapshot))
      }
    } catch { throw BiliRPCError.sanitized(error) }
  }
  public func shutdown() async {
    closed = true
    if ownsTransport { await transport.shutdown(grace: .seconds(2)) }
  }
}
