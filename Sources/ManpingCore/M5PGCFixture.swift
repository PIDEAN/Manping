import Foundation

/// Isolated synthetic samples for PGC layout inspection; never a live-request fallback.
public enum M5PGCFixture {
  public static func response(path: String, parameters: [String: String] = [:]) -> Data? {
    let payload: Any; let envelope: String
    switch path {
    case "/pgc/season/episode/community":
      envelope = "data"; payload = ["like": 1, "coin_number": 1, "favorite": 1]
    case "/pgc/app/follow/add", "/pgc/app/follow/del", "/x/v2/view/like", "/x/v2/view/coin/add", "/x/v2/view/like/triple", "/x/v3/fav/resource/batch-deal":
      envelope = "data"; payload = [:] as [String: Int]
    case "/pgc/app/timeline":
      envelope = "result"
      let domestic = parameters["type"] == "3"
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date())
      let days: [[String: Any]] = (-3...3).map { offset in
        let day = calendar.date(byAdding: .day, value: offset, to: today)!
        let stamp = Int64(day.timeIntervalSince1970)
        let episodes: [[String: Any]] = (0..<2).map { index in
          let season = Int64((domestic ? 200 : 100) + (offset + 3) * 2 + index)
          return ["season_id": season, "episode_id": season * 100 + 1,
            "title": "\(domestic ? "山间少年 · 国创" : "星海游记 · 番剧") \(index + 1)",
            "cover": "https://fixture.invalid/cover/\((offset + 3 + index) % 8)",
            "published": offset <= 0 ? 1 : 0, "pub_time": domestic ? "12:00" : "18:00",
            "pub_index": "第 \(offset + 12) 集", "pub_ts": stamp + (domestic ? 43_200 : 64_800)]
        }
        let month = calendar.component(.month, from: day); let number = calendar.component(.day, from: day)
        return ["date_ts": stamp, "date": "\(month)月\(number)日", "is_today": offset == 0 ? 1 : 0, "episodes": episodes]
      }
      payload = ["navigation_title": "更新日历", "current_time_text": "本地合成样本", "data": days]
    case "/pgc/season/index/condition":
      envelope = "data"
      payload = ["order": [["field": "3", "name": "追番数"], ["field": "1", "name": "更新时间"], ["field": "4", "name": "评分"]],
        "filter": [filter("year", "年份", [("-1", "全部"), ("2026", "2026"), ("2025", "2025")]),
                   filter("style_id", "类型", [("-1", "全部"), ("1", "奇幻"), ("2", "日常")]),
                   filter("season_status", "付费", [("-1", "全部"), ("1", "免费"), ("2", "会员")]),
                   filter("is_finish", "状态", [("-1", "全部"), ("1", "已完结"), ("0", "连载")])]]
    case "/pgc/season/index/result":
      envelope = "data"
      let page = max(1, min(3, Int(parameters["page"] ?? "1") ?? 1))
      let type = Int(parameters["index_type"] ?? "1") ?? 1
      let name = [1: "动漫", 2: "电影", 5: "电视剧", 3: "纪录片"][type] ?? "动漫"
      let items: [[String: Any]] = page >= 3 ? [] : (0..<30).map { index in
        let sid = 1000 + type * 100 + (page - 1) * 30 + index
        return ["season_id": sid, "title": "\(name) · 本地剧集 \((page - 1) * 30 + index + 1)",
          "cover": "https://fixture.invalid/cover/\(index % 8)", "badge": index % 3 == 0 ? "会员" : "",
          "index_show": "更新至第 12 集", "subTitle": parameters["year"] == "2026" ? "2026 · 奇幻之旅" : "奇幻之旅",
          "score": "8.5", "first_ep": ["ep_id": sid * 100 + 1]]
      }
      payload = ["list": items, "has_next": page == 1 ? 1 : 0, "num": page, "size": 30, "total": 60]
    case "/pgc/view/v2/app/season":
      envelope = "data"
      let requested = Int64(parameters["season_id"] ?? "") ?? (Int64(parameters["ep_id"] ?? "") ?? 1001) / 100
      let sid = max(1, min(1_000_000, requested))
      payload = detail(seasonID: sid)
    case "/pgc/player/web/playurl":
      envelope = "result"
      let video: [[String: Any]] = [80, 64, 32].map { quality in
        ["id": quality, "codecs": "avc1.640028", "base_url": "https://fixture.invalid/pgc/video/\(quality)",
         "bandwidth": quality * 10000, "width": 1920, "height": 1080]
      }
      payload = ["accept_quality": [80, 64, 32], "accept_description": ["1080P", "720P", "480P"],
        "dash": ["duration": 1244, "video": video,
          "audio": [["id": 30280, "codecs": "mp4a.40.2", "base_url": "https://fixture.invalid/pgc/audio", "bandwidth": 128000]]]]
    default: return nil
    }
    return try? JSONSerialization.data(withJSONObject: ["code": 0, envelope: payload])
  }
  private static func filter(_ field: String, _ title: String, _ choices: [(String, String)]) -> [String: Any] {
    ["field": field, "name": title, "values": choices.map { ["keyword": $0.0, "name": $0.1] }]
  }
  private static func detail(seasonID sid: Int64) -> [String: Any] {
    let episodes: [[String: Any]] = (0..<8).map { index in
      var episode: [String: Any] = ["id": sid * 100 + Int64(index + 1), "aid": 100 + index, "cid": 1000 + index,
        "ep_index": index + 1, "duration": 1_244_000, "long_title": "星海飞驰 \(index + 1)",
        "cover": "https://fixture.invalid/cover/\(index)", "badge": index == 0 ? "" : "会员",
        "subtitle": "星海游记", "report": ["epid": sid * 100 + Int64(index + 1), "season_id": sid, "season_type": 1]]
      episode["stat"] = ["play": 2_780_000 + index * 9000, "likes": 278_000 + index * 9000,
        "coins": 15_000 + index * 4000, "danmakus": 8000 + index * 200, "reply": 1000]
      return episode
    }
    return ["season_id": sid, "title": "星海游记 · 本地 PGC 样本", "type": 1,
      "cover": "https://fixture.invalid/cover/1", "subtitle": "每周更新 · 全 8 集", "alias": "Journey across the stars",
      "evaluate": "这是隔离的 PGC 本地合成样本，用于检查时间线、筛选、分集和原生播放界面。媒体地址不会加载。",
      "rating": ["score": 8.5, "count": 12000], "staff": ["info": "制作：本地样本工作室"], "actor": ["info": "配音：样本角色"],
      "user_status": ["follow": 1, "progress": ["last_ep_id": sid * 100 + 1, "last_time": 152]],
      "stat": ["views": 23_900_000, "likes": 1_880_000, "coins": 288_000, "danmakus": 689_000, "reply": 9000, "favorites": 920_000],
      "modules": [["style": "positive", "data": ["episodes": episodes]],
        ["style": "season", "data": ["seasons": [["season_id": sid, "title": "第一季", "cover": "https://fixture.invalid/cover/1"],
          ["season_id": sid + 1, "title": "第二季", "cover": "https://fixture.invalid/cover/2"]]]]],
      "dialog": ["msg": "本地预览 · 未加载在线媒体"]]
  }
}
