import Foundation
import XCTest
@testable import ManpingCore

private actor AIStatusTransport: AIHTTPTransport {
  let status: Int
  let body: Data
  init(status: Int, body: String) { self.status = status; self.body = Data(body.utf8) }
  func stream(_ request: URLRequest) async throws -> AIHTTPStream {
    let data = body
    return AIHTTPStream(status: status, chunks: AsyncThrowingStream { $0.yield(data); $0.finish() })
  }
}

final class M8AIProtocolTests: XCTestCase {
  private let secrets = AIProviderSecrets(key: "fixture-key", secret: "fixture-secret")
  private let conversation = AIConversationRequest(system: "系统规则", messages: [.user("<context>…</context>\n\n任务"), .assistant("第一轮回答"), .user("问题：追问")],
    format: .json, budget: AIRequestBudget(contextTokens: 100_000, maxOutputTokens: 3_000, known: true))
  private func body(_ provider: AIProvider, model: String = "fixture-model", configuration: AIProviderConfiguration? = nil,
    conversation: AIConversationRequest? = nil) throws -> [String: Any] {
    let request = try AIChatRequestPlanner.request(provider: provider,
      configuration: configuration ?? AIProviderConfiguration(endpoint: provider.defaultEndpoint ?? "https://fixture.example.invalid"),
      secrets: secrets, model: model, conversation: conversation ?? self.conversation, bearerToken: "fixture-bearer")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
  }

  func testAnthropicUsesTopLevelSystemAndPlannedOutputCap() throws {
    let body = try body(.anthropic, model: "claude-sonnet-5-5")
    XCTAssertEqual(body["system"] as? String, "系统规则")
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
    XCTAssertEqual(messages.last?["content"] as? String, "问题：追问")
    XCTAssertEqual(body["max_tokens"] as? Int, 3_000)
    XCTAssertNil(body["response_format"])
  }

