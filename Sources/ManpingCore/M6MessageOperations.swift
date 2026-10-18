import Foundation

extension BiliService {
  /// Explicit user action only. Loading notifications, sessions or history never invokes this.
  public func sendConversationMessage(receiverID: Int64, content: String, expectedIdentity: AuthSnapshot) async throws -> ConversationMessage {
    try checkRESTIdentity(expectedIdentity)
    guard receiverID > 0, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.count <= 500 else {
      throw BiliError.invalidResponse("消息不能为空，且不能超过 500 字")
    }
    guard let sender = expectedIdentity.token?.mid, sender > 0 else { throw AuthFailure.needsLogin }
    let timestamp = Int64(Date().timeIntervalSince1970)
    let json = try JSONSerialization.data(withJSONObject: ["content": content], options: [.sortedKeys])
    let fields = ["msg[msg_type]": "1", "msg[content]": String(decoding: json, as: UTF8.self),
      "msg[sender_uid]": String(sender), "msg[receiver_id]": String(receiverID), "msg[receiver_type]": "1",
      "msg[receiver_device_id]": "1", "msg[timestamp]": String(timestamp), "msg[msg_status]": "0",
      "msg[dev_id]": "0", "msg[new_face_version]": "1"]
    let response = try await messageWebSend(fields: fields, expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    return try ConversationMessage.parse(["msg_key": response["msg_key"] ?? 0,
      "content": response["msg_content"] ?? String(decoding: json, as: UTF8.self),
      "msg_type": 1, "sender_uid": sender, "timestamp": timestamp])
  }
}
