import BiliProtocol
import Foundation
import SwiftProtobuf

/// Synthetic samples pass through the production binary packet/protobuf decode chain.
public enum LiveChatFixture {
  public static func presentationFrame() throws -> Data {
    var result = try frame()
    for command: [String: Any] in [
      ["cmd": "WATCHED_CHANGE", "data": ["num": 186_000]],
      ["cmd": "ONLINE_RANK_COUNT", "data": ["online_count": 23_000]],
      ["cmd": "LIKE_INFO_V3_UPDATE", "data": ["click_count": 42_000]],
    ] {
      result += LiveChatPacket.encode(
        .message, body: try JSONSerialization.data(withJSONObject: command))
    }
    for index in 0..<9 {
      var meta: [Any] = Array(repeating: 0, count: 16)
      meta[1] = 1
      meta[3] = 16_777_215
      if index == 5 {
        meta[13] = ["url": "https://fixture.invalid/emote/heart", "width": 180, "height": 120]
      }
      var extra: [String: Any] = ["id_str": "fixture-dm-\(index)"]
      if index == 2 {
        extra["reply_uname"] = "阿青"
        extra["reply_mid"] = 900002
        extra["replay_dmid"] = "fixture-dm-1"
      }
      if index == 3 { extra["emots"] = ["[开心]": ["url": "https://fixture.invalid/emote/smile"]] }
      meta[15] = [
        "extra": String(decoding: try JSONSerialization.data(withJSONObject: extra), as: UTF8.self)
      ]
      let medal: [Any] = [
        9, "山野电台", "山野记录", 5000, 4_091_864, "", 0, 6_065_632, 4_091_864, 7_049_192,
        index == 1 ? 3 : 0, index == 4 ? 0 : 1, 900010,
      ]
      let message: [String: Any] = [
        "cmd": "DANMU_MSG",
        "info": [
          meta,
          [
            "晚上好呀", "贡嘎那张太美了", "我也想去", "太开心了[开心]", "带着勋章来啦", "[大表情]", "这个画面好美", "晚风和山野",
            "希望每天都有好心情",
          ][index],
          [
            index == 0 ? 900001 : 900002 + index,
            index == 0 ? "示例账号" : ["阿青", "小林", "北岸"][index % 3],
          ], medal,
        ],
      ]
      result += LiveChatPacket.encode(
        .message, body: try JSONSerialization.data(withJSONObject: message))
    }
    return result
  }
  public static func frame(includeDeletion: Bool = false) throws -> Data {
    var first = Bilibili_Live_Gift_V1_GiftItem()
    first.giftID = 100
    first.giftName = "示例礼物"
    first.num = 2
    first.price = 100
    first.totalCoin = 200
    first.coinType = "gold"
    first.tid = "fixture-gift-1"
    var second = first
    second.giftID = 101
    second.giftName = "示例星星"
    second.num = 1
    second.tid = "fixture-gift-2"
    var broadcast = Bilibili_Live_Gift_V1_SendGiftBroadcast()
    broadcast.uid = 900002
    broadcast.uname = "示例观众"
    broadcast.giftList = [first, second]
    var commands: [[String: Any]] = [
      ["cmd": "DANMU_MSG", "info": [[0, 1, 25, 16_777_215], "示例弹幕", [900002, "示例观众"]]],
      [
        "cmd": "SEND_GIFT_V2", "data": ["pb": try broadcast.serializedData().base64EncodedString()],
      ],
      [
        "cmd": "GUARD_BUY",
        "data": ["uid": 900003, "username": "示例舰长", "guard_level": 3, "num": 1],
      ],
      [
        "cmd": "SUPER_CHAT_MESSAGE",
        "data": [
          "id": "fixture-sc", "uid": 900004, "price": 30, "message": "示例醒目留言", "start_time": 100,
          "end_time": 160, "user_info": ["uname": "示例留言者"],
        ],
      ],
    ]
    if includeDeletion {
      commands.append(["cmd": "SUPER_CHAT_MESSAGE_DELETE", "data": ["ids": ["fixture-sc"]]])
    }
    return try commands.reduce(Data()) { result, command in
      result
        + LiveChatPacket.encode(.message, body: try JSONSerialization.data(withJSONObject: command))
    }
  }
}
