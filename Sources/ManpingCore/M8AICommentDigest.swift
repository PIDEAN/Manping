import Foundation

public struct AICommentItem: Sendable, Equatable, Codable {
  public let id: String
  public let commentID: Int64
  public let text: String
  public let likes: Int64
  public let pinned: Bool
  public let byUploader: Bool
  public let isReply: Bool
}

/// Pinned comment, the most liked comments and the uploader's own replies, each clipped to 200
/// characters with its like count.
public struct AICommentDigest: Sendable, Equatable, Codable {
  public let items: [AICommentItem]
  public let pagesLoaded: Int
  /// The second page failed; the digest uses only the first.
  public let partial: Bool

  public static func make(pages: [RPCCommentPage], uploaderMid: Int64?, hotLimit: Int = 10, uploaderReplyLimit: Int = 3,
    maxCharacters: Int = 200, partial: Bool = false) -> AICommentDigest? {
    var seen = Set<Int64>()
    var all: [RPCComment] = []
    for page in pages {
      for comment in ([page.pinned].compactMap { $0 } + page.comments) where seen.insert(comment.id).inserted { all.append(comment) }
    }
    let pinnedID = pages.compactMap(\.pinned).first?.id ?? all.first(where: \.pinned)?.id
    func isUploader(_ comment: RPCComment) -> Bool { uploaderMid.map { $0 > 0 && comment.author.mid == $0 } ?? false }
    var chosen: [(RPCComment, pinned: Bool, reply: Bool)] = []
    var used = Set<Int64>()
    if let pinnedID, let pinned = all.first(where: { $0.id == pinnedID }) { chosen.append((pinned, true, false)); used.insert(pinned.id) }
    for comment in all.sorted(by: { $0.likes != $1.likes ? $0.likes > $1.likes : $0.id < $1.id })
    where !used.contains(comment.id) && chosen.count < hotLimit + (pinnedID == nil ? 0 : 1) {
      chosen.append((comment, false, false)); used.insert(comment.id)
    }
    let replies = all.flatMap(\.replies).filter { isUploader($0) && !used.contains($0.id) }
    var replyIDs = Set<Int64>()
    for reply in replies.sorted(by: { $0.likes > $1.likes }) where replyIDs.count < uploaderReplyLimit && replyIDs.insert(reply.id).inserted {
      chosen.append((reply, false, true))
    }
    let items = chosen.enumerated().compactMap { index, entry -> AICommentItem? in
      let text = entry.0.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      let clipped = text.count > maxCharacters ? String(text.prefix(maxCharacters)) + "…" : text
      return AICommentItem(id: "m\(index + 1)", commentID: entry.0.id, text: clipped, likes: max(0, entry.0.likes),
        pinned: entry.pinned, byUploader: isUploader(entry.0), isReply: entry.reply)
    }
    guard !items.isEmpty else { return nil }
    return AICommentDigest(items: items, pagesLoaded: pages.count, partial: partial)
  }
  /// Body of `<comments>`: `[m1 置顶·UP 主] text (赞 860)`.
  public func render() -> String {
    items.map { item in
      var marks: [String] = []
      if item.pinned { marks.append("置顶") }
      if item.byUploader { marks.append(item.isReply ? "UP 主回复" : "UP 主") }
      let label = ([item.id] + (marks.isEmpty ? [] : [marks.joined(separator: "·")])).joined(separator: " ")
      return "[\(label)] \(item.text) (赞 \(item.likes))"
    }.joined(separator: "\n")
  }
}

public enum AICommentFetcher {
  /// Reads the first hot page (`next = 0`), then — sequentially, only when the first page is not
  /// the end and gave a usable cursor — the page at `page.next`. A failed second page keeps the
  /// first; cancellation and identity changes still propagate.
  public static func fetch(rpc: any BiliRPCService, oid: Int64, targetType: Int32,
    checkIdentity: @Sendable () async throws -> Void) async throws -> (pages: [RPCCommentPage], partial: Bool, transient: Bool) {
    let first = try await rpc.comments(oid: oid, targetType: targetType, sort: .hot, next: 0)
    try Task.checkCancellation(); try await checkIdentity()
    guard !first.isEnd, first.next > 0 else { return ([first], false, false) }
    do {
      let second = try await rpc.comments(oid: oid, targetType: targetType, sort: .hot, next: first.next)
      try Task.checkCancellation(); try await checkIdentity()
      return ([first, second], false, false)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation(); try await checkIdentity()
      return ([first], true, isTransient(error))
    }
  }

  /// Only known transport and capacity failures may recover without changing the source or account.
  static func isTransient(_ error: any Error) -> Bool {
    if let error = error as? BiliRPCError {
      switch error {
      case .unavailable, .deadlineExceeded, .resourceLimit: return true
      default: return false
      }
    }
    if let error = error as? URLError {
      switch error.code {
      case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet: return true
      default: return false
      }
    }
    return false
  }
}
