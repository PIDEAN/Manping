import Foundation

/// Synthetic notifications and conversations; no copied account data or live fallback.
public enum M6MessageFixture {
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var feed = ["reply": 3, "at": 1, "like": 12]
    var acknowledgements: [Int: Int] = [:]
    var dustbin = 4
  }
  private static let state = State()
  public static func reset() {
    state.lock.withLock {
      state.feed = ["reply": 3, "at": 1, "like": 12]; state.acknowledgements = [:]; state.dustbin = 4
    }
  }
  public static func configurePresentation(_ presentation: String) {
    guard ProcessInfo.processInfo.arguments.contains("--ui-fixture") else { return }
    state.lock.withLock {
      guard presentation == "running" || presentation == "partial" else { return }
      state.feed = ["reply": 0, "at": 0, "like": 0]
      for index in 0..<8 {
        let id = 60001 + index
        state.acknowledgements[id] = 1000 + id
      }
      // Keep a genuine residual count in the synthetic endpoint responses.
      if presentation == "running" { state.acknowledgements[60001] = 61001 - 5 }
      else {
        state.acknowledgements[60001] = 61001 - 1
        state.acknowledgements[60002] = 61002 - 1
      }
    }
  }
  public static func response(path: String, parameters: [String: String] = [:]) -> Data? {
    state.lock.withLock { responseLocked(path: path, parameters: parameters) }
  }
  private static func responseLocked(path: String, parameters: [String: String]) -> Data? {
    let payload: Any
    switch path {
    case "/x/msgfeed/reply", "/x/msgfeed/at", "/x/msgfeed/like":
      let kind = path.components(separatedBy: "/").last!
      if parameters["id"] == "0" || parameters["id"] == nil { state.feed[kind] = 0 }
      let more = parameters["id"] == "0" || parameters["id"] == nil
      let base = more ? 20 : 10
      let rows: [[String: Any]] = (0..<8).map { index in
        let user: [String: Any] = ["mid": 50001 + index, "nickname": "本地读者 \(index + 1)", "avatar": "https://fixture.invalid/avatar/\(index % 8)"]
        return ["id": base + index, "\(kind)_time": 1_790_000_000 - index * 3_600,
          "user": user, "users": [user], "counts": index + 1,
          "item": ["type": "reply", "business": "评论", "business_id": 1,
            "source_content": kind == "at" ? "@本地样本 一起来看看这段精彩内容。" : "这一段讲得很清楚，期待下一次更新！",
            "title": "星海游记 · 新的一天", "desc": "本地样本评论", "uri": "https://www.bilibili.com/video/BV1xx411c7mD"]]
      }
      let cursor: [String: Any] = ["is_end": !more, "id": base, "time": 1_789_000_000]
      payload = kind == "like" ? ["lastest": ["items": Array(rows.prefix(2))], "total": ["items": rows, "cursor": cursor]]
        : ["items": rows, "cursor": cursor]
    case "/session_svr/v1/session_svr/get_sessions":
      let more = parameters["end_ts"] == "0" || parameters["end_ts"] == nil
      let rows: [[String: Any]] = (0..<4).map { index in
        let id = 60001 + index + (more ? 0 : 4)
        return ["talker_id": id, "session_type": 1, "system_msg_type": 0, "session_ts": 1_790_000_000_000_000 - id,
          "max_seqno": 1000 + id, "ack_seqno": state.acknowledgements[id] ?? (1000 + id - (id <= 60005 ? 1 : 0)),
          "unread_count": max(0, 1000 + id - (state.acknowledgements[id] ?? (1000 + id - (id <= 60005 ? 1 : 0)))), "last_msg": chat(key: id, sender: id, content: "你好！这是用于界面验收的本地消息。", time: 1_790_000_000 - index * 60)]
      }
      payload = ["session_list": rows, "has_more": more ? 1 : 0]
    case "/account/v1/user/cards":
      payload = (parameters["uids"] ?? "").split(separator: ",").enumerated().map { index, id -> [String: Any] in
        ["mid": Int64(id) ?? 0, "name": "私信样本 \(index + 1)", "face": "https://fixture.invalid/avatar/\(index % 8)"]
      }
    case "/svr_sync/v1/svr_sync/fetch_session_msgs":
      let older = parameters["begin_seqno"] != nil
      let talker = Int64(parameters["talker_id"] ?? "60001") ?? 60001
      let rows = (0..<8).map { index in
        chat(key: (older ? 10 : 20) + index, sender: index % 3 == 0 ? 123 : Int(talker),
          content: index % 3 == 0 ? "收到，谢谢分享！" : "这是一条本地合成的消息，可以加载更早记录。",
          time: 1_790_000_000 - (older ? 1_000 : 0) + index * 60)
      }
      payload = ["messages": rows.reversed().map { $0 }, "has_more": older ? 0 : 1,
        "min_seqno": older ? 1 : 100, "max_seqno": older ? 99 : 200]
    case "/x/msgfeed/unread":
      payload = state.feed
    case "/session_svr/v1/session_svr/single_unread":
      let count = (0..<8).reduce(0) { sum, index in
        let id = 60001 + index
        return sum + max(0, 1000 + id - (state.acknowledgements[id] ?? (1000 + id - (id <= 60005 ? 1 : 0))))
      }
      payload = ["follow_unread": count, "unfollow_unread": 0,
        "dustbin_unread": parameters["show_dustbin"] == "1" ? state.dustbin : 0]
    case "/session_svr/v1/session_svr/update_ack":
      if let id = parameters["talker_id"].flatMap(Int.init), let sequence = parameters["ack_seqno"].flatMap(Int.init) {
        state.acknowledgements[id] = max(state.acknowledgements[id] ?? 0, min(sequence, 1000 + id))
      }
      payload = [:] as [String: Int]
    case "/session_svr/v1/session_svr/batch_update_dustbin_ack":
      state.dustbin = 0; payload = [:] as [String: Int]
    case "/web_im/v1/web_im/send_msg":
      payload = ["msg_key": 90001, "msg_content": parameters["msg[content]"] ?? "{}"]
    default: return nil
    }
    return try? JSONSerialization.data(withJSONObject: ["code": 0, "data": payload], options: [.sortedKeys])
  }
  private static func chat(key: Int, sender: Int, content: String, time: Int) -> [String: Any] {
    let data = try! JSONSerialization.data(withJSONObject: ["content": content])
    return ["msg_key": key, "sender_uid": sender, "receiver_id": 123, "timestamp": time,
      "msg_type": 1, "content": String(decoding: data, as: UTF8.self)]
  }
}
