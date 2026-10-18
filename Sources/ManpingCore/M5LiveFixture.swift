import Foundation

// Synthetic layout and protocol samples. Never contact a real room or account.
public enum M5LiveFixture {
  public static func response(path: String, parameters: [String: String] = [:]) -> Data? {
    let page = Int(parameters["page"] ?? "1") ?? 1
    let data: [String: Any]
    switch path {
    case "/xlive/app-interface/v2/index/getAreaList":
      data = ["list": [(1, "娱乐", ["视频聊天", "唱见", "舞见"]), (2, "网游", ["英雄联盟", "绝地求生", "综合游戏"]),
        (3, "手游", ["王者荣耀", "原神", "综合手游"]), (4, "单机游戏", ["动作游戏", "独立游戏", "怀旧游戏"]),
        (5, "电台", ["声音陪伴", "音乐电台", "聊天互动"]), (6, "生活", ["户外", "日常", "萌宠"])]
        .map { id, title, names in
          ["id": id, "name": title, "area_list": names.enumerated().map { offset, name in
            ["id": id * 100 + offset + 1, "name": name, "parent_id": id,
              "pic": "https://fixture.invalid/cover/\(offset)"] as [String: Any]
          }] as [String: Any]
        }]
    case "/xlive/app-interface/v2/second/getList":
      let area = Int(parameters["area_id"] ?? "101") ?? 101
      let start = (page - 1) * 12
      data = ["list": page > 2 ? [] : (start..<start + 12).map { room($0, area: area) },
        "new_tags": parameters["sort_type"] == nil && page == 1 ? [
          ["id": 0, "name": "推荐", "sort_type": ""], ["id": 1, "name": "人气", "sort_type": "online"],
          ["id": 2, "name": "最新", "sort_type": "live_time"]] : [], "count": 24]
    case "/xlive/app-interface/v2/index/feed":
      let start = (page - 1) * 12
      var cards: [[String: Any]] = []
      if page == 1, parameters["login_event"] == "2" {
        cards.append(["card_type": "my_idol_v1", "card_data": ["my_idol_v1": ["list": (0..<3).map { room($0) }]]])
      }
      if page <= 2 {
        cards += (start..<start + 12).map { index in
          var card = room(index)
          card["id"] = card["roomid"]
          card["cover_left_style"] = ["text": ["陪伴的声音", "音乐现场", "游戏实况", "分享日常"][index % 4]]
          card["cover_right_style"] = ["text": index % 2 == 0 ? "1.2万" : "8600"]
          return ["card_type": "small_card_v1", "card_data": ["small_card_v1": card]]
        }
        cards.append(["card_type": "banner_v1", "card_data": [:]])
      }
      data = ["card_list": cards]
    default: return nil
    }
    return try? JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
  }
  private static func room(_ index: Int, area: Int = 101) -> [String: Any] {
    ["roomid": 5000 + index, "uid": 10001 + index,
      "title": ["傍晚音乐会｜一起听首歌", "把今天的小事分享给你", "游戏时间：快乐是第一位", "周末慢生活，边做饭边聊天",
        "一场放松的深夜电台", "从城市街头看看世界", "今天也在练习新曲子", "让我们一起探索新的故事"][index % 8],
      "cover": "https://fixture.invalid/cover/\(index % 8)", "face": "https://fixture.invalid/avatar/\(index % 4)",
      "uname": ["音乐现场", "日常记录", "游戏伙伴", "慢生活频道"][index % 4],
      "online": 8600 + index * 720, "area_v2_id": area,
      "area_v2_name": ["视频聊天", "唱见", "综合游戏", "生活日常"][index % 4]]
  }
}
