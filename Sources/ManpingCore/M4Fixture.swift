import BiliProtocol
import Foundation
import SwiftProtobuf

/// Rich UI samples only. IDs, profiles, text, and responses are entirely synthetic.
public enum M4Fixture {
  public static func reply<Request: SwiftProtobuf.Message>(_ request: Request) throws -> Data? {
    if let request = request as? Bilibili_App_Dynamic_V2_DynAllReq {
      let page = feed(video: false, offset: request.offset)
      var reply = Bilibili_App_Dynamic_V2_DynAllReply()
      reply.dynamicList.list = page.items; reply.dynamicList.historyOffset = page.offset
      reply.dynamicList.updateBaseline = "synthetic-m4-baseline"; reply.dynamicList.hasMore_p = page.hasMore
      reply.upList.list = profiles()
      return try reply.serializedData()
    }
    if let request = request as? Bilibili_App_Dynamic_V2_DynVideoReq {
      let page = feed(video: true, offset: request.offset)
      var reply = Bilibili_App_Dynamic_V2_DynVideoReply()
      reply.dynamicList.list = page.items; reply.dynamicList.historyOffset = page.offset
      reply.dynamicList.updateBaseline = "synthetic-m4-video-baseline"; reply.dynamicList.hasMore_p = page.hasMore
      reply.videoUpList.list = profiles()
      return try reply.serializedData()
    }
    if let request = request as? Bilibili_App_Dynamic_V2_DynAllPersonalReq {
      let page = feed(video: false, offset: request.offset, host: request.hostUid)
      var reply = Bilibili_App_Dynamic_V2_DynAllPersonalReply()
      reply.list = page.items; reply.offset = page.offset; reply.hasMore_p = page.hasMore
      return try reply.serializedData()
    }
    if let request = request as? Bilibili_App_Dynamic_V2_DynVideoPersonalReq {
      let page = feed(video: true, offset: request.offset, host: request.hostUid)
      // The pinned SDK parses this method with DynAllPersonalReply; the shared fields are wire-compatible.
      var reply = Bilibili_App_Dynamic_V2_DynAllPersonalReply()
      reply.list = page.items; reply.offset = page.offset; reply.hasMore_p = page.hasMore
      return try reply.serializedData()
    }
    if let request = request as? Bilibili_App_Dynamic_V2_DynSpaceReq {
      let page = feed(video: false, offset: request.historyOffset, host: request.hostUid)
      var reply = Bilibili_App_Dynamic_V2_DynSpaceRsp()
      reply.list = page.items; reply.historyOffset = page.offset; reply.hasMore_p = page.hasMore
      return try reply.serializedData()
    }
    if request is Bilibili_App_Dynamic_V2_DynThumbReq {
      return try Bilibili_App_Dynamic_V2_NoReply().serializedData()
    }
    if let request = request as? Bilibili_Main_Community_Reply_V1_MainListReq {
      var reply = Bilibili_Main_Community_Reply_V1_MainListReply()
      let cursor = min(18, max(0, Int(request.cursor.next)))
      let indices = request.cursor.mode == .mainListTime ? Array((0..<18).reversed()) : Array(0..<18)
      reply.replies = indices.dropFirst(cursor).prefix(6).map { index in
        var item = comment(oid: request.oid, type: request.type, index: index)
        if index == 0 {
          item.count = 8
          item.replies = (0..<2).map {
            comment(oid: request.oid, type: request.type, index: $0, root: item.id)
          }
        }
        return item
      }
      var top = comment(oid: request.oid, type: request.type, index: 99)
      top.content.message = "置顶：这是本地动态评论样本。最热、最新和楼中楼均使用此动态的具体评论类型。"
      top.replyControl.isUpTop = true
      reply.upTop = top
      reply.cursor.next = Int64(min(18, cursor + reply.replies.count))
      reply.cursor.isEnd = reply.cursor.next >= 18; reply.cursor.mode = request.cursor.mode
      return try reply.serializedData()
    }
    if let request = request as? Bilibili_Main_Community_Reply_V1_DetailListReq {
      var reply = Bilibili_Main_Community_Reply_V1_DetailListReply()
      let cursor = min(8, max(0, Int(request.cursor.next)))
      var root = comment(oid: request.oid, type: request.type, index: 0)
      root.id = request.root; root.count = 8; root.content.message = "本地楼中楼根评论"
      root.replies = (cursor..<min(8, cursor + 4)).map {
        comment(oid: request.oid, type: request.type, index: $0, root: request.root)
      }
      reply.root = root
      reply.cursor.next = Int64(min(8, cursor + root.replies.count)); reply.cursor.isEnd = reply.cursor.next >= 8
      reply.cursor.mode = request.cursor.mode
      return try reply.serializedData()
    }
    return nil
  }

