import Foundation
import XCTest
@testable import ManpingCore

private actor AIListingFixture: AIHTTPTransport {
  var pages: [AIHTTPStream]
  private(set) var requests: [URLRequest] = []
  init(_ bodies: [(Int, String)]) {
    pages = bodies.map { status, body in AIHTTPStream(status: status, chunks: AsyncThrowingStream { continuation in
      continuation.yield(Data(body.utf8)); continuation.finish()
    }) }
  }
  func stream(_ request: URLRequest) async throws -> AIHTTPStream {
    requests.append(request)
    guard !pages.isEmpty else { throw AIModelListingFailure.network }
    return pages.removeFirst()
  }
}

final class M8AIProviderDiscoveryTests: XCTestCase {
  let secrets = AIProviderSecrets(key: "fixture-key")
  func testPublicCatalogueFixturesAndMetadata() throws {
    // Reduced anonymous GET responses, 2026-10-20. Sources: the three URLs below.
    // https://openrouter.ai/api/v1/models
    let router = Data(#"{"data":[{"id":"minimax/minimax-m3.1-flash:free","context_length":1000000,"top_provider":{"max_completion_tokens":524288},"supported_parameters":["max_tokens","reasoning","tools"]}]}"#.utf8)
    let result = try AIModelListing.parse(router, provider: .openRouter).models
    XCTAssertEqual(result.first?.contextTokens, 1_000_000); XCTAssertEqual(result.first?.maxOutputTokens, 524_288)
    XCTAssertEqual(result.first?.toolSupport, true)
    // https://opencode.ai/inference/v1/models
    let zen = Data(#"{"data":[{"id":"gpt-6-astra","object":"model","owned_by":"openai"}]}"#.utf8)
    XCTAssertEqual(try AIModelListing.parse(zen, provider: .opencodeZen).models.first?.id, "gpt-6-astra")
    // https://coding.dashscope.aliyuncs.com/v1/models (parsing fixture only; no subscription integration).
    let coding = Data(#"{"object":"list","data":[{"id":"kimi-k2.5","object":"model","ownedBy":"system"},{"id":"qwen3.7-plus","object":"model","ownedBy":"system"}],"hasMore":false}"#.utf8)
    XCTAssertEqual(try AIModelListing.parse(coding, provider: .qwen).models.map(\.id), ["kimi-k2.5", "qwen3.7-plus"])
  }
  func testNativeListingFamiliesAndCapabilities() throws {
    let claude = Data(#"{"data":[{"id":"claude-fable-5-1","max_input_tokens":1000000,"max_tokens":128000,"capabilities":{"image_input":{"supported":true},"thinking":{"supported":true}}},{"id":"old","lifecycle":"retired"}],"has_more":true,"last_id":"cursor"}"#.utf8)
    let a = try AIModelListing.parse(claude, provider: .anthropic)
    XCTAssertEqual(a.next, "cursor"); XCTAssertEqual(a.models.count, 1)
    XCTAssertEqual(a.models.first?.visionSupport, true); XCTAssertEqual(a.models.first?.capabilities, ["image_input", "thinking"])
    let gemini = Data(#"{"models":[{"name":"models/gemini-3.8-flash","inputTokenLimit":1048576,"outputTokenLimit":65536,"supportedGenerationMethods":["generateContent"]},{"name":"models/embedding","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"next"}"#.utf8)
    let g = try AIModelListing.parse(gemini, provider: .gemini)
    XCTAssertEqual(g.models.map(\.id), ["gemini-3.8-flash"]); XCTAssertEqual(g.next, "next")
    XCTAssertEqual(g.models.first?.maxOutputTokens, 65_536)
    XCTAssertEqual(try AIModelListing.parse(Data(#"{"models":[{"name":"local:latest"}]}"#.utf8), provider: .ollama).models.first?.id, "local:latest")
    XCTAssertNil(try AIModelListing.parse(Data(#"{"data":[{"id":"x","max_tokens":true,"max_input_tokens":0}]}"#.utf8), provider: .anthropic).models.first?.maxOutputTokens)
  }
  func testDiscoveryRequestsAreGETAndPublicCataloguesNeverSendKeys() throws {
    for provider in AIProvider.sourceProviders where ![.azureAI, .ernie].contains(provider) {
      let config = AIProviderConfiguration(endpoint: provider.defaultEndpoint ?? "https://fixture.invalid")
      let request = try AIModelListing.request(provider: provider, configuration: config, secrets: secrets)
      XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
      if provider == .azureOpenAI {
        XCTAssertEqual(request.url?.path, "/openai/models")
        XCTAssertTrue(request.url?.query?.contains("api-version=2024-10-21") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "fixture-key")
      }
      if [.opencodeZen, .opencodeGo, .openRouter].contains(provider) { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) }
      if provider == .opencodeGo {
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Manping/") == true)
        XCTAssertNotNil(UUID(uuidString: request.value(forHTTPHeaderField: "x-opencode-session") ?? ""))
      }
    }
    XCTAssertThrowsError(try AIModelListing.request(provider: .openAI, configuration: .init(endpoint: "http://remote.invalid"), secrets: secrets))
    XCTAssertThrowsError(try AIModelListing.request(provider: .openAI, configuration: .init(), secrets: .init(key: "x\r\nInjected: true")))
  }
  func testDiscoveryPaginationLoopAndAuthorizationClassification() async throws {
    let page = #"{"data":[{"id":"fixture"}],"has_more":true,"last_id":"same"}"#
    let transport = AIListingFixture([(200, page), (200, page)])
    do { _ = try await AIModelListing(transport: transport).models(provider: .anthropic, configuration: .init(), secrets: secrets); XCTFail("loop accepted") }
    catch { XCTAssertEqual(error as? AIModelListingFailure, .invalidFormat) }
    let requests = await transport.requests
    XCTAssertTrue(requests.last?.url?.absoluteString.contains("after_id=same") == true)
    do { _ = try await AIModelListing(transport: AIListingFixture([(401, "secret body")])).models(provider: .openAI, configuration: .init(), secrets: secrets); XCTFail("401 accepted") }
    catch { XCTAssertEqual(error as? AIModelListingFailure, .unauthorized); XCTAssertFalse(error.localizedDescription.contains("secret body")) }
  }
  func testDiscoveryLimitsAndLegacyConfigurationMerge() throws {
    let rows = (0..<1002).map { ["id": "m\($0)"] }
    let data = try JSONSerialization.data(withJSONObject: ["data": rows])
    XCTAssertEqual(try AIModelListing.parse(data, provider: .openAI).models.count, 1000)
    XCTAssertThrowsError(try AIModelListing.parse(Data(repeating: 32, count: 16_777_217), provider: .openAI))
    var config = try XCTUnwrap(AIConfigurationStore.decodePublicConfiguration(Data(#"{"openai":{"models":[{"id":"gpt-5","mac_max_output_tokens":777}]}}"#.utf8))[.openAI])
    XCTAssertEqual(config.fetchedModels, []); XCTAssertNil(config.modelsFetchedAt)
    config.fetchedModelsEndpoint = AIProvider.openAI.defaultEndpoint
    config.fetchedModels = [AIModel(id: "gpt-5", name: "Discovered", contextTokens: 123_456, maxOutputTokens: 888)]
    let model = try XCTUnwrap(config.availableModels(for: .openAI).first(where: { $0.id == "gpt-5" }))
    XCTAssertEqual(model.contextTokens, 123_456); XCTAssertEqual(model.maxOutputTokens, 777)
    config.endpoint = "https://other.invalid/v1"
    XCTAssertEqual(config.availableModels(for: .openAI).first(where: { $0.id == "gpt-5" })?.contextTokens, 400_000)
  }
  func testFetchedModelsPersistWithoutChangingCredentialsOrDestination() async throws {
    let store = AIConfigurationStore.fixture(configurations: [.openAI: .init()], secrets: [.openAI: secrets])
    let before = try await store.discoverySecrets(for: .openAI)
    try await store.saveFetchedModels(provider: .openAI, models: [AIModel(id: "remote", name: "Remote", contextTokens: 55_000)], endpoint: AIProvider.openAI.defaultEndpoint!)
    let after = try await store.discoverySecrets(for: .openAI)
    XCTAssertEqual(before, after)
    let snapshot = try await store.snapshot(for: .openAI)
    XCTAssertEqual(snapshot.configuration.fetchedModels.first?.contextTokens, 55_000)
    do { try await store.saveFetchedModels(provider: .openAI, models: [], endpoint: "https://other.invalid"); XCTFail("destination changed") }
    catch { XCTAssertEqual(error as? AIConfigurationError, .credentialsChanged) }
  }
  func testOpenCodeExactProviderRoutingAndProtocolRequests() throws {
    XCTAssertEqual(AIOpenCodeRouting.family(provider: .opencodeZen, model: "qwen3.8-max"), .openAI)
    XCTAssertEqual(AIOpenCodeRouting.family(provider: .opencodeGo, model: "qwen3.8-max"), .anthropic)
    XCTAssertEqual(AIOpenCodeRouting.family(provider: .opencodeZen, model: "gpt-unknown"), .openAI)
    for (model, path) in [("gpt-6-astra", "/openai/v1/responses"), ("claude-fable-5-1", "/anthropic/v1/messages"), ("gemini-4-argon", "/google/v1beta/models/gemini-4-argon:streamGenerateContent"), ("minimax-m3", "/openai/v1/chat/completions")] {
      let request = try AIChatRequestPlanner.request(provider: .opencodeZen, configuration: .init(), secrets: secrets, model: model,
        conversation: AIConversationRequest(system: "system", messages: [.user("hello")]), options: .init(maxTokens: 1234))
      XCTAssertEqual(request.url?.path, "/inference" + path)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
      XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key")); XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
      if model.hasPrefix("claude") { XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 1); XCTAssertEqual(body["system"] as? String, "system") }
      if model.hasPrefix("gpt") { XCTAssertEqual(body["max_output_tokens"] as? Int, 1234); XCTAssertNil(body["max_tokens"]) }
    }
  }
  func testReasoningContentNeverEntersAnswersAndResponsesComplete() throws {
    var parser = AIStreamParser(family: .openAI)
    let result = try parser.append(Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hidden\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}\n\ndata: [DONE]\n\n".utf8))
    XCTAssertEqual(result.joined(), "answer")
    let complete = Data(#"{"status":"completed","output":[{"type":"reasoning","text":"hidden"},{"type":"message","content":[{"type":"output_text","text":"answer"}]}]}"#.utf8)
    XCTAssertEqual(try AIStreamParser.complete(complete, family: .responses), "answer")
  }
  func testDocumentedEffortAndRegionalEndpoints() throws {
    for provider in [AIProvider.moonshot, .qwen, .zhiPu, .minimax, .minimaxPlan, .mimoTokenPlan] {
      XCTAssertFalse(provider.regions.isEmpty)
      for region in provider.regions { XCTAssertNoThrow(try AIChatRequestPlanner.endpoint(region.endpoint)) }
    }
    for (provider, model) in [(AIProvider.minimaxPlan, "MiniMax-M3.1-Flash"), (.moonshot, "kimi-k3"), (.zhiPu, "glm-5.3")] {
      let request = try AIChatRequestPlanner.request(provider: provider, configuration: .init(), secrets: secrets, model: model,
        conversation: .init(system: nil, messages: [.user("hello")]), options: .init(temperature: 0.2, effort: "low"))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
      XCTAssertEqual(body["reasoning_effort"] as? String, "low")
      XCTAssertNotEqual((body["thinking"] as? [String: String])?["type"], "disabled")
      if provider == .moonshot { XCTAssertNil(body["temperature"]) }
    }
  }
  func testOpenCodeClientUsesModelSpecificStreamParser() async throws {
    let data = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"answer\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    let transport = AIListingFixture([(200, data)])
    var text = ""
    for try await chunk in AIChatClient(transport: transport).response(provider: .opencodeGo, configuration: .init(), secrets: secrets,
      model: "qwen3.8-max", conversation: .init(system: nil, messages: [.user("hello")])) { text += chunk }
    XCTAssertEqual(text, "answer")
    let requests = await transport.requests
    XCTAssertEqual(requests.first?.url?.path, "/inference/go/anthropic/v1/messages")
  }
  func testDiscoveryRejectsTamperedCredentialBindingIncludingOptionalLocalKey() async throws {
    for provider in [AIProvider.openAI, .lmStudio] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryBinding-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let file = directory.appendingPathComponent("config.json")
      let credentials = AIMemorySecretStore()
      let store = AIConfigurationStore(fileURL: file, credentials: credentials)
      try await store.save(provider: provider, configuration: .init(), secrets: secrets)
      var config = try AIConfigurationStore.decodePublicConfiguration(Data(contentsOf: file))
      config[provider]?.endpoint = "https://other.invalid/v1"
      try AIConfigurationStore.encodePublicConfiguration(config).write(to: file)
      let restarted = AIConfigurationStore(fileURL: file, credentials: credentials)
      do { _ = try await restarted.discoverySecrets(for: provider); XCTFail("tampered destination accepted") }
      catch { XCTAssertEqual(error as? AIConfigurationError, .credentialsChanged) }
    }
  }
  func testGenericResponsesNeverReportChatGPTPlanFailures() throws {
    var parser = AIStreamParser(family: .responses, planUsage: false)
    XCTAssertThrowsError(try parser.append(Data("data: {\"type\":\"error\",\"code\":\"subscription_sharing_invalid_user\"}\n\n".utf8))) {
      XCTAssertEqual($0 as? AIChatFailure, .providerError)
    }
  }
  func testDocumentedThinkingWhitelistNeverDisablesUnknownModels() throws {
    for (provider, model, expected) in [(AIProvider.qwen, "qwen3.8-max", false as Bool?), (.qwen, "qwen3.8-flash", false),
      (.qwen, "qwen3.7-plus", false), (.qwen, "qwen3.6-plus", false), (.qwen, "qwen3.5-plus", false),
      (.siliconFlow, "Qwen/Qwen3.6-35B-A3B", false), (.qwen, "qwen3.8-plus", nil),
      (.qwen, "qwen3.8-2.4t-a95b", nil), (.siliconFlow, "Qwen/Qwen3-32B", nil)] {
      let request = try AIChatRequestPlanner.request(provider: provider, configuration: .init(), secrets: secrets, model: model,
        conversation: .init(system: nil, messages: [.user("hello")]), options: .init(effort: "low"))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
      XCTAssertEqual(body["enable_thinking"] as? Bool, expected, model)
    }
  }
  func testUnsupportedCredentialDiscoveryDoesNotSendRequests() async throws {
    for (provider, config) in [(AIProvider.ernie, AIProviderConfiguration()), (.mistral, AIProviderConfiguration(useCodestral: true))] {
      let transport = AIListingFixture([])
      do { _ = try await AIModelListing(transport: transport).models(provider: provider, configuration: config, secrets: secrets); XCTFail("unsupported discovery accepted") }
      catch { XCTAssertEqual(error as? AIModelListingFailure, .unsupported) }
      let requests = await transport.requests
      XCTAssertTrue(requests.isEmpty)
    }
    let request = try AIModelListing.request(provider: .mistral, configuration: .init(endpoint: "https://proxy.invalid/v1", useCodestral: true), secrets: secrets)
    XCTAssertEqual(request.url?.host, "proxy.invalid")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
  }
  func testLiveBackendReasoningBudgetReachesProtocolOutputCap() async throws {
    let pairs: [(AIProvider, String)] = [(.openAI, "gpt-6-astra"), (.zhiPu, "glm-5.3"), (.minimaxPlan, "MiniMax-M3.1-Flash"),
      (.mimoTokenPlan, "mimo-v2.6-pro"), (.moonshot, "kimi-k3"), (.deepSeek, "deepseek-v4-pro"), (.opencodeZen, "claude-fable-5-1")]
    for (provider, model) in pairs {
      let configuration = AIProviderConfiguration(models: [AIModel(id: model, name: model, contextTokens: 128_000, maxOutputTokens: 32_000)])
      let store = AIConfigurationStore.fixture(configurations: [provider: configuration], secrets: [provider: secrets])
      let anthropic = AIChatRequestPlanner.family(provider, model: model) == .anthropic
      let body = anthropic ? #"{"content":[{"type":"text","text":"answer"}],"stop_reason":"end_turn"}"# : #"{"choices":[{"message":{"content":"answer"},"finish_reason":"stop"}]}"#
      let transport = AIListingFixture([(200, body)])
      let backend = try await AILiveBackendFactory(configuration: store, client: AIChatClient(transport: transport)).backend(provider: provider, modelID: model)
      let budget = backend.budget(desiredOutput: 1500)
      XCTAssertEqual(budget.maxOutputTokens, 16_000, model)
      var request = AIConversationRequest(system: nil, messages: [.user("hello")])
      request.budget = budget
      var answer = ""
      for try await text in backend.stream(request, options: .init(effort: "low"), streaming: false) { answer += text }
      XCTAssertEqual(answer, "answer")
      let captured = await transport.requests
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(captured.first?.httpBody)) as? [String: Any])
      let cap = [.openAI, .mimoTokenPlan, .moonshot].contains(provider) ? "max_completion_tokens" : "max_tokens"
      XCTAssertEqual(payload[cap] as? Int, 16_000, model)
    }
  }
  func testKimiK3RejectsIncompleteReasoningHistory() throws {
    XCTAssertThrowsError(try AIChatRequestPlanner.request(provider: .moonshot, configuration: .init(), secrets: secrets,
      model: "kimi-k3", conversation: .init(system: nil, messages: [.user("one"), .assistant("answer"), .user("two")]))) {
      XCTAssertEqual($0 as? AIChatFailure, .reasoningHistoryRequired)
    }
  }
  func testOversizedPublicConfigurationIsRejectedBeforePersistence() throws {
    let models = (0..<1000).map { AIModel(id: "m\($0)", name: String(repeating: "a", count: 1024), capabilities: Array(repeating: String(repeating: "b", count: 128), count: 100)) }
    XCTAssertThrowsError(try AIConfigurationStore.encodePublicConfiguration([.openAI: .init(models: models)]))
  }
}
