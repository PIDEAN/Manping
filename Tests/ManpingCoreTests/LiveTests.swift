import Foundation
import XCTest

@testable import ManpingCore

final class LiveTests: XCTestCase {
  private func playInfo(_ streams: [[String: Any]], status: Int = 1) -> [String: Any] {
    ["room_id": 7734200, "live_status": status, "playurl_info": ["playurl": [
      "g_qn_desc": [["qn": 10000, "desc": "原画"], ["qn": 400, "desc": "蓝光"], ["qn": 250, "desc": "超清"], ["qn": 20000, "desc": "4K"]],
      "stream": streams]]]
  }
  private func stream(_ protocolName: String, _ format: String, _ codecs: [(String, Int, [Int], [String])]) -> [String: Any] {
    ["protocol_name": protocolName, "format": [["format_name": format, "codec": codecs.map { codec in
      ["codec_name": codec.0, "current_qn": codec.1, "accept_qn": codec.2, "base_url": "/live-bvc/1/live_\(codec.0).\(format)?",
       "url_info": codec.3.map { ["host": "https://\($0)", "extra": "expires=1&sign=x"] }] as [String: Any]
    }]]]
  }

  func testParsesStreamsAndBuildsURLsFromHostBaseAndExtra() throws {
    let info = playInfo([
      stream("http_stream", "flv", [("avc", 250, [10000, 400, 250], ["d1--ov-gotcha05.bilivideo.com", "cn-x-mcdn.bilivideo.cn"])]),
      stream("http_hls", "fmp4", [("hevc", 250, [10000, 400, 250], ["d1--ov-gotcha207.bilivideo.com"])]),
    ])
    let playback = try LivePlayback.parse(info)
    XCTAssertEqual(playback.roomID, 7734200)
    XCTAssertEqual(playback.status, .live)
    XCTAssertEqual(playback.streams.count, 2)
    XCTAssertEqual(playback.streams[0].urls.first?.absoluteString,
      "https://d1--ov-gotcha05.bilivideo.com/live-bvc/1/live_avc.flv?expires=1&sign=x")
    XCTAssertEqual(playback.available.map(\.qn), [10000, 400, 250], "4K is described but not offered by this room")
  }

  func testOfflineRoomHasNoStreams() throws {
    let playback = try LivePlayback.parse(["room_id": 1, "live_status": 0, "playurl_info": NSNull()])
    XCTAssertEqual(playback.status, .offline)
    XCTAssertTrue(playback.streams.isEmpty)
    XCTAssertNil(LiveStreamSelector.ranked(playback, preferHEVC: false).first)
  }

  func testSelectorPrefersQualityThenCodecThenFLVAndPutsPeerHostsLast() throws {
    let playback = try LivePlayback.parse(playInfo([
      stream("http_hls", "fmp4", [("avc", 10000, [10000], ["hls.bilivideo.com"]), ("av1", 10000, [10000], ["av1.bilivideo.com"])]),
      stream("http_stream", "flv", [("avc", 10000, [10000], ["cn-x-mcdn.bilivideo.cn", "d1--ov-gotcha05.bilivideo.com"]),
        ("hevc", 10000, [10000], ["hevc.bilivideo.com"])]),
      stream("http_hls", "ts", [("avc", 20000, [20000], ["low.bilivideo.com"])]),
    ]))
    let avc = try XCTUnwrap(LiveStreamSelector.ranked(playback, preferHEVC: false).first)
    XCTAssertEqual(avc.currentQuality, 20000, "a higher delivered quality wins over the format")
    let without4K = LivePlayback(roomID: 1, status: .live, qualities: playback.qualities,
      streams: playback.streams.filter { $0.currentQuality == 10000 })
    let flv = try XCTUnwrap(LiveStreamSelector.ranked(without4K, preferHEVC: false).first)
    XCTAssertEqual([flv.formatName, flv.codecName], ["flv", "avc"])
    XCTAssertEqual(flv.urls.map { $0.host }, ["d1--ov-gotcha05.bilivideo.com", "cn-x-mcdn.bilivideo.cn"], "PCDN lines last")
    let hevc = try XCTUnwrap(LiveStreamSelector.ranked(without4K, preferHEVC: true).first)
    XCTAssertEqual(hevc.codecName, "hevc")
    let mixed = try LivePlayback.parse(playInfo([
      stream("http_stream", "flv", [("hevc", 250, [10000, 400, 250], ["hevc.bilivideo.com"]),
        ("avc", 150, [10000, 400, 250, 150], ["avc.bilivideo.com"])]),
    ]))
    XCTAssertEqual(LiveStreamSelector.ranked(mixed, preferHEVC: true, requested: 150).first?.currentQuality, 150,
      "a requested quality only one codec offers beats the preferred codec")
    XCTAssertEqual(LiveStreamSelector.ranked(mixed, preferHEVC: true, requested: 400).first?.currentQuality, 250,
      "otherwise the closest quality below the request")
    let onlyAV1 = LivePlayback(roomID: 1, status: .live, qualities: [], streams: without4K.streams.filter { $0.codecName == "av1" })
    XCTAssertEqual(LiveStreamSelector.ranked(onlyAV1, preferHEVC: false).first?.codecName, "av1", "AV1 only when nothing else exists")
  }

