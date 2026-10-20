import AIChat
import AIChatAnthropic
import AIChatTesting
import Foundation
import Testing

private enum Fixture {
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name))
    }

    static func stream(_ name: String, chunkSize: Int = 41) throws -> StubHTTPClient.Stub {
        .eventStream(try data(name), chunkSize: chunkSize, headers: ["request-id": "req_test"])
    }
}

@MainActor
@Suite("Anthropic transport")
struct AnthropicTransportTests {
    private func transport(_ http: StubHTTPClient, configure: (inout AnthropicConfiguration) -> Void = { _ in }) -> AnthropicChatTransport {
        var configuration = AnthropicConfiguration(authentication: .apiKey("sk-test"), httpClient: http)
        configure(&configuration)
        return AnthropicChatTransport(configuration: configuration)
    }

    @Test func sendsAStreamingMessagesRequest() async throws {
        let http = StubHTTPClient([try Fixture.stream("docs-basic.sse")])
        let chat = Chat(transport: transport(http) { configuration in
            configuration.system = "You are concise."
            configuration.thinking = .adaptive(display: .summarized)
            configuration.effort = .high
            configuration.betas = ["fast-mode-2026-02-01"]
        }, configuration: ChatConfiguration(tools: [ChatTool(name: "get_weather", description: "Weather", inputSchema: ["type": "object", "properties": ["location": ["type": "string"]]])]))
        await chat.sendMessage("Hello")

        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "fast-mode-2026-02-01")
        let body = try #require(http.requestBodies.first)
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["stream"] == true)
        #expect(body["max_tokens"] == 64_000)
        #expect(body["system"] == [["type": "text", "text": "You are concise."]])
        #expect(body["messages"] == [["role": "user", "content": [["type": "text", "text": "Hello"]]]])
        #expect(body["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(body["output_config"] == ["effort": "high"])
        #expect(body["cache_control"] == ["type": "ephemeral"])
        #expect(body["tools"] == [[
            "name": "get_weather",
            "description": "Weather",
            "input_schema": ["type": "object", "properties": ["location": ["type": "string"]]],
            "eager_input_streaming": true,
        ]])

        let reply = try #require(chat.messages.last)
        #expect(reply.text == "Hello!")
        #expect(reply.metadata?["model"] == "claude-opus-5-5")
        #expect(reply.metadata?["provider"] == "anthropic")
        #expect(reply.metadata?["usage"]?["outputTokens"] == 15)
        #expect(chat.status == .ready)
    }

    @Test func bearerTokensUseTheOAuthBeta() async throws {
        let http = StubHTTPClient([try Fixture.stream("docs-basic.sse")])
        let transport = AnthropicChatTransport(configuration: AnthropicConfiguration(authentication: .bearerToken("oauth-token"), httpClient: http))
        await Chat(transport: transport).sendMessage("Hi")
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer oauth-token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func streamsToolUseAndFinishesWithToolCalls() async throws {
        var finish: ChatFinishEvent?
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("docs-tool-use.sse", chunkSize: 7)])), configuration: ChatConfiguration(onFinish: { finish = $0 }))
        await chat.sendMessage("What's the weather in San Francisco?")
        let reply = try #require(chat.messages.last)
        #expect(reply.parts.map(\.type) == ["step-start", "text", "tool-get_weather"])
        #expect(reply.text == "Okay, let's check the weather for San Francisco, CA:")
        let tool = try #require(reply.toolParts.first)
        #expect(tool.state == .inputAvailable)
        #expect(tool.input == ["location": "San Francisco, CA"])
        #expect(finish?.finishReason == .toolCalls)
    }

    @Test func keepsThinkingSignatures() async throws {
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("docs-thinking.sse")])))
        await chat.sendMessage("GCD of 1071 and 462?")
        let reply = try #require(chat.messages.last)
        let reasoning = try #require(reply.parts.compactMap(\.reasoningPart).first)
        #expect(reasoning.text.hasPrefix("I need to find the GCD"))
        #expect(reasoning.providerMetadata?["anthropic"]?["signature"]?.stringValue?.hasPrefix("EqQBCgIYAhIM") == true)
        #expect(reply.text == "The greatest common divisor of 1071 and 462 is **21**.")
    }

    @Test func redactedThinkingAndEmptyToolInput() async throws {
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("thinking-tools.sse")])))
        await chat.sendMessage("Weather and time in Paris?")
        let reply = try #require(chat.messages.last)
        let reasoning = reply.parts.compactMap(\.reasoningPart)
        #expect(reasoning.count == 2)
        #expect(reasoning[0].providerMetadata?["anthropic"]?["redactedData"] != nil)
        #expect(reasoning[1].providerMetadata?["anthropic"]?["signature"] == "EqQBCgIYAhIM1gbcDa9GJwZA2b3h")
        #expect(reply.toolPart(callID: "toolu_01")?.input == ["location": "Paris"])
        #expect(reply.toolPart(callID: "toolu_02")?.input == [:])
    }

    @Test func webSearchBecomesAProviderToolWithSourcesAndCitations() async throws {
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("web-search.sse", chunkSize: 23)])) { configuration in
            configuration.serverTools = [["type": "web_search_20260209", "name": "web_search"]]
        })
        await chat.sendMessage("Weather in NYC?")
        let reply = try #require(chat.messages.last)
        let search = try #require(reply.toolPart(callID: "srvtoolu_014hJH82Qum7Td6UV8gDXThB"))
        #expect(search.providerExecuted == true)
        #expect(search.state == .outputAvailable)
        #expect(search.input == ["query": "weather NYC today"])
        #expect(search.output?.arrayValue?.count == 2)
        #expect(search.resultProviderMetadata?["anthropic"]?["type"] == "web_search_tool_result")
        #expect(reply.sourceURLParts.map(\.url) == ["https://world-weather.info/forecast/usa/new_york/", "https://weather.example.com/nyc"])
        let cited = try #require(reply.parts.compactMap(\.textPart).last)
        #expect(cited.citations?.first?.citedText == "Partly cloudy, 18°C")
        #expect(reply.metadata?["usage"]?["inputTokens"] == 10682)
    }

    @Test func continuesPauseTurnsAutomatically() async throws {
        let http = StubHTTPClient([try Fixture.stream("pause-turn-1.sse"), try Fixture.stream("pause-turn-2.sse")])
        let chat = Chat(transport: transport(http))
        await chat.sendMessage("What changed in Swift 6.3?")

        #expect(http.requests.count == 2)
        let second = try #require(http.requestBodies.last)
        let messages = try #require(second["messages"]?.arrayValue)
        #expect(messages.count == 2)
        #expect(messages[1] == [
            "role": "assistant",
            "content": [["type": "server_tool_use", "id": "srvtoolu_A", "name": "web_search", "input": ["query": "swift 6.3 release notes"]]],
        ])
        let reply = try #require(chat.messages.last)
        #expect(reply.toolPart(callID: "srvtoolu_A")?.state == .outputError)
        #expect(reply.toolPart(callID: "srvtoolu_A")?.errorText == "max_uses_exceeded")
        #expect(reply.text == "I couldn't search again, but here is what I know.")
        #expect(reply.parts.filter(\.isStepStart).count == 2)
        #expect(reply.metadata?["usage"]?["outputTokens"] == 50)
    }

    @Test func streamErrorsKeepThePartialText() async throws {
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("error-overloaded.sse")])))
        await chat.sendMessage("Hi")
        #expect(chat.status == .error)
        #expect(chat.error?.code == "overloaded_error")
        #expect(chat.error?.isRetryable == true)
        #expect(chat.messages.last?.text == "Partial")
    }

    @Test func refusalsFinishWithContentFilter() async throws {
        var finish: ChatFinishEvent?
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("refusal.sse")])), configuration: ChatConfiguration(onFinish: { finish = $0 }))
        await chat.sendMessage("Hi")
        #expect(finish?.finishReason == .contentFilter)
        #expect(chat.messages.last?.metadata?["stopDetails"]?["category"] == "cyber")
        #expect(chat.status == .ready)
    }

    @Test func httpErrorsCarryTheAnthropicErrorType() async throws {
        let http = StubHTTPClient([StubHTTPClient.Stub(statusCode: 400, headers: ["request-id": "req_011CS", "content-type": "application/json"], chunks: [try Fixture.data("http-error.json")])])
        let chat = Chat(transport: transport(http))
        await chat.sendMessage("Hi")
        let error = try #require(chat.error)
        #expect(error.statusCode == 400)
        #expect(error.code == "invalid_request_error")
        #expect(error.message == "messages: text content blocks must be non-empty")
        #expect(error.requestID == "req_011CS")
        #expect(!error.isRetryable)
    }

    @Test func truncatedStreamsAreDisconnects() async throws {
        let full = String(decoding: try Fixture.data("docs-basic.sse"), as: UTF8.self)
        let truncated = full.components(separatedBy: "event: message_delta")[0]
        let chat = Chat(transport: transport(StubHTTPClient([.eventStream(truncated)])))
        await chat.sendMessage("Hi")
        #expect(chat.error?.isDisconnect == true)
        #expect(chat.messages.last?.text == "Hello!")
    }

    @Test func runsClientToolsInALoop() async throws {
        let final = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_final","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":600,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"It's 18°C and sunny in San Francisco."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        let http = StubHTTPClient([try Fixture.stream("docs-tool-use.sse"), .eventStream(final)])
        let weather = ChatTool(name: "get_weather", inputSchema: ["type": "object"]) { call in
            ["location": call.input["location"] ?? "", "celsius": 18, "sky": "sunny"]
        }
        let chat = Chat(transport: transport(http), configuration: ChatConfiguration(tools: [weather]))
        await chat.sendMessage("What's the weather in San Francisco?")
        try await waitUntil { http.requests.count == 2 && chat.status == .ready }

        let second = try #require(http.requestBodies.last)
        let messages = try #require(second["messages"]?.arrayValue)
        #expect(messages.count == 3)
        #expect(messages[1]["role"] == "assistant")
        #expect(messages[1]["content"]?.arrayValue?.map { $0["type"] } == ["text", "tool_use"])
        #expect(messages[1]["content"]?[1]?["input"] == ["location": "San Francisco, CA"])
        #expect(messages[2] == [
            "role": "user",
            "content": [[
                "type": "tool_result",
                "tool_use_id": "toolu_01T1x1fJ34qAmk2tNTrN7Up6",
                "content": .string(#"{"celsius":18,"location":"San Francisco, CA","sky":"sunny"}"#),
            ]],
        ])
        let reply = try #require(chat.messages.last)
        #expect(chat.messages.count == 2)
        #expect(reply.parts.map(\.type) == ["step-start", "text", "tool-get_weather", "step-start", "text"])
        #expect(reply.text.hasSuffix("It's 18°C and sunny in San Francisco."))
    }

    @Test func listsModelsAcrossPages() async throws {
        let http = StubHTTPClient([
            .json(try JSONValue(parsing: try Fixture.data("models-page-1.json"))),
            .json(try JSONValue(parsing: try Fixture.data("models-page-2.json"))),
        ])
        let models = try await AnthropicModelCatalog(configuration: AnthropicConfiguration(authentication: .apiKey("k"), httpClient: http)).models()
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-haiku-5-5", "claude-haiku-4-5-20251001"])
        #expect(models[0].displayName == "Claude Opus 5.5")
        #expect(models[0].contextWindow == 1_000_000)
        #expect(models[0].maxOutputTokens == 128_000)
        #expect(models[0].capabilities == [.toolUse, .imageInput, .fileInput, .reasoning, .structuredOutput])
        #expect(!models[1].supports(.fileInput))
        #expect(http.requests[1].url?.query?.contains("after_id=claude-haiku-5-5") == true)
        #expect(http.requests[0].value(forHTTPHeaderField: "x-api-key") == "k")
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for a condition")
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}
