import Foundation

// Live room playback and chat. Request parameters follow BiliKernel 22fdf8ca (GPL-3.0):
// `PlayerClient.GetLivePlayDetailAsync` (web-room v2 getRoomPlayInfo) and the live chat socket.

public enum LiveStatus: Int, Sendable, Equatable {
  case offline = 0, live = 1, round = 2
  public var title: String {
    switch self {
    case .offline: "未开播"
    case .live: "直播中"
    case .round: "轮播中"
    }
  }
}

public struct LiveRoomInfo: Sendable, Equatable {
  public let roomID: Int64
  public let shortID: Int64
  public let anchorID: Int64
  public var anchorName: String
  public var anchorAvatar: URL?
  public let status: LiveStatus
  public let title: String
  public let cover: URL?
  public let area: String
  public let online: Int64
  public let description: String
  public let startedAt: Date?
  public var webURL: URL { URL(string: "https://live.bilibili.com/\(roomID)")! }
  public init(roomID: Int64, shortID: Int64 = 0, anchorID: Int64, anchorName: String = "", anchorAvatar: URL? = nil,
    status: LiveStatus, title: String, cover: URL? = nil, area: String = "", online: Int64 = 0, description: String = "",
    startedAt: Date? = nil) {
    self.roomID = roomID; self.shortID = shortID; self.anchorID = anchorID; self.anchorName = anchorName
    self.anchorAvatar = anchorAvatar; self.status = status; self.title = title; self.cover = cover; self.area = area
    self.online = online; self.description = description; self.startedAt = startedAt
  }
}

public struct LiveQuality: Sendable, Equatable, Identifiable {
  public var id: Int { qn }
  public let qn: Int
  public let title: String
  public init(qn: Int, title: String) { self.qn = qn; self.title = title }
}

/// One protocol/format/codec combination of a live stream and its CDN lines.
public struct LiveStream: Sendable, Equatable {
  public let protocolName: String
  public let formatName: String
  public let codecName: String
  public let currentQuality: Int
  public let acceptedQualities: [Int]
  public let urls: [URL]
  public init(protocolName: String, formatName: String, codecName: String, currentQuality: Int,
    acceptedQualities: [Int], urls: [URL]) {
    self.protocolName = protocolName; self.formatName = formatName; self.codecName = codecName
    self.currentQuality = currentQuality; self.acceptedQualities = acceptedQualities; self.urls = urls
  }
  public var label: String { "\(formatName.uppercased()) · \(codecName.uppercased())" }
}

public struct LivePlayback: Sendable, Equatable {
  public let roomID: Int64
  public let status: LiveStatus
  public let qualities: [LiveQuality]
  public let streams: [LiveStream]
  public init(roomID: Int64, status: LiveStatus, qualities: [LiveQuality], streams: [LiveStream]) {
    self.roomID = roomID; self.status = status; self.qualities = qualities; self.streams = streams
  }

  /// Qualities this room actually offers (the union of every stream's accepted list).
  public var available: [LiveQuality] {
    let accepted = Set(streams.flatMap(\.acceptedQualities))
    return qualities.filter { accepted.contains($0.qn) }.sorted { $0.qn > $1.qn }
  }

