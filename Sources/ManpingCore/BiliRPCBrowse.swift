import Foundation

/// Shared read adapter used by the popular/ranking UI and injected RPC fixtures.
public struct RPCBrowseSource: Sendable {
  private let rpc: any BiliRPCService
  public init(rpc: any BiliRPCService) { self.rpc = rpc }

  public func popularFeed(cursor: String? = nil) async throws -> BrowseVideoPage {
    let index: Int64
    if let cursor {
      guard let parsed = Int64(cursor), parsed >= 0 else { throw BiliRPCError.invalidArgument }
      index = parsed
    } else { index = 0 }
    let page = try await rpc.popular(index: index, version: "")
    var known = Set<String>()
    let videos = try page.items.compactMap { item -> Video? in
      guard case .video(let card, _, _) = item else { return nil }
      let video = try Self.video(card)
      return known.insert(video.id).inserted ? video : nil
    }
    // The continuation belongs to all raw cards, including unsupported cards at the tail.
    let next = page.nextIndex.flatMap { $0 > index ? String($0) : nil }
    return BrowseVideoPage(items: videos, nextCursor: next)
  }

  public func rankingFeed(region: Int = 0) async throws -> BrowseVideoPage {
    guard let rid = Int32(exactly: region), rid >= 0 else { throw BiliRPCError.invalidArgument }
    let cards = try await rpc.ranking(region: rid)
    var known = Set<String>()
    let videos = try cards.map(Self.video).filter { known.insert($0.id).inserted }
    return BrowseVideoPage(items: videos)
  }

  private static func video(_ card: RPCVideoCard) throws -> Video {
    guard card.aid > 0, let duration = Int(exactly: card.duration), duration >= 0,
      let views = Int(exactly: card.views), views >= 0 else {
      throw BiliRPCError.invalidPayload("browse.video")
    }
    return Video(
      bvid: card.bvid, title: card.title, cover: card.cover, author: card.author?.name ?? "",
      duration: duration, views: views, cid: card.cid > 0 ? card.cid : nil,
      aid: card.aid, authorID: card.author?.mid, avatar: card.author?.avatar,
      publishedAt: card.publishedAt, subtitle: card.subtitle, recommendationReason: card.recommendationReason)
  }
}
