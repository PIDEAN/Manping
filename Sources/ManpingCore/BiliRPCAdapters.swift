// Adapted from BiliKernel 22fdf8ca (GPL-3.0), Copyright (c) Richasy.
import BiliProtocol
import Foundation

// Mappings follow the exact BiliKernel adapters; unsupported oneofs remain visible in the DTO.
enum BiliRPCAdapter {
  static func url(_ raw: String) -> URL? {
    guard !raw.isEmpty else { return nil }
    let url = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw)
    return ["http", "https"].contains(url?.scheme ?? "") ? url : nil
  }
  static func bounded(_ count: Int) throws {
    guard count <= 512 else { throw BiliRPCError.resourceLimit }
  }
  static func comment(_ info: Bilibili_Main_Community_Reply_V1_ReplyInfo, depth: Int = 0) throws
    -> RPCComment
  {
    guard depth <= 8 else { throw BiliRPCError.resourceLimit }
    guard info.id > 0, info.hasContent, info.hasMember else {
      throw BiliRPCError.invalidPayload("comment")
    }
    try bounded(info.replies.count)
    return RPCComment(
      id: info.id, root: info.root,
      author: RPCUser(mid: info.member.mid, name: info.member.name, avatar: url(info.member.face)),
      text: info.content.message,
      emotes: info.content.emotes.keys.sorted().map {
        RPCEmote(text: $0, image: url(info.content.emotes[$0]!.url))
      },
      createdAt: info.ctime, likes: info.like, replyCount: info.count,
      liked: info.replyControl.action == 1,
      pinned: info.replyControl.isAdminTop || info.replyControl.isUpTop,
      replies: try info.replies.map { try comment($0, depth: depth + 1) })
  }
  static func comments(
    _ reply: Bilibili_Main_Community_Reply_V1_MainListReply, oid: Int64, type: Int32
  ) throws -> RPCCommentPage {
    guard reply.hasCursor else { throw BiliRPCError.invalidPayload("comment.cursor") }
    try bounded(reply.replies.count)
    let top = reply.hasUpTop ? reply.upTop : reply.hasVoteTop ? reply.voteTop : nil
    return RPCCommentPage(
      oid: oid, targetType: type, comments: try reply.replies.map { try comment($0) },
      pinned: try top.map { try comment($0) }, next: reply.cursor.next, isEnd: reply.cursor.isEnd)
  }
  static func comments(
    _ reply: Bilibili_Main_Community_Reply_V1_DetailListReply, oid: Int64, type: Int32
  ) throws -> RPCCommentPage {
    guard reply.hasCursor, reply.hasRoot else {
      throw BiliRPCError.invalidPayload("comment.detail")
    }
    try bounded(reply.root.replies.count)
    return RPCCommentPage(
      oid: oid, targetType: type, comments: try reply.root.replies.map { try comment($0) },
      pinned: try comment(reply.root), next: reply.cursor.next, isEnd: reply.cursor.isEnd)
  }
  static func dynamic(_ item: Bilibili_App_Dynamic_V2_DynamicItem, depth: Int = 0) throws
    -> RPCDynamic
  {
    guard depth <= 8 else { throw BiliRPCError.resourceLimit }
    try bounded(item.modules.count)
    let author = item.modules.first { $0.moduleType == .moduleAuthor }?.moduleAuthor
    let forwardAuthor = item.modules.first { $0.moduleType == .moduleAuthorForward }?
      .moduleAuthorForward
    let description = item.modules.first { $0.moduleType == .moduleDesc }?.moduleDesc
    let main = item.modules.first { $0.moduleType == .moduleDynamic }?.moduleDynamic
    let stat = item.modules.first { $0.moduleType == .moduleStat }?.moduleStat
    let user: RPCUser?
    if let author, author.hasAuthor {
      user = RPCUser(
        mid: author.author.mid, name: author.author.name, avatar: url(author.author.face))
    } else if let forwardAuthor {
      user = RPCUser(
        mid: forwardAuthor.uid, name: forwardAuthor.title.map(\.text).joined(),
        avatar: url(forwardAuthor.faceURL))
    } else {
      user = nil
    }
    let content: RPCDynamicContent
    switch main?.moduleItem {
    case .dynArchive(let video):
      if video.isPGC {
        content = .episode(
          RPCEpisodeCard(
            aid: video.avid, cid: video.cid, episodeID: video.episodeID,
            seasonID: video.pgcSeasonID, title: video.title, cover: url(video.cover), uri: video.uri
          ))
      } else {
        content = .video(
          RPCVideoCard(
            aid: video.avid, bvid: video.bvid, cid: video.cid,
            title: video.title, cover: url(video.cover), author: user, duration: video.duration,
            views: Int64(video.view), uri: video.uri))
      }
    case .dynPgc(let episode):
      content = .episode(
        RPCEpisodeCard(
          aid: episode.aid, cid: episode.cid, episodeID: episode.epid,
          seasonID: episode.seasonID, title: episode.title, cover: url(episode.cover),
          uri: episode.uri))
    case .dynForward(let forward):
      content =
        forward.hasItem
        ? .forward(try dynamic(forward.item, depth: depth + 1))
        : .unsupported(type: item.cardType.rawValue)
    case .dynDraw(let draw):
      try bounded(draw.items.count)
      content = .images(draw.items.compactMap { url($0.src) })
    case .dynArticle(let article):
      content = .article(
        RPCArticleCard(
          id: article.id, title: article.title, text: article.desc,
          covers: article.covers.compactMap(url), uri: article.uri))
    case nil where item.cardType == .word: content = .text
    default: content = .unsupported(type: main?.type.rawValue ?? item.cardType.rawValue)
    }
    let targetType: Int32
    switch item.cardType {
    case .forward, .word, .live: targetType = 17
    case .draw: targetType = 11
    case .av, .pgc, .ugcSeason, .medialist: targetType = 1
    case .courses, .coursesSeason: targetType = 33
    case .article: targetType = 12
    case .music: targetType = 14
    default: targetType = 0
    }
    let target: String
    if targetType == 17 {
      target = item.extend.dynIDStr
    } else if case .dynPgc(let pgc) = main?.moduleItem {
      target = String(pgc.aid)
    } else {
      target = item.extend.businessID
    }
    return RPCDynamic(
      id: item.extend.dynIDStr, author: user,
      timeLabel: author?.ptimeLabelText ?? forwardAuthor?.ptimeLabelText ?? "",
      text: description.map { $0.text.isEmpty ? $0.desc.map(\.text).joined() : $0.text } ?? "",
      emotes: description?.desc.filter { $0.type == .emoji }.map {
        RPCEmote(text: $0.text, image: url($0.uri))
      } ?? [],
      likes: stat?.like ?? 0, replies: stat?.reply ?? 0, reposts: stat?.repost ?? 0,
      liked: stat?.likeInfo.isLike ?? false, commentTargetType: targetType, commentTargetID: target,
      content: content)
  }
  static func dynamics(
    _ items: [Bilibili_App_Dynamic_V2_DynamicItem], offset: String, baseline: String = "",
    hasMore: Bool, users: [Bilibili_App_Dynamic_V2_UpListItem] = []
  ) throws -> RPCDynamicPage {
    try bounded(items.count)
    return RPCDynamicPage(
      items: try items.map { try dynamic($0) }, historyOffset: offset,
      updateBaseline: baseline, hasMore: hasMore,
      users: users.filter { $0.uid > 0 }.map { RPCDynamicProfile(id: $0.uid, name: $0.name,
        avatar: url($0.face), hasUnread: $0.hasUpdate_p, isLive: $0.liveState == .liveLive) })
  }
  static func history(_ reply: Bilibili_App_Interfaces_V1_CursorV2Reply) throws -> RPCHistoryPage {
    try bounded(reply.items.count)
    guard reply.hasCursor || (reply.items.isEmpty && !reply.hasMore_p) else {
      throw BiliRPCError.invalidPayload("history.cursor")
    }
    return RPCHistoryPage(
      items: reply.items.map { item in
        let content: RPCHistoryContent
        switch item.cardItem {
        case .cardUgc(let video):
          content = .video(
            RPCVideoCard(
              aid: item.kid, bvid: video.bvid, cid: video.cid,
              title: item.title, cover: url(video.cover),
              author: RPCUser(mid: video.mid, name: video.name, avatar: nil),
              duration: video.duration, views: video.view, uri: item.uri), progress: video.progress)
        case .cardOgv(let episode):
          content = .episode(
            cover: url(episode.cover), progress: episode.progress, duration: episode.duration,
            subtitle: episode.subtitle)
        case .cardArticle(let article):
          content = .article(
            author: RPCUser(mid: article.mid, name: article.name, avatar: nil),
            covers: article.covers.compactMap(url))
        case .cardLive(let live):
          content = .live(
            author: RPCUser(mid: live.mid, name: live.name, avatar: nil), cover: url(live.cover),
            status: live.status)
        case .cardCheese(let course):
          content = .course(
            cover: url(course.cover), progress: course.progress, duration: course.duration,
            subtitle: course.subtitle)
        case nil: content = .unsupported
        }
        return RPCHistoryItem(
          id: item.kid, oid: item.oid, business: item.business, title: item.title,
          uri: item.uri, viewedAt: item.viewAt, content: content)
      }, max: reply.cursor.max, hasMore: reply.hasMore_p)
  }
  // App popular cards expose formatted counts and duration labels, not raw numeric fields.
  private static func countNumber(_ label: String) -> Int64 {
    let text = label.replacingOccurrences(of: "次", with: "").replacingOccurrences(of: ",", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let multiplier: Double = text.hasSuffix("亿") ? 100_000_000 : (text.hasSuffix("万") ? 10_000 : 1)
    let number = multiplier == 1 ? text : String(text.dropLast())
    guard let value = Double(number), value.isFinite, value >= 0,
      value * multiplier < Double(Int64.max) else { return 0 }
    return Int64(value * multiplier)
  }
  private static func durationSeconds(_ label: String) -> Int64 {
    let segments = label.split(separator: ":").compactMap { Int64($0) }
    guard (2...3).contains(segments.count), segments.count == label.split(separator: ":").count,
      segments.allSatisfy({ (0...999).contains($0) }) else { return 0 }
    return segments.reduce(0) { $0 * 60 + $1 }
  }
  static func ranking(_ reply: Bilibili_App_Show_Rank_V1_RankListReply) throws -> [RPCVideoCard] {
    try bounded(reply.items.count)
    return try reply.items.map { item in
      guard let aid = Int64(item.param), aid > 0 else {
        throw BiliRPCError.invalidPayload("ranking.aid")
      }
      return RPCVideoCard(
        aid: aid, bvid: "", cid: item.cid, title: item.title,
        cover: url(item.cover),
        author: RPCUser(mid: item.mid, name: item.name, avatar: url(item.face)),
        duration: item.duration, views: Int64(item.play), uri: item.uri,
        publishedAt: item.pubDate > 0 ? item.pubDate : nil)
    }
  }
  static func popular(_ reply: Bilibili_App_Show_Popular_V1_PopularReply) throws -> RPCPopularPage {
    try bounded(reply.items.count)
    var next: Int64?
    let items = try reply.items.map { card -> RPCPopularItem in
      let base: Bilibili_App_Card_V1_Base?
      let kind: String
      switch card.item {
      case .smallCoverV5(let video):
        if video.hasBase { next = max(next ?? 0, video.base.idx) }
        guard video.base.cardGoto == "av", !video.base.uri.contains("bangumi") else {
          return .unsupported(kind: "smallCoverV5")
        }
        guard video.hasBase, let aid = Int64(video.base.param), aid > 0 else {
          throw BiliRPCError.invalidPayload("popular.aid")
        }
        let share = video.base.threePointV4.sharePlane
        let author = !share.author.isEmpty
          ? RPCUser(mid: share.authorID, name: share.author, avatar: video.hasUp ? url(video.up.avatar.cover) : nil)
          : video.hasUp
            ? RPCUser(mid: video.up.id, name: video.up.name, avatar: url(video.up.avatar.cover))
            : video.base.hasArgs
              ? RPCUser(mid: video.base.args.upID, name: video.base.args.upName, avatar: nil) : nil
        let subtitle = video.rightDesc2.split(separator: "·").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return .video(
          RPCVideoCard(
            aid: aid, bvid: video.base.threePointV4.sharePlane.bvid,
            cid: video.base.playerArgs.cid > 0 ? video.base.playerArgs.cid : share.firstCid,
            title: video.base.title, cover: url(video.base.cover),
            author: author,
            duration: video.base.playerArgs.duration > 0 ? video.base.playerArgs.duration : durationSeconds(video.coverRightText1),
            views: countNumber(share.playNumber), uri: video.base.uri,
            subtitle: subtitle?.isEmpty == false ? subtitle : nil,
            recommendationReason: video.rcmdReasonStyle.text.isEmpty ? nil : video.rcmdReasonStyle.text),
          index: video.base.idx,
          durationLabel: video.coverRightText1)
      case .largeCoverV1(let v):
        base = v.hasBase ? v.base : nil
        kind = "largeCoverV1"
      case .threeItemAllV2(let v):
        base = v.hasBase ? v.base : nil
        kind = "threeItemAllV2"
      case .threeItemV1(let v):
        base = v.hasBase ? v.base : nil
        kind = "threeItemV1"
      case .hotTopic(let v):
        base = v.hasBase ? v.base : nil
        kind = "hotTopic"
      case .threeItemHV5(let v):
        base = v.hasBase ? v.base : nil
        kind = "threeItemHV5"
      case .middleCoverV3(let v):
        base = v.hasBase ? v.base : nil
        kind = "middleCoverV3"
      case .largeCoverV4(let v):
        base = v.hasBase ? v.base : nil
        kind = "largeCoverV4"
      case .popularTopEntrance(let v):
        base = v.hasBase ? v.base : nil
        kind = "popularTopEntrance"
      case .rcmdOneItem(let v):
        base = v.hasBase ? v.base : nil
        kind = "rcmdOneItem"
      case .smallCoverV5Ad(let v):
        base = v.hasBase ? v.base : nil
        kind = "smallCoverV5Ad"
      case .topicList(let v):
        base = v.hasBase ? v.base : nil
        kind = "topicList"
      case nil:
        base = nil
        kind = "unknown"
      }
      if let base { next = max(next ?? 0, base.idx) }
      return .unsupported(kind: kind)
    }
    return RPCPopularPage(items: items, nextIndex: next, version: reply.ver)
  }
}
