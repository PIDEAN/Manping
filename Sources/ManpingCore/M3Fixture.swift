import BiliProtocol
import Foundation
import GRPCCore
import SwiftProtobuf

// Synthetic, deterministic data. No real account, credentials, or external writes.
public enum M3Fixture {
  public static let owner: Int64 = 123
  public static func uiResponse(path: String, parameters: [String: String]) -> Data? {
    if let space = spaceResponse(path: path, parameters: parameters, ui: true) { return space }
    let page = max(1, Int(parameters["page"] ?? parameters["pn"] ?? "1") ?? 1)
    let data: Any
    switch path {
    case "/x/relation": data = ["attribute": 2, "special": 0]
    case "/x/v2/search/trending/ranking", "/x/v2/search/recommend":
      data = ["list": ["动画新作", "旅行记录", "桌面布置", "音乐现场", "科学与生活"].enumerated().map { index, word in
        ["position": index + 1, "keyword": word, "title": word, "show_name": word] as [String: Any]
      }]
    case "/x/web-interface/card":
      let mid = Int64(parameters["mid"] ?? "123") ?? 123
      var user = uiUser(mid); user["Official"] = ["role": 1, "title": "旅行 UP 主", "desc": "旅行领域优质 UP 主", "type": 0]
      data = ["card": user, "space": ["l_img": "https://fixture.invalid/cover/3"], "archive_count": 40, "follower": 12000, "follow": 40, "like_num": 234567]
    case "/x/relation/tags":
      data = [["tagid": 0, "name": "默认分组", "count": 100], ["tagid": 1, "name": "音乐与生活", "count": 64]]
    case "/x/relation/tag":
      let total = parameters["tagid"] == "1" ? 64 : 100
      let start = (page - 1) * 50
      data = start < total ? (start..<min(start + 50, total)).map { uiUser(Int64(10001 + $0)) } : []
    case "/x/relation/followers":
      let start = (page - 1) * 50
      data = ["list": start < 100 ? (start..<min(start + 50, 100)).map { uiUser(Int64(10001 + $0)) } : [], "total": 100]
    case "/x/web-interface/wbi/search/type":
      let kind = parameters["search_type"] ?? "video"
      let items: [[String: Any]] = (0..<12).map { index in
        let offset = (page - 1) * 12 + index
        switch kind {
        case "bili_user": return searchUser(Int64(10001 + offset), ui: true)
        case "media_bangumi", "media_ft": return ["season_id": 99 + offset, "title": "本地剧集 · \(offset + 1)", "cover": "https://fixture.invalid/cover/\(offset)"]
        case "live_room": return ["roomid": 88 + offset, "title": "本地直播 · \(offset + 1)", "uname": "本地主播", "cover": "https://fixture.invalid/cover/\(offset)"]
        case "article": return ["id": 77 + offset, "title": "本地专栏 · \(offset + 1)", "image_urls": ["https://fixture.invalid/cover/\(offset)"]]
        default: return searchVideo(uiVideo(offset), mid: 10001)
        }
      }
      data = ["result": page <= 2 ? items : [], "numPages": 2, "numResults": 24]
    case "/x/v2/history/toview":
      let start = (page - 1) * 40
      data = ["list": start < 48 ? (start..<min(start + 40, 48)).map(uiVideo) : [], "count": 48]
    case "/x/v3/fav/resource/list":
      let start = (page - 1) * 20
      let items: [[String: Any]] = start < 36 ? (start..<min(start + 20, 36)).map { index in
        ["id": 789 + index, "type": 2, "title": "本地收藏 · \(index + 1)", "cover": "https://fixture.invalid/cover/\(index)", "duration": 180 + index,
          "fav_time": 1_760_000_000 - index * 3600, "upper": ["mid": 10001, "name": "本地 UP 主", "face": "https://fixture.invalid/avatar/1"], "cnt_info": ["play": 120000]]
      } : []
      data = ["medias": items, "has_more": page < 2, "info": ["media_count": 36]]
    default: return response(path: path, parameters: parameters)
    }
    return try? JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
  }
  private static func uiVideo(_ index: Int) -> [String: Any] {
    ["aid": 789 + index, "title": "本地视频 · \(index + 1)", "pic": "https://fixture.invalid/cover/\(index)",
      "cid": 456 + index, "duration": 180 + index, "pubdate": 1_760_000_000 - index * 3600,
      "add_at": 1_760_000_000 - index * 3600, "owner": uiUser(10001), "stat": ["view": 120000 + index * 1000]]
  }
  private static func uiUser(_ mid: Int64) -> [String: Any] {
    ["mid": mid, "uname": "本地 UP 主 \(mid)", "name": "本地 UP 主 \(mid)", "face": "https://fixture.invalid/avatar/\(mid % 8)",
      "sign": "记录日常与新发现，这是隔离的本地样本。", "fans": 12000, "attention": 40, "attribute": mid % 3 == 0 ? 0 : 2, "level_info": ["current_level": 6], "vip": ["status": 1, "sign": "年度大会员"]]
  }
  private static func searchVideo(_ video: [String: Any], mid: Int64) -> [String: Any] {
    var video = video; video["owner"] = nil; video["mid"] = mid
    video["author"] = "本地 UP 主"; video["upic"] = "//fixture.invalid/avatar/1"
    return video
  }
  private static func searchUser(_ mid: Int64, ui: Bool) -> [String: Any] {
    ["mid": mid, "uname": ui ? "本地 UP 主 \(mid)" : "Fixture owner", "upic": "//fixture.invalid/avatar/\(mid % 8)",
      "usign": "记录日常与新发现", "fans": 12000, "videos": 40, "level": 6,
      "is_upuser": 1, "official_verify": ["type": mid % 2 == 0 ? 0 : -1, "desc": mid % 2 == 0 ? "旅行领域优质 UP 主" : ""],
      "res": [uiVideo(0)], "is_live": mid % 3 == 0 ? 1 : 0, "room_id": 88]
  }
  private static func spaceResponse(path: String, parameters: [String: String], ui: Bool) -> Data? {
    let page = Int(parameters["pn"] ?? parameters["page_num"] ?? "1") ?? 1
    let total = ui ? 40 : 1
    let start = (page - 1) * 30
    let videos = start < total ? (start..<min(start + 30, total)).map(uiVideo) : []
    let data: Any
    switch path {
    case "/x/space/wbi/arc/search":
      data = ["list": ["vlist": videos, "tlist": ["160": ["tid": 160, "name": "生活", "count": total]]], "page": ["count": total]]
    case "/x/v2/space/archive/cursor":
      let aid = Int(parameters["aid"] ?? "0") ?? 0
      let offset = aid == 0 ? 0 : aid - 789 + 1
      let items: [[String: Any]] = offset < total ? (offset..<min(offset + 30, total)).map { index in
        ["param": String(789 + index), "title": "本地投稿 · \(index + 1)", "cover": "https://fixture.invalid/cover/\(index)",
          "author": "本地 UP 主", "goto": "av", "length": "03:20", "duration": 200, "play": 120000,
          "first_cid": 456 + index, "ctime": 1_760_000_000 - index * 1000]
      } : []
      data = ["item": items, "count": total, "has_next": offset + 30 < total ? 1 : 0]
    case "/x/space/navnum": data = ["video": total, "season_num": 2]
    case "/x/space/upstat": data = [:] as [String: Any]
    case "/x/space/top/arc": data = uiVideo(0)
    case "/x/space/masterpiece": data = [uiVideo(1), uiVideo(2), uiVideo(3)]
    case "/x/polymer/web-space/seasons_series_list":
      data = ["items_lists": ["page": ["page_num": page, "page_size": 20, "total": 2],
        "seasons_list": page == 1 ? [["meta": ["season_id": 22, "name": "川藏线慢旅行", "cover": "https://fixture.invalid/cover/0", "total": total], "archives": [uiVideo(0)]]] : [],
        "series_list": page == 1 ? [["meta": ["series_id": 22, "name": "器材与装备", "total": total], "archives": [uiVideo(1)]]] : []]]
    case "/x/polymer/web-space/seasons_archives_list", "/x/series/archives":
      let descending = parameters["sort_reverse"] == "true" || parameters["sort"] == "desc"
      let indices = descending ? Array((0..<total).reversed()) : Array(0..<total)
      data = ["archives": Array(indices.dropFirst(start).prefix(30)).map(uiVideo), "page": ["total": total]]
    default: return nil
    }
    return try? JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
  }
  public static func response(path: String, parameters: [String: String] = [:]) -> Data? {
    if let space = spaceResponse(path: path, parameters: parameters, ui: false) { return space }
    let video: [String: Any] = ["aid": 789, "bvid": "BVfixture123", "title": "M3 fixture video",
      "pic": "https://fixture.invalid/cover/1", "cid": 456, "duration": 90,
      "owner": ["mid": 123, "name": "Fixture owner"], "stat": ["view": 900]]
    let user: [String: Any] = ["mid": 123, "uname": "Fixture owner", "name": "Fixture owner",
      "face": "https://fixture.invalid/avatar/1", "sign": "Synthetic profile", "fans": 5, "attention": 2, "level_info": ["current_level": 5], "vip": ["status": 1, "sign": "大会员"]]
    let folder: [String: Any] = ["id": 11, "title": "Fixture favorites", "media_count": 1,
      "type": 2, "upper": ["mid": 123]]
    let season: [String: Any] = ["id": 22, "title": "Fixture collection", "media_count": 1,
      "type": 21, "upper": ["mid": 123]]
    let data: Any
    var result = false
    switch path {
    case "/x/web-interface/wbi/search/type":
      let kind = parameters["search_type"] ?? "video"
      let item: [String: Any]
      switch kind {
      case "bili_user": item = searchUser(123, ui: false)
      case "media_bangumi", "media_ft": item = ["season_id": 99, "title": "Fixture series"]
      case "live_room": item = ["roomid": 88, "title": "Fixture room", "uname": "Fixture owner"]
      case "article": item = ["id": 77, "title": "Fixture article", "image_urls": ["https://fixture.invalid/cover/2"]]
      default: item = searchVideo(video, mid: 123)
      }
      data = ["result": parameters["page"] == "2" ? [] : [item], "numPages": 2, "numResults": 1]
    case "/x/web-interface/card": data = ["card": user, "space": ["l_img": "https://fixture.invalid/cover/3"], "archive_count": 8, "follower": 5, "follow": 2, "like_num": 321]
    case "/x/relation/tags": data = [["tagid": 0, "name": "默认分组", "count": 1]]
    case "/x/relation/tag": data = [user]
    case "/x/relation/followers": data = ["list": [user], "total": 1]
    case "/x/v3/fav/folder/space/v2":
      data = ["space_infos": [["id": 2, "name": "我收藏的", "mediaListResponse": ["list": [season]]]]]
    case "/x/v3/fav/folder/created/list-all": data = ["list": [folder]]
    case "/x/v3/fav/folder/collected/list": data = ["list": []]
    case "/x/v3/fav/resource/list":
      data = ["medias": [["id": 789, "type": 2, "title": "Fixture favorite video", "duration": 90,
        "upper": ["mid": 123, "name": "Fixture owner"], "cnt_info": ["play": 900]]],
        "has_more": false, "info": ["media_count": 1]]
    case "/x/polymer/web-space/seasons_archives_list": data = ["archives": [video], "page": ["total": 1]]
    case "/pgc/app/follow/v2/bangumi", "/pgc/app/follow/v2/cinema":
      data = ["follow_list": [["season_id": 99, "title": "Fixture series",
        "new_ep": ["index_show": "全 12 集"]]], "total": 1]; result = true
    case "/x/v2/history/toview": data = ["list": [video], "count": 1]
    default: return nil
    }
    return try? JSONSerialization.data(withJSONObject: ["code": 0, result ? "result" : "data": data])
  }
}