  /// Parses the `data` object of `xlive/web-room/v2/index/getRoomPlayInfo`.
  public static func parse(_ data: [String: Any]) throws -> LivePlayback {
    guard let room = JSONValue.int64(data["room_id"]), room > 0 else {
      throw BiliError.invalidResponse("Missing live room id")
    }
    let status = LiveStatus(rawValue: liveInt(data["live_status"]) ?? 0) ?? .offline
    guard let info = data["playurl_info"] as? [String: Any], let playurl = info["playurl"] as? [String: Any] else {
      return LivePlayback(roomID: room, status: status, qualities: [], streams: [])
    }
    let qualities = (playurl["g_qn_desc"] as? [[String: Any]] ?? []).compactMap { item -> LiveQuality? in
      guard let qn = liveInt(item["qn"]), let title = item["desc"] as? String else { return nil }
      return LiveQuality(qn: qn, title: title)
    }
    var streams: [LiveStream] = []
    for stream in playurl["stream"] as? [[String: Any]] ?? [] {
      let protocolName = stream["protocol_name"] as? String ?? ""
      for format in stream["format"] as? [[String: Any]] ?? [] {
        let formatName = format["format_name"] as? String ?? ""
        for codec in format["codec"] as? [[String: Any]] ?? [] {
          guard let base = codec["base_url"] as? String else { continue }
          let urls = (codec["url_info"] as? [[String: Any]] ?? []).compactMap { line -> URL? in
            guard let host = line["host"] as? String, host.hasPrefix("https://") || host.hasPrefix("http://") else { return nil }
            return URL(string: host + base + (line["extra"] as? String ?? ""))
          }
          guard !urls.isEmpty else { continue }
          streams.append(LiveStream(protocolName: protocolName, formatName: formatName,
            codecName: codec["codec_name"] as? String ?? "", currentQuality: liveInt(codec["current_qn"]) ?? 0,
            acceptedQualities: (codec["accept_qn"] as? [Any] ?? []).compactMap { liveInt($0) }, urls: urls))
        }
      }
    }
    return LivePlayback(roomID: room, status: status, qualities: qualities, streams: streams)
  }
}

public enum LiveStreamSelector {
  /// Peer-assisted (PCDN) hosts carry `mcdn` in their name; they are tried last.
  public static func isPeerAssisted(_ url: URL) -> Bool { url.host?.contains("mcdn") ?? false }

  /// The requested quality (or the closest one below it, then above it) first; then the
  /// preferred hardware codec (AV1 last, it decodes in software on most Macs); then FLV (lowest
  /// latency), fMP4 HLS, TS HLS. Without a request the highest delivered quality wins.
  public static func select(_ playback: LivePlayback, preferHEVC: Bool, requested: Int? = nil,
    avoidPeerAssisted: Bool = true) -> LiveStream? {
    ranked(playback, preferHEVC: preferHEVC, requested: requested, avoidPeerAssisted: avoidPeerAssisted).first
  }

  /// Races a small read on every line of the given streams at once and returns the
  /// best-ranked line that answers with media. A live CDN hostname resolves to several edges
  /// and one of them may be dead; mpv would wait on it for its full connect timeout, while
  /// URLSession moves to the next address at once. After the first answer, slightly slower
  /// answers from a preferred format (FLV first) still win within `grace` seconds.
  public static func fastestLine(_ streams: ArraySlice<LiveStream>, fetcher: CDNRangeFetching,
    timeout: TimeInterval = 4, grace: TimeInterval = 0.4) async -> (LiveStream, Int)? {
    let streams = Array(streams)
    enum Result: Sendable { case line(stream: Int, line: Int, ok: Bool), deadline }
    return await withTaskGroup(of: Result.self) { group in
      var pending = 0
      for (streamIndex, stream) in streams.enumerated() {
        for (lineIndex, url) in stream.urls.enumerated() {
          pending += 1
          group.addTask { .line(stream: streamIndex, line: lineIndex, ok: await fetcher.fetch(url, range: 0...32_767, timeout: timeout).ok) }
        }
      }
      var best: (stream: Int, line: Int)?
      var waiting = false
      while pending > 0, let result = await group.next() {
        switch result {
        case .deadline:
          group.cancelAll()
          pending = 0
        case .line(let streamIndex, let lineIndex, let ok):
          pending -= 1
          guard ok else { continue }
          if best == nil || (streamIndex, lineIndex) < (best!.stream, best!.line) { best = (streamIndex, lineIndex) }
          if best!.stream == 0 && best!.line == 0 { group.cancelAll(); pending = 0; break }
          if !waiting {
            waiting = true
            group.addTask {
              try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
              return .deadline
            }
          }
        }
      }
      group.cancelAll()
      return best.map { (streams[$0.stream], $0.line) }
    }
  }