  func testFastestLineSkipsDeadEdgesAndFallsBackToTheNextFormat() async throws {
    struct Fetcher: CDNRangeFetching {
      let dead: Set<String>
      func fetch(_ url: URL, range: ClosedRange<Int>, timeout: TimeInterval) async -> CDNFetchOutcome {
        if dead.contains(url.host ?? "") {
          try? await Task.sleep(nanoseconds: 300_000_000)
          return CDNFetchOutcome(status: 0, data: Data(), ttfbMs: 300, durationMs: 300, totalLength: nil, contentType: nil, error: "超时")
        }
        return CDNFetchOutcome(status: 200, data: Data(count: 10), ttfbMs: 5, durationMs: 5, totalLength: nil, contentType: "video/x-flv", error: nil)
      }
    }
    func line(_ format: String, _ hosts: [String]) -> LiveStream {
      LiveStream(protocolName: "http_stream", formatName: format, codecName: "avc", currentQuality: 10000,
        acceptedQualities: [10000], urls: hosts.map { URL(string: "https://\($0)/live.\(format)")! })
    }
    let flv = line("flv", ["dead-a.bilivideo.com", "live-b.bilivideo.com"])
    let hls = line("fmp4", ["live-c.bilivideo.com"])
    let picked = await LiveStreamSelector.fastestLine([flv, hls][...], fetcher: Fetcher(dead: ["dead-a.bilivideo.com"]))
    XCTAssertEqual(picked?.0.formatName, "flv")
    XCTAssertEqual(picked?.1, 1, "the edge that answers wins over the dead first line")
    let fallback = await LiveStreamSelector.fastestLine([flv, hls][...],
      fetcher: Fetcher(dead: ["dead-a.bilivideo.com", "live-b.bilivideo.com"]))
    XCTAssertEqual(fallback?.0.formatName, "fmp4", "every FLV line dead → the next format")
    let none = await LiveStreamSelector.fastestLine([flv][...], fetcher: Fetcher(dead: ["dead-a.bilivideo.com", "live-b.bilivideo.com"]))
    XCTAssertNil(none)
  }

  // MARK: Chat protocol

