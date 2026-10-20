import Darwin
import Foundation
import XCTest
@testable import ManpingCore

private actor AIChatFixtureTransport: AIHTTPTransport {
  private var responses: [(Int, Data)]
  private(set) var requests: [URLRequest] = []
  init(_ responses: [(Int, Data)]) { self.responses = responses }
  func stream(_ request: URLRequest) async throws -> AIHTTPStream {
    requests.append(request)
    guard !responses.isEmpty else { throw AIChatFailure.invalidResponse }
    let (status, data) = responses.removeFirst()
    return AIHTTPStream(status: status, chunks: AsyncThrowingStream { continuation in
      // Network boundaries deliberately split each UTF-8 scalar and protocol token.
      for byte in data { continuation.yield(Data([byte])) }
      continuation.finish()
    })
  }
}
private final class AICancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var cancelled: Bool { lock.withLock { value } }
  func mark() { lock.withLock { value = true } }
}
private struct AIHangingTransport: AIHTTPTransport {
  let probe: AICancellationProbe
  func stream(_ request: URLRequest) async throws -> AIHTTPStream {
    let chunks = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n".utf8))
      continuation.onTermination = { _ in probe.mark() }
    }
    return AIHTTPStream(status: 200, chunks: chunks, cancel: { probe.mark() })
  }
}