public actor M3FixtureRPCTransport: BiliRPCTransport {
  private let richUI: Bool
  public init(richUI: Bool = false) { self.richUI = richUI }
  public func unary<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    _ request: Request, response: Response.Type, descriptor: MethodDescriptor, metadata: Metadata
  ) async throws -> Response {
    if richUI, let data = try M4Fixture.reply(request) { return try Response(serializedBytes: data) }
    let payload: Data
    if let request = request as? Bilibili_App_Show_Popular_V1_PopularResultReq {
      var reply = Bilibili_App_Show_Popular_V1_PopularReply()
      if request.idx < 199 {
        let start = request.idx == 0 ? 0 : 12
        reply.items = (start..<(start + 12)).map { Self.popularCard($0) }
        // Duplicate and non-video tail exercise deduplication and the raw continuation.
        reply.items.append(Self.popularCard(start))
        var tail = Bilibili_App_Card_V1_Card()
        tail.hotTopic.base.idx = request.idx == 0 ? 99 : 199
        reply.items.append(tail)
      }
      reply.ver = "synthetic-popular"
      payload = try reply.serializedData()
    } else if let request = request as? Bilibili_App_Show_Rank_V1_RankRegionResultReq {
      var reply = Bilibili_App_Show_Rank_V1_RankListReply()
      reply.items = (0..<18).map { index in
        var item = Bilibili_App_Show_Rank_V1_Item()
        item.param = String(100 + index); item.cid = Int64(1000 + index)
        item.title = "本地榜单 · \(request.rid == 0 ? "全区" : String(request.rid)) · \(index + 1)"
        item.cover = "https://fixture.invalid/cover/\(index)"
        item.mid = 10001; item.name = "本地样本"; item.face = "https://fixture.invalid/avatar/1"
        item.pubDate = 1_700_000_000; item.duration = 180; item.play = 120_000
        item.goto = "av"; item.uri = "https://www.bilibili.com/video/av\(100 + index)"
        return item
      }
      payload = try reply.serializedData()
    } else if let request = request as? Bilibili_App_Interfaces_V1_SearchArchiveReq {
      var reply = Bilibili_App_Interfaces_V1_SearchArchiveReply()
      var arc = Bilibili_App_Interfaces_V1_Arc()
      arc.archive.aid = 789; arc.archive.title = "Fixture space video"
      arc.archive.firstCid = 456; arc.archive.duration = 90
      arc.archive.author.mid = 123; arc.archive.author.name = "Fixture owner"
      reply.archives = [arc]; reply.total = 1
      if richUI {
        let start = max(0, Int(request.pn - 1)) * 20
        reply.archives = start < 40 ? (start..<min(start + 20, 40)).map { index in
          var item = arc
          item.archive.aid = Int64(789 + index); item.archive.title = "本地投稿 · \(index + 1)"
          item.archive.pic = "https://fixture.invalid/cover/\(index)"
          item.archive.stat.view = Int32(120000 + index * 1000)
          return item
        } : []
        reply.total = 40
      }
      payload = try reply.serializedData()
    } else if let request = request as? Bilibili_App_Interfaces_V1_SuggestionResult3Req {
      var reply = Bilibili_App_Interfaces_V1_SuggestionResult3Reply()
      reply.list = (0..<5).map { index in
        var item = Bilibili_App_Interfaces_V1_ResultItem()
        item.keyword = "\(request.keyword) \(["视频", "新作", "合集", "音乐", "记录"][index])"
        item.title = item.keyword
        return item
      }
      payload = try reply.serializedData()
    } else if request is Bilibili_App_Interfaces_V1_DeleteReq || request is Bilibili_App_Interfaces_V1_ClearReq {
      payload = try Bilibili_App_Interfaces_V1_NoReply().serializedData()
    } else if let request = request as? Bilibili_App_Interfaces_V1_CursorReq {
      var reply = Bilibili_App_Interfaces_V1_CursorV2Reply()
      let start = Int(request.cursor.max)
      reply.items = start < 24 ? (start..<min(start + 12, 24)).map { index in
        var item = Self.historyItem()
        item.kid = Int64(321 + index); item.oid = Int64(789 + index)
        item.title = "本地观看记录 · \(index + 1)"; item.viewAt -= Int64(index * 3600)
        if request.business == "article" {
          item.business = "article"; item.uri = "https://www.bilibili.com/read/cv\(321 + index)"
          item.cardArticle.covers = ["https://fixture.invalid/cover/\(index)"]
        } else if request.business == "live" {
          item.business = "live"; item.uri = "https://live.bilibili.com/\(321 + index)"
          item.cardLive.cover = "https://fixture.invalid/cover/\(index)"
        } else { item.cardUgc.cover = "https://fixture.invalid/cover/\(index)" }
        return item
      } : []
      reply.cursor.max = Int64(start + reply.items.count); reply.hasMore_p = start + reply.items.count < 24
      payload = try reply.serializedData()
    } else if request is Bilibili_App_Interfaces_V1_SearchReq {
      var reply = Bilibili_App_Interfaces_V1_SearchReply()
      reply.items = [Self.historyItem()]; reply.page.total = 1
      payload = try reply.serializedData()
    } else if let request = request as? Bilibili_App_Interfaces_V1_CursorV2Req {
      var reply = Bilibili_App_Interfaces_V1_CursorV2Reply()
      var item = Self.historyItem()
      if request.business == "article" {
        item.business = "article"; item.kid = 77; item.title = "Fixture history article"
        item.uri = "bilibili://article/77"
        item.cardArticle.name = "Fixture owner"; item.cardArticle.mid = 123
        item.cardArticle.covers = ["https://fixture.invalid/cover/2"]
      } else if request.business == "live" {
        item.business = "live"; item.kid = 88; item.title = "Fixture history live"
        item.uri = "bilibili://live/88"
        item.cardLive.name = "Fixture owner"; item.cardLive.mid = 123
        item.cardLive.cover = "https://fixture.invalid/cover/3"
      }
      reply.items = [item]; reply.cursor.max = 1
      payload = try reply.serializedData()
    } else if request is Bilibili_App_Dynamic_V2_DynAllPersonalReq {
      var reply = Bilibili_App_Dynamic_V2_DynAllPersonalReply()
      var item = Bilibili_App_Dynamic_V2_DynamicItem()
      item.extend.dynIDStr = "fixture-dynamic"
      item.cardType = .word
      var description = Bilibili_App_Dynamic_V2_Module()
      description.moduleType = .moduleDesc
      description.moduleDesc.text = "这是用户空间的本地动态样本，用于检查列表布局。"
      var author = Bilibili_App_Dynamic_V2_Module()
      author.moduleType = .moduleAuthor
      author.moduleAuthor.author.mid = 123
      author.moduleAuthor.author.name = "Fixture owner"
      author.moduleAuthor.author.face = "https://fixture.invalid/avatar/1"
      author.moduleAuthor.ptimeLabelText = "刚刚"
      item.modules = [author, description]
      reply.list = [item]
      payload = try reply.serializedData()
    } else { throw BiliRPCError.invalidArgument }
    return try Response(serializedBytes: payload)
  }
  /// Made-up videos for the 热门 grid, one per sample cover (`cover/0`…`cover/15`).
  public static let popularTitles = [
    "走进山野：记录一段慢下来的旅程", "从零搭建桌面工作空间｜整理与收纳", "城市的声音：雨后的街道与夜色", "用镜头发现日常里的光影",
    "聊聊经典游戏背后的设计", "一周读书分享：故事与想象力", "在家做一碗热气腾腾的面", "周末去划船：和狗狗一起看湖",
    "小型 Live 现场｜木吉他与一束暖光", "一杯拿铁的早晨：咖啡拉花入门", "手柄横评：握感、延迟与续航", "后厨一日：备菜的节奏",
    "老式麦克风的声音为什么好听", "夜晚的城市漫步｜街头灯光", "旧钢琴修复记录：从走音到重新开口", "沿着小路往森林深处走",
  ]
  private static let popularAuthors = ["山野记录", "桌面研究所", "城市漫游者", "光影日记", "游戏设计笔记", "周末读书会", "一人食厨房", "湖边的狗狗"]
  private static func popularCard(_ index: Int) -> Bilibili_App_Card_V1_Card {
    var card = Bilibili_App_Card_V1_Card()
    var video = Bilibili_App_Card_V1_SmallCoverV5()
    let slot = index % popularTitles.count
    video.base.cardGoto = "av"; video.base.param = String(100 + index)
    video.base.title = popularTitles[slot]; video.base.idx = Int64(index + 1)
    video.base.cover = "https://fixture.invalid/cover/\(slot)"
    video.base.uri = "https://www.bilibili.com/video/av\(100 + index)"
    let seconds = 186 + (index * 437) % 1260
    video.base.playerArgs.cid = Int64(1000 + index); video.base.playerArgs.duration = Int64(seconds)
    video.base.threePointV4.sharePlane.author = popularAuthors[index % popularAuthors.count]
    video.base.threePointV4.sharePlane.authorID = 10001 + Int64(index % popularAuthors.count)
    video.base.threePointV4.sharePlane.playNumber = "\(Double(38 + (index * 53) % 460) / 10)万次"
    video.up.avatar.cover = "https://fixture.invalid/avatar/\(index % 8)"
    video.coverRightText1 = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    video.rightDesc2 = "UP 主 · \([3, 8, 12, 20, 1, 6][index % 6])小时前"
    video.rcmdReasonStyle.text = index % 3 == 0 ? "很多人点赞" : ""
    card.smallCoverV5 = video
    return card
  }
  private static func historyItem() -> Bilibili_App_Interfaces_V1_CursorItem {
    var item = Bilibili_App_Interfaces_V1_CursorItem()
    item.kid = 789; item.oid = 789; item.title = "Fixture history video"; item.business = "archive"
    item.uri = "https://www.bilibili.com/video/av789"; item.viewAt = 1_700_000_000
    item.cardUgc.cid = 456; item.cardUgc.duration = 90; item.cardUgc.progress = 30
    item.cardUgc.mid = 123; item.cardUgc.name = "Fixture owner"
    return item
  }
  public func shutdown(grace: Duration) async {}
}