  /// Every stream in preference order, each with its peer-assisted lines moved last.
  public static func ranked(_ playback: LivePlayback, preferHEVC: Bool, requested: Int? = nil,
    avoidPeerAssisted: Bool = true) -> [LiveStream] {
    func distance(_ quality: Int) -> Int {
      guard let requested else { return -quality }
      return quality <= requested ? requested - quality : quality - requested + 1_000_000
    }
    func codecRank(_ name: String) -> Int {
      switch name {
      case "hevc": preferHEVC ? 0 : 1
      case "avc": preferHEVC ? 1 : 0
      default: 2
      }
    }
    func formatRank(_ stream: LiveStream) -> Int {
      switch (stream.protocolName, stream.formatName) {
      case ("http_stream", "flv"): 0
      case ("http_hls", "fmp4"): 1
      case ("http_hls", "ts"): 2
      default: 3
      }
    }
    let ranked = playback.streams.sorted {
      ($0.codecName == "av1" ? 1 : 0, distance($0.currentQuality), codecRank($0.codecName), formatRank($0))
        < ($1.codecName == "av1" ? 1 : 0, distance($1.currentQuality), codecRank($1.codecName), formatRank($1))
    }
    guard avoidPeerAssisted else { return ranked }
    return ranked.map { stream in
      LiveStream(protocolName: stream.protocolName, formatName: stream.formatName, codecName: stream.codecName,
        currentQuality: stream.currentQuality, acceptedQualities: stream.acceptedQualities,
        urls: stream.urls.filter { !isPeerAssisted($0) } + stream.urls.filter(isPeerAssisted))
    }
  }
}

private func liveInt(_ value: Any?) -> Int? { JSONValue.int64(value).map { Int($0) } }
private func liveIdentifier(_ value: Int64) throws {
  guard value > 0 else { throw BiliError.invalidResponse("直播间编号无效") }
}

// MARK: Chat

public enum LiveChatEvent: Sendable, Equatable {
  case connected
  case danmaku(user: String, text: String, color: UInt32)
  case superChat(user: String, text: String, price: Int)
  case gift(user: String, name: String, count: Int)
  /// 「xx 人看过」.
  case watched(Int64)
  /// Viewers online now (online rank count).
  case online(Int64)
  /// Heartbeat reply value (popularity).
  case popularity(Int64)
  case liveStarted
  case liveEnded
  case titleChanged(String)
}

public struct LiveChatEndpoint: Sendable, Equatable {
  public let urls: [URL]
  public let token: String
  public let roomID: Int64
  public let uid: Int64
  public let buvid: String
  public init(urls: [URL], token: String, roomID: Int64, uid: Int64, buvid: String) {
    self.urls = urls; self.token = token; self.roomID = roomID; self.uid = uid; self.buvid = buvid
  }
}

/// Live chat wire format: a 16-byte big-endian header (total length, header length 16,
/// protocol version, operation, sequence) followed by the body. Version 2 bodies are zlib
/// streams that contain further packets.
public enum LiveChatPacket {
  public enum Operation: UInt32 { case heartbeat = 2, heartbeatReply = 3, message = 5, auth = 7, authReply = 8 }

  public static func encode(_ operation: Operation, body: Data, version: UInt16 = 1) -> Data {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    append(UInt32(16 + body.count)); append(UInt16(16)); append(version); append(operation.rawValue); append(UInt32(1))
    data.append(body)
    return data
  }