final class M8AIChatTests: XCTestCase {
  private let secrets = AIProviderSecrets(key: "fixture-key", secret: "fixture-secret", codestralKey: "fixture-codestral")
  private static let openAIStream = Data("data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\ndata: [DONE]\n\n".utf8)
  private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
    var result = ""
    for try await chunk in stream { result += chunk }
    return result
  }
  func testAllRegisteredProvidersBuildOneUserPromptWithoutSending() throws {
    XCTAssertEqual(AIProvider.sourceProviders.count, 29)
    for provider in AIProvider.sourceProviders {
      let configuration = AIProviderConfiguration(endpoint: provider.defaultEndpoint ?? "https://fixture.example.invalid")
      let request = try AIChatRequestPlanner.request(provider: provider, configuration: configuration,
        secrets: secrets, model: "fixture-model", conversation: AIConversationRequest(system: nil, messages: [.user("标题与字幕 fixture")]), bearerToken: "fixture-bearer")
      XCTAssertEqual(request.httpMethod, "POST")
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
      if provider == .gemini {
        XCTAssertEqual((body["contents"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(body["messages"])
      } else {
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
      }
      XCTAssertNil(body["system"])
    }
  }
  func testAzureFamiliesHaveDistinctRouteVersionAndAuthentication() throws {
    let configuration = AIProviderConfiguration(endpoint: "https://fixture.example.invalid", apiVersion: "fixture-version")
    let openAI = try AIChatRequestPlanner.request(provider: .azureOpenAI, configuration: configuration, secrets: secrets,
      model: "deploy name", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")]))
    let inference = try AIChatRequestPlanner.request(provider: .azureAI, configuration: configuration, secrets: secrets,
      model: "fixture-model", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")]))
    XCTAssertEqual(openAI.url?.path, "/openai/deployments/deploy name/chat/completions")
    XCTAssertEqual(inference.url?.path, "/chat/completions")
    XCTAssertEqual(inference.value(forHTTPHeaderField: "api-key"), "fixture-key")
    XCTAssertNil(inference.value(forHTTPHeaderField: "Authorization"))
    XCTAssertTrue(inference.url?.absoluteString.contains("api-version=fixture-version") == true)
  }
  func testGeminiAndAnthropicHaveNativeBodiesAndKeyHeaders() throws {
    let gemini = try AIChatRequestPlanner.request(provider: .gemini, configuration: .init(), secrets: secrets,
      model: "gemini-fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")]), options: .init(maxTokens: 128))
    XCTAssertEqual(gemini.url?.path, "/v1beta/models/gemini-fixture:streamGenerateContent")
    XCTAssertFalse(gemini.url!.absoluteString.contains("fixture-key"))
    XCTAssertEqual(gemini.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
    let anthropic = try AIChatRequestPlanner.request(provider: .anthropic, configuration: .init(), secrets: secrets,
      model: "claude-fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")]))
    XCTAssertEqual(anthropic.url?.path, "/v1/messages")
    XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(anthropic.httpBody)) as? [String: Any])
    XCTAssertEqual(body["max_tokens"] as? Int, 16_000)
    // Unknown/older model IDs keep the plain body: no thinking, effort or fallback fields.
    XCTAssertNil(body["thinking"]); XCTAssertNil(body["output_config"]); XCTAssertNil(body["fallbacks"])
  }
  func testCodestralUsesSeparateKeyAndEndpoint() throws {
    let request = try AIChatRequestPlanner.request(provider: .mistral, configuration: .init(useCodestral: true),
      secrets: secrets, model: "codestral-fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")]))
    XCTAssertEqual(request.url?.host, "codestral.mistral.ai")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-codestral")
    XCTAssertThrowsError(try AIChatRequestPlanner.request(provider: .mistral, configuration: .init(useCodestral: true),
      secrets: .init(key: "fixture-key"), model: "fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
  }
  func testEndpointAndHeaderInjectionAreRejectedBeforeTransport() throws {
    for endpoint in ["http://remote.example.invalid", "https://key:secret@example.invalid", "https://example.invalid?key=value"] {
      XCTAssertThrowsError(try AIChatRequestPlanner.request(provider: .openAI, configuration: .init(endpoint: endpoint),
        secrets: secrets, model: "fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
    }
    XCTAssertThrowsError(try AIChatRequestPlanner.request(provider: .openAI, configuration: .init(),
      secrets: .init(key: "fixture\r\nAuthorization: injected"), model: "fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
  }
  func testSSEMultilineCRLFAndSplitUTF8() throws {
    var parser = AIStreamParser(family: .openAI)
    let payload = ": ping\r\ndata: {\r\ndata: \"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n"
    var output = ""
    for byte in payload.utf8 { output += try parser.append(Data([byte])).joined() }
    output += try parser.finish().joined()
    XCTAssertEqual(output, "你好")
  }
  func testNativeStreamingFamilies() throws {
    let samples: [(AIProtocolFamily, String)] = [
      (.anthropic, "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"native\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"),
      (.gemini, "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"native\"}]},\"finishReason\":\"STOP\"}]}\n\n"),
      (.ollama, "{\"message\":{\"content\":\"native\"},\"done\":false}\n{\"message\":{\"content\":\"\"},\"done\":true}"),
    ]
    for (family, sample) in samples {
      var parser = AIStreamParser(family: family)
      var output = try parser.append(Data(sample.utf8)).joined()
      output += try parser.finish().joined()
      XCTAssertEqual(output, "native")
    }
  }
  func testMissingTerminatorEmptyErrorAndLimitAreNotSuccess() throws {
    var truncated = AIStreamParser(family: .openAI)
    _ = try truncated.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".utf8))
    XCTAssertThrowsError(try truncated.finish()) { XCTAssertEqual($0 as? AIChatFailure, .truncatedStream) }
    var empty = AIStreamParser(family: .openAI)
    _ = try empty.append(Data("data: [DONE]\n\n".utf8))
    XCTAssertThrowsError(try empty.finish()) { XCTAssertEqual($0 as? AIChatFailure, .emptyResponse) }
    var malformed = AIStreamParser(family: .anthropic)
    XCTAssertThrowsError(try malformed.append(Data("event: error\ndata: {\"error\":\"fixture-secret\"}\n\n".utf8)))
    var limited = AIStreamParser(family: .openAI)
    XCTAssertThrowsError(try limited.append(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n".utf8))) {
      XCTAssertEqual($0 as? AIChatFailure, .outputLimit)
    }
  }
  func testCompleteResponseAllFamilies() throws {
    for (family, sample) in [
      (AIProtocolFamily.openAI, "{\"choices\":[{\"message\":{\"content\":\"complete\"},\"finish_reason\":\"stop\"}]}"),
      (.anthropic, "{\"content\":[{\"type\":\"text\",\"text\":\"complete\"}],\"stop_reason\":\"end_turn\"}"),
      (.gemini, "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"complete\"}]},\"finishReason\":\"STOP\"}]}"),
      (.ollama, "{\"message\":{\"content\":\"complete\"},\"done\":true}"),
    ] { XCTAssertEqual(try AIStreamParser.complete(Data(sample.utf8), family: family), "complete") }
  }
  func testClientInjectedTransportEmitsIncrementalText() async throws {
    let transport = AIChatFixtureTransport([(200, Self.openAIStream)])
    let client = AIChatClient(transport: transport)
    let text = try await Self.collect(client.response(provider: .openAI, configuration: .init(), secrets: secrets, model: "fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
    XCTAssertEqual(text, "你好")
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
  }
  func testErnieUsesBCEAuthorizationThenBearerNotAccessKey() async throws {
    let transport = AIChatFixtureTransport([(200, Data("{\"token\":\"fixture-bearer\"}".utf8)), (200, Self.openAIStream)])
    let client = AIChatClient(transport: transport)
    let text = try await Self.collect(client.response(provider: .ernie, configuration: .init(), secrets: secrets,
      model: "fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
    XCTAssertEqual(text, "你好")
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].httpMethod, "GET")
    XCTAssertEqual(requests[0].url?.path, "/v1/BCE-BEARER/token")
    XCTAssertTrue(requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("bce-auth-v1/fixture-key/") == true)
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-bearer")
    let signature = try AIChatRequestPlanner.ernieAuthorization(accessKey: "fixture-key", secret: "fixture-secret", date: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(signature, "bce-auth-v1/fixture-key/1970-01-01T00:00:00Z/3600/host/59acd7d295edf7188c4c80887dffb911c9f75cfae074780a7ea67b07996ca741")
    XCTAssertFalse(signature.contains("fixture-secret"))
  }
  func testErnieRejectsInvalidConfigurationAndRemoteIAMOverrideBeforeSending() async throws {
    let transport = AIChatFixtureTransport([])
    let client = AIChatClient(transport: transport)
    do {
      _ = try await Self.collect(client.response(provider: .ernie, configuration: .init(), secrets: secrets,
        model: "", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
      XCTFail("Invalid model reached IAM")
    } catch { XCTAssertEqual(error as? AIChatFailure, .missingConfiguration) }
    let override = AIChatClient(transport: transport,
      ernieAuthorizationEndpoint: URL(string: "https://untrusted.example.invalid/token")!)
    do {
      _ = try await Self.collect(override.response(provider: .ernie, configuration: .init(), secrets: secrets,
        model: "fixture-model", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
      XCTFail("Credentials reached a remote IAM override")
    } catch { XCTAssertEqual(error as? AIChatFailure, .invalidEndpoint) }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testHTTPFailuresAreClassifiedWithoutEchoingServerOrCredentials() async throws {
    for (status, expected) in [(401, AIChatFailure.unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .httpStatus(500))] {
      let client = AIChatClient(transport: AIChatFixtureTransport([(status, Data("fixture-key server detail".utf8))]))
      do {
        _ = try await Self.collect(client.response(provider: .openAI, configuration: .init(), secrets: secrets, model: "fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
        XCTFail("HTTP failure accepted")
      } catch {
        XCTAssertEqual(error as? AIChatFailure, expected)
        XCTAssertFalse(error.localizedDescription.contains("fixture-key"))
      }
    }
  }
  func testCancellationStopsUnderlyingStream() async throws {
    let probe = AICancellationProbe()
    let client = AIChatClient(transport: AIHangingTransport(probe: probe))
    let credentials = secrets
    let task = Task {
      try await Self.collect(client.response(provider: .openAI, configuration: .init(), secrets: credentials, model: "fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
    }
    try await Task.sleep(for: .milliseconds(30))
    task.cancel()
    _ = await task.result
    for _ in 0..<100 where !probe.cancelled { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(probe.cancelled)
  }
  func testLocalHTTPServerStreamsAllIndependentFamiliesAndRejectsRedirect() async throws {
    let server = try AIChatHTTPFixture(); defer { server.stop() }
    let client = AIChatClient()
    for (provider, path) in [(AIProvider.openAI, "openai"), (.azureOpenAI, "azure"), (.azureAI, "inference"),
      (.anthropic, "anthropic"), (.gemini, "gemini"), (.ollama, "ollama")] {
      let configuration = AIProviderConfiguration(endpoint: server.endpoint(path))
      let text = try await Self.collect(client.response(provider: provider, configuration: configuration, secrets: secrets,
        model: "fixture-model", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
      XCTAssertEqual(text, "你好")
    }
    do {
      _ = try await Self.collect(client.response(provider: .openAI, configuration: .init(endpoint: server.endpoint("redirect")),
        secrets: secrets, model: "fixture", conversation: AIConversationRequest(system: nil, messages: [.user("fixture")])))
      XCTFail("Redirect followed")
    } catch { XCTAssertEqual(error as? AIChatFailure, .httpStatus(302)) }
    let records = try server.requests()
    XCTAssertFalse(records.contains { ($0["path"] as? String)?.contains("redirect-target") == true })
    for record in records {
      let headers = record["headers"] as? [String: String] ?? [:]
      XCTAssertNil(headers["Cookie"])
    }
  }
}

private final class AIChatHTTPFixture: @unchecked Sendable {
  private let process: Process
  private let latch = DispatchSemaphore(value: 0)
  private let folder: URL
  private let port: Int
  init() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("BiliAIHTTP-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [root.appendingPathComponent("scripts/fixtures/ai_mock_server.py").path, folder.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    let latch = self.latch; process.terminationHandler = { _ in latch.signal() }
    try process.run()
    let deadline = Date().addingTimeInterval(3)
    var publishedPort: Int?
    while Date() < deadline {
      if let text = try? String(contentsOf: folder.appendingPathComponent("port"), encoding: .utf8),
        let candidate = Int(text), (1...65535).contains(candidate) {
        publishedPort = candidate; break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    guard let port = publishedPort else {
      Self.terminate(process, latch: latch); try? FileManager.default.removeItem(at: folder)
      throw AIChatFailure.invalidResponse
    }
    self.port = port
  }
  func endpoint(_ path: String) -> String { "http://127.0.0.1:\(port)/\(path)" }
  func requests() throws -> [[String: Any]] {
    let text = try String(contentsOf: folder.appendingPathComponent("requests.jsonl"), encoding: .utf8)
    return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:] }
  }
  func stop() { Self.terminate(process, latch: latch); try? FileManager.default.removeItem(at: folder) }
  private static func terminate(_ process: Process, latch: DispatchSemaphore) {
    if process.isRunning { process.terminate() }
    if latch.wait(timeout: .now() + 1) == .timedOut {
      if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
      _ = latch.wait(timeout: .now() + 1)
    }
  }
}