  func testOpenAIFamiliesLeadWithSystemMessageAndUseCapabilityTable() throws {
    let openAI = try body(.openAI, model: "gpt-5")
    let messages = try XCTUnwrap(openAI["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
    XCTAssertEqual(messages.first?["content"] as? String, "系统规则")
    XCTAssertEqual(openAI["max_completion_tokens"] as? Int, 3_000)
    XCTAssertNil(openAI["max_tokens"])
    XCTAssertEqual((openAI["response_format"] as? [String: Any])?["type"] as? String, "json_object")
    let deepSeek = try body(.deepSeek, model: "deepseek-chat")
    XCTAssertEqual(deepSeek["max_tokens"] as? Int, 3_000)
    XCTAssertNotNil(deepSeek["response_format"])
    // Unknown endpoint or model: JSON is asked for in the prompt only.
    XCTAssertNil(try body(.openAI, model: "gpt-5", configuration: AIProviderConfiguration(endpoint: "https://proxy.example.invalid/v1"))["response_format"])
    XCTAssertNil(try body(.deepSeek, model: "deepseek-reasoner")["response_format"])
    XCTAssertNil(try body(.siliconFlow, model: "Qwen/QwQ-32B")["response_format"])
    let azure = try body(.azureOpenAI, configuration: AIProviderConfiguration(endpoint: "https://fixture.example.invalid"))
    XCTAssertEqual((azure["messages"] as? [[String: Any]])?.first?["role"] as? String, "system")
    XCTAssertNil(azure["response_format"])
  }

  func testResponsesUsesInstructionsAndTypedInput() throws {
    let body = try body(.chatGPTPlan, model: "gpt-5", configuration: AIProviderConfiguration())
    XCTAssertEqual(body["instructions"] as? String, "系统规则")
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    XCTAssertEqual(input.map { $0["role"] as? String }, ["user", "assistant", "user"])
    let types = input.compactMap { (($0["content"] as? [[String: Any]])?.first?["type"]) as? String }
    XCTAssertEqual(types, ["input_text", "output_text", "input_text"])
    XCTAssertNil(body["max_output_tokens"]); XCTAssertNil(body["text"])
    XCTAssertEqual(body["store"] as? Bool, false)
  }

  func testGeminiUsesSystemInstructionModelRoleAndJSONMime() throws {
    let body = try body(.gemini, model: "gemini-2.5-flash", configuration: AIProviderConfiguration())
    XCTAssertEqual(((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String, "系统规则")
    let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
    XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model", "user"])
    let generation = try XCTUnwrap(body["generationConfig"] as? [String: Any])
    XCTAssertEqual(generation["maxOutputTokens"] as? Int, 3_000)
    XCTAssertEqual(generation["responseMimeType"] as? String, "application/json")
    XCTAssertNil(body["messages"])
  }

  func testOllamaKeepsSystemRoleAndJSONFormat() throws {
    let body = try body(.ollama, configuration: AIProviderConfiguration(endpoint: "http://localhost:11434"))
    XCTAssertEqual((body["messages"] as? [[String: Any]])?.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
    XCTAssertEqual(body["format"] as? String, "json")
    XCTAssertEqual((body["options"] as? [String: Any])?["num_predict"] as? Int, 3_000)
  }

  func testSingleUserConversationAndByteLimit() throws {
    let request = try AIChatRequestPlanner.request(provider: .openAI, configuration: AIProviderConfiguration(endpoint: AIProvider.openAI.defaultEndpoint),
      secrets: secrets, model: "gpt-5", conversation: AIConversationRequest(system: nil, messages: [.user("单条")]))
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 1)
    XCTAssertNil(body["max_tokens"]); XCTAssertNil(body["max_completion_tokens"]); XCTAssertNil(body["response_format"])
    // The formal conversation limit counts the system prompt and every message together.
    let limit = String(repeating: "x", count: 8_388_608)
    XCTAssertNoThrow(try AIChatRequestPlanner.request(provider: .openAI, configuration: .init(), secrets: secrets,
      model: "gpt-5", conversation: AIConversationRequest(system: nil, messages: [.user(limit)])))
    XCTAssertThrowsError(try AIChatRequestPlanner.request(provider: .openAI, configuration: .init(), secrets: secrets,
      model: "gpt-5", conversation: AIConversationRequest(system: "s", messages: [.user(limit)])))
    // A conversation must end with a user message.
    XCTAssertThrowsError(try AIChatRequestPlanner.request(provider: .openAI, configuration: AIProviderConfiguration(), secrets: secrets,
      model: "gpt-5", conversation: AIConversationRequest(system: nil, messages: [.user("a"), .assistant("b")])))
  }

  func testContextOverflowAndOtherFailuresStayErrors() async throws {
    let client = AIChatClient(transport: AIStatusTransport(status: 400,
      body: #"{"error":{"code":"context_length_exceeded","message":"This model's maximum context length is 8192 tokens"}}"#))
    do {
      for try await _ in client.response(provider: .openAI, configuration: AIProviderConfiguration(), secrets: secrets, model: "gpt-5",
        conversation: conversation) {}
      XCTFail("Expected overflow")
    } catch let failure as AIChatFailure { XCTAssertEqual(failure, .contextTooLong) }
    let other = AIChatClient(transport: AIStatusTransport(status: 400, body: #"{"error":{"message":"bad request"}}"#))
    do {
      for try await _ in other.response(provider: .anthropic, configuration: AIProviderConfiguration(), secrets: secrets, model: "claude-sonnet-5-5",
        conversation: conversation) {}
      XCTFail("Expected HTTP error")
    } catch let failure as AIChatFailure { XCTAssertEqual(failure, .httpStatus(400)) }
    let refusal = AIChatClient(transport: AIStatusTransport(status: 200,
      body: "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}\n\n"))
    do {
      for try await _ in refusal.response(provider: .anthropic, configuration: AIProviderConfiguration(), secrets: secrets, model: "claude-sonnet-5-5",
        conversation: conversation) {}
      XCTFail("Expected refusal")
    } catch let failure as AIChatFailure { XCTAssertEqual(failure, .refused) }
  }
}