  private static func profiles() -> [Bilibili_App_Dynamic_V2_UpListItem] {
    (0..<5).map { index in
      var item = Bilibili_App_Dynamic_V2_UpListItem()
      item.uid = Int64(30001 + index); item.name = ["创作研究所", "旅行随记", "影像实验室", "音乐频道", "日常分享"][index]
      item.face = "https://fixture.invalid/avatar/\(index + 1)"
      item.hasUpdate_p = index != 3
      return item
    }
  }
  private static func feed(video: Bool, offset: String, host: Int64? = nil)
    -> (items: [Bilibili_App_Dynamic_V2_DynamicItem], offset: String, hasMore: Bool) {
    let next = video ? "m4-video-next" : "m4-all-next"
    let end = video ? "m4-video-end" : "m4-all-end"
    guard offset.isEmpty || offset == next else { return ([], end, false) }
    let start = offset.isEmpty ? 0 : 6
    var items = (start..<(start + 6)).map { index in
      dynamic(index: index, author: host ?? Int64(30001 + index % 5), kind: video ? 0 : index % 5)
    }
    if start > 0 {
      // A duplicate exercises UI deduplication while the server cursor still advances.
      items.insert(dynamic(index: 5, author: host ?? 30001, kind: video ? 0 : 0), at: 0)
    }
    return (items, start == 0 ? next : end, start == 0)
  }
  private static func dynamic(index: Int, author: Int64, kind: Int) -> Bilibili_App_Dynamic_V2_DynamicItem {
    var item = Bilibili_App_Dynamic_V2_DynamicItem()
    item.extend.dynIDStr = String(9_000_000 + author * 100 + Int64(index))
    var authorModule = Bilibili_App_Dynamic_V2_Module()
    authorModule.moduleType = .moduleAuthor
    authorModule.moduleAuthor.author.mid = author
    authorModule.moduleAuthor.author.name = profiles().first { $0.uid == author }?.name ?? "本地用户 \(author)"
    authorModule.moduleAuthor.author.face = "https://fixture.invalid/avatar/\(index % 5 + 1)"
    authorModule.moduleAuthor.ptimeLabelText = "\(index + 1) 小时前"
    var description = Bilibili_App_Dynamic_V2_Module()
    description.moduleType = .moduleDesc
    description.moduleDesc.text = ["新的创作已经发布，一起看看这次的记录。", "午后散步遇见的风景，分享这一刻。", "本地文字动态：保留简单的日常，也保留每一次好奇。", "转发一则有意思的影像，看看另一种视角。", "本地专栏样本：关于创作和观察的几件小事。"][kind]
    description.moduleDesc.text += " [微笑] 看看新的发现 [爱心]"
    description.moduleDesc.desc = [("[微笑]", "smile"), ("[爱心]", "heart")].map { token, name in
      var emote = Bilibili_App_Dynamic_V2_Description()
      emote.type = .emoji; emote.text = token; emote.uri = "https://fixture.invalid/emote/\(name)"
      return emote
    }
    var content = Bilibili_App_Dynamic_V2_Module()
    content.moduleType = .moduleDynamic
    switch kind {
    case 0:
      item.cardType = .av; item.extend.businessID = String(100 + index)
      content.moduleDynamic.type = .mdlDynArchive
      content.moduleDynamic.dynArchive.avid = Int64(100 + index)
      content.moduleDynamic.dynArchive.cid = Int64(1000 + index)
      content.moduleDynamic.dynArchive.title = "动态视频 · \(index + 1) · 记录创作与生活"
      content.moduleDynamic.dynArchive.cover = "https://fixture.invalid/cover/\(index)"
      content.moduleDynamic.dynArchive.uri = "https://www.bilibili.com/video/av\(100 + index)"
      content.moduleDynamic.dynArchive.duration = 180; content.moduleDynamic.dynArchive.view = 120_000
    case 1:
      item.cardType = .draw; item.extend.businessID = String(7000 + index)
      content.moduleDynamic.type = .mdlDynDraw; content.moduleDynamic.dynDraw.id = Int64(7000 + index)
      content.moduleDynamic.dynDraw.items = (0..<3).map { image in
        var draw = Bilibili_App_Dynamic_V2_MdlDynDrawItem()
        draw.src = "https://fixture.invalid/cover/\(index * 3 + image)"; draw.width = 800; draw.height = 800
        return draw
      }
    case 2: item.cardType = .word
    case 3:
      item.cardType = .forward; content.moduleDynamic.type = .mdlDynForward
      content.moduleDynamic.dynForward.item = dynamic(index: index + 100, author: 30003, kind: 1)
    default:
      item.cardType = .article; item.extend.businessID = String(2000 + index)
      content.moduleDynamic.type = .mdlDynArticle; content.moduleDynamic.dynArticle.id = Int64(2000 + index)
      content.moduleDynamic.dynArticle.title = "本地创作笔记 · \(index + 1)"
      content.moduleDynamic.dynArticle.desc = "这是一篇用于检查动态专栏卡片的本地样本。"
      content.moduleDynamic.dynArticle.covers = ["https://fixture.invalid/cover/\(index)"]
    }
    var stat = Bilibili_App_Dynamic_V2_Module()
    stat.moduleType = .moduleStat; stat.moduleStat.like = Int64(120 + index * 15)
    stat.moduleStat.reply = 18; stat.moduleStat.repost = Int64(3 + index)
    stat.moduleStat.likeInfo.isLike = index % 3 == 0
    item.modules = [authorModule, description]
    if kind != 2 { item.modules.append(content) }
    item.modules.append(stat)
    return item
  }
  private static func comment(oid: Int64, type: Int64, index: Int, root: Int64 = 0)
    -> Bilibili_Main_Community_Reply_V1_ReplyInfo {
    var item = Bilibili_Main_Community_Reply_V1_ReplyInfo()
    item.id = root > 0 ? root + Int64(1000 + index) : 1_000_000 + (oid % 100_000) * 100 + type * 100 + Int64(index)
    item.oid = oid; item.type = type; item.root = root; item.parent = root
    item.member.mid = Int64(40001 + index); item.member.name = "本地评论者 \(index + 1)"
    item.member.face = "https://fixture.invalid/avatar/\(index % 5 + 1)"
    item.content.message = "\(root > 0 ? "楼中楼回复" : "评论") \(index + 1)：这是一条本地样本，用于检查动态评论、分页和回复布局。"
    item.content.message += " [微笑] 和正文同一行 [爱心]"
    for (token, name) in [("[微笑]", "smile"), ("[爱心]", "heart")] {
      var emote = Bilibili_Main_Community_Reply_V1_Emote()
      emote.text = token; emote.url = "https://fixture.invalid/emote/\(name)"
      item.content.emotes[token] = emote
    }
    item.ctime = 1_700_000_000 + Int64(index * 60); item.like = Int64(max(0, 60 - index))
    item.replyControl.action = index % 4 == 0 ? 1 : 0
    return item
  }
}
