import Foundation
import ManpingCore

struct Measurement: Encodable {
  let name: String
  let samplesMS: [Double]
  let medianMS: Double
  let p95MS: Double
  let checksum: Int
}

let repeats = Int(CommandLine.arguments.dropFirst().first ?? "7") ?? 7
var results: [Measurement] = []

@MainActor func measure(_ name: String, _ body: () throws -> Int) rethrows {
  let expected = try body() // warm-up, outside timed samples
  var samples: [Double] = []
  for _ in 0..<repeats {
    let start = DispatchTime.now().uptimeNanoseconds
    let checksum = try body()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    precondition(checksum == expected, "Non-deterministic benchmark output")
    samples.append(elapsed)
  }
  let sorted = samples.sorted()
  results.append(Measurement(name: name, samplesMS: samples, medianMS: sorted[sorted.count / 2],
    p95MS: sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)], checksum: expected))
}

func chunks(_ data: Data, size: Int) -> [Data] {
  stride(from: 0, to: data.count, by: size).map { Data(data[$0..<min($0 + size, data.count)]) }
}

func parse(_ chunks: [Data], expectedBytes: Int) throws -> Int {
  var parser = AIStreamParser(family: .openAI)
  var count = 0
  for chunk in chunks { count += try parser.append(chunk).reduce(0) { $0 + $1.utf8.count } }
  count += try parser.finish().reduce(0) { $0 + $1.utf8.count }
  precondition(count == expectedBytes)
  return count
}

let text = String(repeating: "x", count: 131_072)
let longStream = Data(("data: {\"choices\":[{\"delta\":{\"content\":\"" + text + "\"}}]}\n\ndata: [DONE]\n\n").utf8)
let longChunks = chunks(longStream, size: 128)
try measure("sse_128k_line_128b_chunks") { try parse(longChunks, expectedBytes: text.utf8.count) }

let delta = "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n"
let batched = Data((String(repeating: delta, count: 4_000) + "data: [DONE]\n\n").utf8)
try measure("sse_4000_events_one_chunk") { try parse([batched], expectedBytes: 24_000) }
let normalChunks = chunks(batched, size: 128)
try measure("sse_4000_events_128b_chunks") { try parse(normalChunks, expectedBytes: 24_000) }

let multiline = [Data("data: {\n".utf8)] + Array(repeating: Data("data: \n".utf8), count: 4_096)
  + [Data("data: \"choices\":[{\"delta\":{\"content\":\"fixture\"}}]}\n\ndata: [DONE]\n\n".utf8)]
try measure("sse_4096_data_lines") { try parse(multiline, expectedBytes: 7) }

let cues = (0..<5_000).map { index in
  DownloadSubtitleCue(start: Double(index) * 3, end: Double(index) * 3 + 2,
    text: "  第\(index)段字幕：这是一个用来测量清理性能的离线样例，包含中文、English 和标点。\n")
}
measure("transcript_5000_cues") {
  let transcript = AITranscript.clean(cues, language: "zh-CN", isAI: false)
  precondition(transcript.cues.count == 5_000)
  return transcript.cues.reduce(0) { $0 + $1.text.utf8.count }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(results), as: UTF8.self))