  func testAuthorizationPacketLayout() throws {
    let packet = LiveChatPacket.authorization(LiveChatEndpoint(urls: [], token: "tok", roomID: 7734200, uid: 0, buvid: "b3"))
    XCTAssertEqual(Array(packet.prefix(4)), Self.bigEndian(UInt32(packet.count)))
    XCTAssertEqual(Array(packet[4..<6]), [0, 16])
    XCTAssertEqual(Array(packet[8..<12]), [0, 0, 0, 7])
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: packet.dropFirst(16)) as? [String: Any])
    XCTAssertEqual(body["roomid"] as? Int, 7734200)
    XCTAssertEqual(body["key"] as? String, "tok")
    XCTAssertEqual(body["protover"] as? Int, 2)
  }

  func testDecodesCompressedMessagesAndControlPackets() throws {
    let danmaku: [String: Any] = ["cmd": "DANMU_MSG", "info": [[0, 1, 25, 16_772_431], "好耶", [42, "观众甲"]]]
    let ended: [String: Any] = ["cmd": "PREPARING", "roomid": "7734200"]
    let watched: [String: Any] = ["cmd": "WATCHED_CHANGE", "data": ["num": 12345]]
    let inner = try [danmaku, ended, watched].map {
      LiveChatPacket.encode(.message, body: try JSONSerialization.data(withJSONObject: $0), version: 0)
    }.reduce(Data(), +)
    let compressed = LiveChatPacket.encode(.message, body: try Self.zlib(inner), version: 2)
    var reply = Data(Self.bigEndian(UInt32(888)))
    reply = LiveChatPacket.encode(.heartbeatReply, body: reply, version: 1)
    let auth = LiveChatPacket.encode(.authReply, body: Data(#"{"code":0}"#.utf8))
    let events = LiveChatPacket.decode(auth + compressed + reply).events
    XCTAssertEqual(events, [
      .connected,
      .danmaku(user: "观众甲", text: "好耶", color: 16_772_431),
      .liveEnded,
      .watched(12345),
      .popularity(888),
    ])
  }

  func testTruncatedFramesAreIgnored() {
    let packet = LiveChatPacket.encode(.message, body: Data(#"{"cmd":"LIVE"}"#.utf8))
    XCTAssertEqual(LiveChatPacket.decode(packet).events, [.liveStarted])
    XCTAssertTrue(LiveChatPacket.decode(packet.prefix(20)).events.isEmpty)
    XCTAssertTrue(LiveChatPacket.decode(Data([0, 0, 0, 5])).events.isEmpty)
  }

  func testCommandSuffixesAndGiftsParse() {
    XCTAssertEqual(LiveChatPacket.event(["cmd": "DANMU_MSG:4:0:2:2:2:0", "info": [[0, 1, 25, 0], "hi", [1, "u"]]]),
      .danmaku(user: "u", text: "hi", color: 0xffffff))
    XCTAssertEqual(LiveChatPacket.event(["cmd": "SEND_GIFT", "data": ["uname": "u", "giftName": "小心心", "num": 3]]),
      .gift(user: "u", name: "小心心", count: 3))
    XCTAssertEqual(LiveChatPacket.event(["cmd": "ONLINE_RANK_COUNT", "data": ["count": 6281, "online_count": 6290]]), .online(6290))
    XCTAssertNil(LiveChatPacket.event(["cmd": "UNKNOWN"]))
  }

  // MARK: Live danmaku timeline

  func testTimelineAppendsInOrderAndStaysBounded() {
    var timeline = DanmakuTimeline(comments: [], lanes: 4, duration: 8)
    XCTAssertTrue(timeline.append(DanmakuComment(time: 10, text: "a")))
    XCTAssertFalse(timeline.append(DanmakuComment(time: 5, text: "late")), "out-of-order lines are dropped")
    XCTAssertEqual(timeline.visible(at: 12).map(\.comment.text), ["a"])
    for index in 0..<4_000 { timeline.append(DanmakuComment(time: 20 + Double(index) * 3, text: "\(index)")) }
    XCTAssertLessThanOrEqual(timeline.count, 1_501)
    XCTAssertFalse(timeline.visible(at: 20 + 3_999 * 3 + 1).isEmpty)
  }

  func testTimelineStaysBoundedWhileTheClockStandsStill() {
    // A paused live stream: chat keeps arriving at the same media time.
    var timeline = DanmakuTimeline(comments: [], lanes: 4, duration: 8)
    for index in 0..<5_000 { timeline.append(DanmakuComment(time: 42, text: "\(index)")) }
    XCTAssertLessThanOrEqual(timeline.count, 1_500)
    timeline.setSpeed(0.5)
    XCTAssertLessThanOrEqual(timeline.count, 1_500)
    XCTAssertFalse(timeline.visible(at: 43).isEmpty)
  }

  // MARK: Helpers

  private static func bigEndian(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian) { Array($0) } }

  /// RFC 1950 wrapper around Foundation's raw deflate.
  private static func zlib(_ data: Data) throws -> Data {
    let deflated = try (data as NSData).compressed(using: .zlib) as Data
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    return Data([0x78, 0x9c]) + deflated + Data(bigEndian((b << 16) | a))
  }

  func testRejectedChatAuthIsNotAConnection() {
    let accepted = LiveChatPacket.encode(.authReply, body: Data(#"{"code":0}"#.utf8))
    XCTAssertEqual(LiveChatPacket.decode(accepted).events, [.connected])
    XCTAssertFalse(LiveChatPacket.decode(accepted).authRejected)
    for body in [#"{"code":-101}"#, #"{"code":"1"}"#, "not json", "{}"] {
      let reply = LiveChatPacket.encode(.authReply, body: Data(body.utf8))
      let decoded = LiveChatPacket.decode(reply)
      XCTAssertEqual(decoded.events, [], body)
      XCTAssertTrue(decoded.authRejected, body)
    }
    let heartbeat = LiveChatPacket.encode(.heartbeatReply, body: Data([0, 0, 0, 7]))
    XCTAssertFalse(LiveChatPacket.decode(heartbeat).authRejected)
  }
}