  public static func authorization(_ endpoint: LiveChatEndpoint) -> Data {
    let body: [String: Any] = ["uid": endpoint.uid, "roomid": endpoint.roomID, "protover": 2, "buvid": endpoint.buvid,
      "platform": "web", "type": 2, "key": endpoint.token]
    return encode(.auth, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
  }

  public static let heartbeat = encode(.heartbeat, body: Data("[object Object]".utf8))

  /// Splits a frame into packets, inflating compressed bodies.
  public static func packets(_ frame: Data, depth: Int = 0) -> [(operation: UInt32, body: Data)] {
    var result: [(UInt32, Data)] = []
    var offset = frame.startIndex
    func read32(_ at: Int) -> UInt32 { frame[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    func read16(_ at: Int) -> UInt16 { frame[at..<at + 2].reduce(0) { $0 << 8 | UInt16($1) } }
    while frame.endIndex - offset >= 16 {
      let total = Int(read32(offset)), header = Int(read16(offset + 4))
      guard total >= header, header >= 16, offset + total <= frame.endIndex else { break }
      let version = read16(offset + 6), operation = read32(offset + 8)
      let body = frame.subdata(in: (offset + header)..<(offset + total))
      if version == 2, depth < 2, let inflated = inflate(body) {
        result += packets(inflated, depth: depth + 1)
      } else {
        result.append((operation, body))
      }
      offset += total
    }
    return result
  }

  /// zlib (RFC 1950) → raw deflate for Foundation's decompressor.
  static func inflate(_ data: Data) -> Data? {
    guard data.count > 6 else { return nil }
    return try? (data.subdata(in: (data.startIndex + 2)..<(data.endIndex - 4)) as NSData).decompressed(using: .zlib) as Data
  }

  public static func events(_ frame: Data) -> [LiveChatEvent] { decode(frame).events }

  /// Events in a frame, and whether it carried an auth reply that was not `{"code":0}`. A
  /// rejected (or unreadable) auth reply is not a connection: the client closes the socket so the
  /// caller counts a failure and reconnects with a fresh token.
  public static func decode(_ frame: Data) -> (events: [LiveChatEvent], authRejected: Bool) {
    var rejected = false
    let events = packets(frame).compactMap { packet -> LiveChatEvent? in
      switch Operation(rawValue: packet.operation) {
      case .authReply:
        guard authAccepted(packet.body) else { rejected = true; return nil }
        return .connected
      case .heartbeatReply:
        guard packet.body.count >= 4 else { return nil }
        return .popularity(Int64(packet.body.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }))
      case .message:
        guard let json = try? JSONSerialization.jsonObject(with: packet.body) as? [String: Any] else { return nil }
        return event(json)
      default: return nil
      }
    }
    return (events, rejected)
  }

  static func authAccepted(_ body: Data) -> Bool {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
    return JSONValue.int64(json["code"]) == 0
  }

  static func event(_ json: [String: Any]) -> LiveChatEvent? {
    let command = (json["cmd"] as? String ?? "").split(separator: ":").first.map(String.init) ?? ""
    let data = json["data"] as? [String: Any] ?? [:]
    switch command {
    case "DANMU_MSG":
      guard let info = json["info"] as? [Any], info.count > 2, let text = info[1] as? String,
        let user = info[2] as? [Any], user.count > 1 else { return nil }
      let meta = info[0] as? [Any] ?? []
      let color = meta.count > 3 ? UInt32(truncatingIfNeeded: JSONValue.int64(meta[3]) ?? 0xffffff) : 0xffffff
      return .danmaku(user: user[1] as? String ?? "", text: text, color: color == 0 ? 0xffffff : color)
    case "SUPER_CHAT_MESSAGE":
      let user = (data["user_info"] as? [String: Any])?["uname"] as? String ?? ""
      return .superChat(user: user, text: data["message"] as? String ?? "", price: liveInt(data["price"]) ?? 0)
    case "SEND_GIFT":
      return .gift(user: data["uname"] as? String ?? "", name: data["giftName"] as? String ?? "",
        count: liveInt(data["num"]) ?? 1)
    case "WATCHED_CHANGE":
      return JSONValue.int64(data["num"]).map { .watched($0) }
    case "ONLINE_RANK_COUNT":
      return (JSONValue.int64(data["online_count"]) ?? JSONValue.int64(data["count"])).map { .online($0) }
    case "LIVE": return .liveStarted
    case "PREPARING": return .liveEnded
    case "ROOM_CHANGE":
      return (data["title"] as? String).map { .titleChanged($0) }
    default: return nil
    }
  }
}

extension BiliService {
  private static let liveBase = "https://api.live.bilibili.com"

  /// Resolves a short or real room id and loads the room and anchor.
  public func liveRoom(_ id: Int64) async throws -> LiveRoomInfo {
    try liveIdentifier(id)
    let initial = try await json(Self.liveBase + "/room/v1/Room/room_init", params: ["id": String(id)])
    guard let room = JSONValue.int64(initial["room_id"]), room > 0 else { throw BiliError.invalidResponse("直播间不存在") }
    let info = try await json(Self.liveBase + "/room/v1/Room/get_info", params: ["room_id": String(room)])
    let anchorID = JSONValue.int64(info["uid"]) ?? JSONValue.int64(initial["uid"]) ?? 0
    let started = (info["live_time"] as? String).flatMap { value -> Date? in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
      formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
      return formatter.date(from: value)
    }
    let description = (info["description"] as? String ?? "")
      .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    var result = LiveRoomInfo(roomID: room, shortID: JSONValue.int64(initial["short_id"]) ?? 0, anchorID: anchorID,
      status: LiveStatus(rawValue: liveInt(info["live_status"]) ?? 0) ?? .offline,
      title: info["title"] as? String ?? "直播间", cover: (info["user_cover"] as? String).flatMap(Self.secureURL),
      area: [info["parent_area_name"] as? String, info["area_name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
      online: JSONValue.int64(info["online"]) ?? 0, description: description, startedAt: started)
    if anchorID > 0, let master = try? await json(Self.liveBase + "/live_user/v1/Master/info", params: ["uid": String(anchorID)]),
      let anchor = master["info"] as? [String: Any] {
      result.anchorName = anchor["uname"] as? String ?? ""
      result.anchorAvatar = (anchor["face"] as? String).flatMap(Self.secureURL)
    }
    return result
  }

  public func livePlayback(roomID: Int64, quality: Int = 10000) async throws -> LivePlayback {
    try liveIdentifier(roomID)
    var params = ["room_id": String(roomID), "no_playurl": "0", "qn": String(quality), "codec": "0,1,2", "dolby": "5",
      "format": "0,1,2", "only_audio": "0", "protocol": "0,1", "mask": "1", "panorama": "1"]
    if let csrf = cookieValue("bili_jct") { params["csrf"] = csrf }
    return try LivePlayback.parse(try await json(Self.liveBase + "/xlive/web-room/v2/index/getRoomPlayInfo", params: params))
  }

  public func liveChatEndpoint(roomID: Int64) async throws -> LiveChatEndpoint {
    try liveIdentifier(roomID)
    let info = try await json(Self.liveBase + "/xlive/web-room/v1/index/getDanmuInfo",
      params: ["id": String(roomID), "type": "0", "web_location": "444.8"], signed: true)
    guard let token = info["token"] as? String, !token.isEmpty else { throw BiliError.invalidResponse("Missing chat token") }
    let urls = (info["host_list"] as? [[String: Any]] ?? []).compactMap { host -> URL? in
      guard let name = host["host"] as? String, let port = liveInt(host["wss_port"]) else { return nil }
      return URL(string: "wss://\(name):\(port)/sub")
    }
    let uid = authSnapshot().token?.mid ?? cookieValue("DedeUserID").flatMap { Int64($0) } ?? 0
    return LiveChatEndpoint(urls: urls.isEmpty ? [URL(string: "wss://broadcastlv.chat.bilibili.com/sub")!] : urls,
      token: token, roomID: roomID, uid: uid, buvid: cookieValue("buvid3") ?? "")
  }

  private static func secureURL(_ value: String) -> URL? {
    guard !value.isEmpty else { return nil }
    return URL(string: value.hasPrefix("http://") ? "https://" + value.dropFirst(7) : value)
  }
}
