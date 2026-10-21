import AIChat
import AIChatOpenAI
import AIChatTesting
import Foundation
import Testing

@MainActor
@Suite("OpenAI Chat Completions")
struct OpenAIChatCompletionsTests {
    private func transport(_ http: StubHTTPClient, configure: (inout OpenAIConfiguration) -> Void = { _ in }) -> OpenAIChatTransport {
        var configuration = OpenAIConfiguration(apiKey: "sk-test", api: .chatCompletions, httpClient: http)
        configure(&configuration)
        return OpenAIChatTransport(configuration: configuration)
    }

    @Test func sendsAStreamingChatCompletionsRequest() async throws {
        let http = StubHTTPClient([try Fixture.stream("chat-text.sse")])
        let chat = Chat(transport: transport(http) { configuration in
            configuration.system = "Be brief."
            configuration.reasoning = .init(effort: .low)
            configuration.maxOutputTokens = 500
            configuration.parallelToolCalls = false
        }, configuration: ChatConfiguration(tools: [ChatTool(name: "get_weather", inputSchema: ["type": "object"], strict: true)]))
        await chat.sendMessage("Say hi in French.")

        #expect(http.requests.first?.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        let body = try #require(http.requestBodies.first)
        #expect(body["stream_options"] == ["include_usage": true])
        #expect(body["reasoning_effort"] == "low")
        #expect(body["max_completion_tokens"] == 500)
        #expect(body["parallel_tool_calls"] == false)
        #expect(body["tools"] == [["type": "function", "function": ["name": "get_weather", "parameters": ["type": "object"], "strict": true]]])
        #expect(body["messages"] == [
            ["role": "system", "content": "Be brief."],
            ["role": "user", "content": "Say hi in French."],
        ])
        #expect(chat.messages.last?.text == "Bonjour !")
        #expect(chat.messages.last?.metadata?["usage"]?["inputTokens"] == 18)
    }

    @Test func runsParallelToolCallsAndSendsTheResults() async throws {
        let http = StubHTTPClient([try Fixture.stream("chat-parallel-tools.sse"), try Fixture.stream("chat-text.sse")])
        let weather = ChatTool(name: "get_weather", inputSchema: ["type": "object"]) { call in
            ["city": call.input["city"] ?? "", "celsius": 18]
        }
        var finishes: [FinishReason?] = []
        let chat = Chat(transport: transport(http), configuration: ChatConfiguration(tools: [weather], onFinish: { finishes.append($0.finishReason) }))
        await chat.sendMessage("Weather in Paris and Tokyo?")
        try await waitUntil { http.requests.count == 2 && chat.status == .ready }

        let messages = try #require(http.requestBodies.last?["messages"]?.arrayValue)
        #expect(messages.count == 4)
        #expect(messages[1]["content"] == .null)
        #expect(messages[1]["tool_calls"]?.arrayValue?.map { $0["function"]?["arguments"] } == [#"{"city":"Paris"}"#, #"{"city":"Tokyo"}"#])
        #expect(messages[2] == ["role": "tool", "tool_call_id": "call_DuPdIHEF2Rs8OqXO38XZefcd", "content": #"{"celsius":18,"city":"Paris"}"#])
        #expect(messages[3]["tool_call_id"] == "call_q7C7tBINHGkQxEUIs7PoCFkJ")
        let reply = try #require(chat.messages.last)
        #expect(reply.parts.map(\.type) == ["step-start", "tool-get_weather", "tool-get_weather", "step-start", "text"])
        #expect(reply.toolPart(callID: "call_q7C7tBINHGkQxEUIs7PoCFkJ")?.input == ["city": "Tokyo"])
        #expect(finishes.first == .toolCalls)
    }

    @Test func readsReasoningContentFromCompatibleServers() async throws {
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("chat-reasoning-content.sse", chunkSize: 11)])))
        await chat.sendMessage("Is 221 prime?")
        let reply = try #require(chat.messages.last)
        #expect(reply.parts.map(\.type) == ["step-start", "reasoning", "text"])
        #expect(reply.parts.compactMap(\.reasoningPart).first?.text == "221 = 13 × 17, so it is composite.")
        #expect(reply.text == "No, 221 is 13 × 17.")
        #expect(reply.metadata?["usage"]?["reasoningTokens"] == 18)
        #expect(reply.metadata?["model"] == "deepseek-reasoner")
    }

    @Test func errorChunksKeepThePartialText() async throws {
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("chat-error.sse")])))
        await chat.sendMessage("Hi")
        #expect(chat.status == .error)
        #expect(chat.error?.code == "rate_limit_exceeded")
        #expect(chat.error?.isRetryable == true)
        #expect(chat.messages.last?.text == "Hel")
    }

    @Test func truncatedStreamsAreDisconnects() async throws {
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("chat-truncated.sse")])))
        await chat.sendMessage("Hi")
        #expect(chat.error?.isDisconnect == true)
    }

    @Test func convertsAttachmentsAndAssistantSteps() async throws {
        let http = StubHTTPClient([try Fixture.stream("chat-text.sse")])
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let assistant = UIMessage(id: "a1", role: .assistant, parts: [
            .stepStart,
            .reasoning(ReasoningPart(text: "Thinking")),
            .text("Let me check."),
            .tool(ToolPart(toolName: "web_search", toolCallId: "ws", state: .outputAvailable, input: [:], output: [:], providerExecuted: true)),
            .tool(ToolPart(toolName: "delete_file", toolCallId: "call_1", state: .outputDenied, input: ["path": "a"], approval: ToolApproval(id: "ap", approved: false))),
            .stepStart,
            .text("Kept it."),
        ])
        let chat = Chat(messages: [
            UIMessage(role: .user, parts: [
                .file(data: png, mediaType: "image/png"),
                .file(data: Data("%PDF".utf8), mediaType: "application/pdf", filename: "a.pdf"),
                .text("Look"),
            ]),
            assistant,
            .user("Ok"),
        ], transport: transport(http))
        await chat.submit()
        let messages = try #require(http.requestBodies.first?["messages"]?.arrayValue)
        #expect(messages[0]["content"] == [
            ["type": "image_url", "image_url": ["url": .string("data:image/png;base64,\(png.base64EncodedString())")]],
            ["type": "file", "file": ["filename": "a.pdf", "file_data": .string("data:application/pdf;base64,\(Data("%PDF".utf8).base64EncodedString())")]],
            ["type": "text", "text": "Look"],
        ])
        #expect(messages[1] == [
            "role": "assistant",
            "content": "Let me check.",
            "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "delete_file", "arguments": #"{"path":"a"}"#]]],
        ])
        #expect(messages[2] == ["role": "tool", "tool_call_id": "call_1", "content": "The user denied this tool call."])
        #expect(messages[3] == ["role": "assistant", "content": "Kept it."])
        #expect(messages[4] == ["role": "user", "content": "Ok"])
    }

    @Test func pdfURLsNeedTheBytes() async throws {
        let http = StubHTTPClient([try Fixture.stream("chat-text.sse")])
        let chat = Chat(messages: [UIMessage(role: .user, parts: [.file(url: "https://example.com/a.pdf", mediaType: "application/pdf")])], transport: transport(http))
        await chat.submit()
        #expect(chat.error?.code == "unsupported_file_url")
        #expect(http.requests.isEmpty)
    }

    @Test func gatewayConfigurationUsesTheGatewayURL() async throws {
        let http = StubHTTPClient([try Fixture.stream("chat-text.sse")])
        var configuration = OpenAIConfiguration.aiGateway(apiKey: "gw")
        configuration.httpClient = http
        let chat = Chat(transport: OpenAIChatTransport(configuration: configuration))
        await chat.sendMessage("Hi")
        #expect(http.requests.first?.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/chat/completions")
        #expect(http.requestBodies.first?["model"] == "openai/gpt-5.5")
    }

    @Test func listsChatModelsNewestFirst() async throws {
        let http = StubHTTPClient([.json(try JSONValue(parsing: try Fixture.data("models.json")))])
        let models = try await OpenAIModelCatalog(configuration: OpenAIConfiguration(apiKey: "k", httpClient: http)).models()
        #expect(models.map(\.id) == ["gpt-5.5", "gpt-5.4-mini", "o3"])
        #expect(models.allSatisfy { $0.provider == "openai" })
        #expect(http.requests.first?.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(http.requests.first?.value(forHTTPHeaderField: "authorization") == "Bearer k")
    }
}
