import AIChat
import AIChatOpenAI
import AIChatTesting
import Foundation
import Testing

enum Fixture {
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name))
    }

    static func stream(_ name: String, chunkSize: Int = 37) throws -> StubHTTPClient.Stub {
        .eventStream(try data(name), chunkSize: chunkSize, headers: ["x-request-id": "req_test"])
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

@MainActor
@Suite("OpenAI Responses")
struct OpenAIResponsesTests {
    private func transport(_ http: StubHTTPClient, configure: (inout OpenAIConfiguration) -> Void = { _ in }) -> OpenAIChatTransport {
        var configuration = OpenAIConfiguration(apiKey: "sk-test", httpClient: http)
        configure(&configuration)
        return OpenAIChatTransport(configuration: configuration)
    }

    @Test func sendsAStreamingResponsesRequest() async throws {
        let http = StubHTTPClient([try Fixture.stream("responses-reasoning.sse")])
        let chat = Chat(transport: transport(http) { configuration in
            configuration.system = "You are concise."
            configuration.systemMessageRole = .developer
            configuration.reasoning = .init(effort: .high, summary: .detailed)
            configuration.verbosity = "low"
            configuration.maxOutputTokens = 2_000
            configuration.builtInTools = [["type": "web_search"]]
            configuration.organization = "org_1"
        }, configuration: ChatConfiguration(tools: [ChatTool(name: "get_weather", description: "Weather", inputSchema: ["type": "object"])]))
        await chat.sendMessage("Is 221 prime?")

        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "openai-organization") == "org_1")
        let body = try #require(http.requestBodies.first)
        #expect(body["model"] == "gpt-5.5")
        #expect(body["stream"] == true)
        #expect(body["store"] == false)
        #expect(body["include"] == ["reasoning.encrypted_content"])
        #expect(body["reasoning"] == ["effort": "high", "summary": "detailed"])
        #expect(body["text"] == ["verbosity": "low"])
        #expect(body["max_output_tokens"] == 2_000)
        #expect(body["tools"] == [
            ["type": "function", "name": "get_weather", "description": "Weather", "parameters": ["type": "object"], "strict": false],
            ["type": "web_search"],
        ])
        #expect(body["input"] == [
            ["role": "developer", "content": "You are concise."],
            ["role": "user", "content": [["type": "input_text", "text": "Is 221 prime?"]]],
        ])
    }

    @Test func streamsReasoningSummariesAndText() async throws {
        var finish: ChatFinishEvent?
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("responses-reasoning.sse")])), configuration: ChatConfiguration(onFinish: { finish = $0 }))
        await chat.sendMessage("Is 221 prime?")
        let reply = try #require(chat.messages.last)
        #expect(reply.parts.map(\.type) == ["step-start", "reasoning", "text"])
        let reasoning = try #require(reply.parts.compactMap(\.reasoningPart).first)
        #expect(reasoning.text.hasPrefix("**Checking divisibility**"))
        #expect(reasoning.providerMetadata?["openai"]?["encryptedContent"] == "enc_reasoning_1")
        let text = try #require(reply.parts.compactMap(\.textPart).first)
        #expect(text.text == "No—221 is not prime, because it equals 13 × 17.")
        #expect(text.providerMetadata?["openai"]?["phase"] == "final_answer")
        #expect(finish?.finishReason == .stop)
        #expect(reply.metadata?["usage"]?["reasoningTokens"] == 24)
        #expect(reply.metadata?["model"] == "gpt-5.4-mini-2026-03-17")
        #expect(chat.status == .ready)
    }

    @Test func passesReasoningBackAsEncryptedContent() async throws {
        let http = StubHTTPClient([try Fixture.stream("responses-reasoning.sse"), try Fixture.stream("responses-incomplete.sse")])
        let chat = Chat(transport: transport(http))
        await chat.sendMessage("Is 221 prime?")
        await chat.sendMessage("And 223?")

        let input = try #require(http.requestBodies.last?["input"]?.arrayValue)
        #expect(input.count == 4)
        #expect(input[1]["type"] == "reasoning")
        #expect(input[1]["id"] == "rs_0737c479c96fe063016ad86f4bb84c87d1854cd9ab8d8c084e")
        #expect(input[1]["encrypted_content"] == "enc_reasoning_1")
        #expect(input[1]["summary"]?[0]?["type"] == "summary_text")
        #expect(input[2] == [
            "type": "message",
            "role": "assistant",
            "phase": "final_answer",
            "content": [["type": "output_text", "text": "No—221 is not prime, because it equals 13 × 17."]],
        ])
        #expect(input[3] == ["role": "user", "content": [["type": "input_text", "text": "And 223?"]]])
    }

    @Test func storedResponsesSendItemReferences() async throws {
        let http = StubHTTPClient([try Fixture.stream("responses-web-search.sse"), try Fixture.stream("responses-reasoning.sse"), try Fixture.stream("responses-incomplete.sse")])
        let chat = Chat(transport: transport(http) { $0.store = true })
        await chat.sendMessage("Events in Lisbon?")
        await chat.sendMessage("Is 221 prime?")
        await chat.sendMessage("Thanks")

        let input = try #require(http.requestBodies.last?["input"]?.arrayValue)
        #expect(http.requestBodies.last?["include"] == nil)
        #expect(input.map { $0["type"] ?? $0["role"] } == ["user", "item_reference", "message", "user", "item_reference", "message", "user"])
        #expect(input[1]["id"] == "ws_1")
        #expect(input[2]["id"] == "msg_1")
        #expect(input[4]["id"] == "rs_0737c479c96fe063016ad86f4bb84c87d1854cd9ab8d8c084e")
    }

    @Test func runsFunctionCallsAndSendsTheirOutput() async throws {
        let http = StubHTTPClient([try Fixture.stream("responses-function-call.sse"), try Fixture.stream("responses-reasoning.sse")])
        let weather = ChatTool(name: "get_weather", inputSchema: ["type": "object"]) { call in
            ["city": call.input["city"] ?? "", "celsius": 18]
        }
        let chat = Chat(transport: transport(http), configuration: ChatConfiguration(tools: [weather]))
        await chat.sendMessage("What's the weather in Paris?")
        try await waitUntil { http.requests.count == 2 && chat.status == .ready }

        let input = try #require(http.requestBodies.last?["input"]?.arrayValue)
        #expect(input.count == 3)
        #expect(input[1] == [
            "type": "function_call",
            "call_id": "call_gUhz3NpkXOv5DG1gE4JfD7l0",
            "name": "get_weather",
            "arguments": #"{"city":"Paris"}"#,
        ])
        #expect(input[2] == [
            "type": "function_call_output",
            "call_id": "call_gUhz3NpkXOv5DG1gE4JfD7l0",
            "output": #"{"celsius":18,"city":"Paris"}"#,
        ])
        let reply = try #require(chat.messages.last)
        #expect(reply.toolPart(callID: "call_gUhz3NpkXOv5DG1gE4JfD7l0")?.state == .outputAvailable)
        #expect(reply.parts.map(\.type) == ["step-start", "tool-get_weather", "step-start", "reasoning", "text"])
    }

    @Test func deniedApprovalsBecomeFunctionOutputs() async throws {
        let http = StubHTTPClient([try Fixture.stream("responses-incomplete.sse")])
        let assistant = UIMessage(id: "a1", role: .assistant, parts: [
            .stepStart,
            .tool(ToolPart(toolName: "delete_file", toolCallId: "call_1", state: .outputDenied, input: ["path": "a"], approval: ToolApproval(id: "ap", approved: false, reason: "Keep it"))),
            .tool(ToolPart(toolName: "ask", toolCallId: "call_2", state: .inputAvailable, input: nil)),
        ])
        let chat = Chat(messages: [.user("Clean up"), assistant, .user("Never mind")], transport: transport(http))
        await chat.submit()
        let input = try #require(http.requestBodies.first?["input"]?.arrayValue)
        #expect(input.map { $0["type"] ?? $0["role"] } == ["user", "function_call", "function_call", "function_call_output", "function_call_output", "user"])
        #expect(input[2]["arguments"] == "{}")
        #expect(input[3]["output"] == "The user denied this tool call. Reason: Keep it")
        #expect(input[4]["output"] == "The tool call did not finish, so it has no result.")
    }

    @Test func webSearchBecomesAProviderToolWithSources() async throws {
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("responses-web-search.sse", chunkSize: 19)])) { configuration in
            configuration.builtInTools = [["type": "web_search"]]
        })
        await chat.sendMessage("Events in Lisbon this weekend?")
        let reply = try #require(chat.messages.last)
        let search = try #require(reply.toolPart(callID: "ws_1"))
        #expect(search.toolName == "web_search")
        #expect(search.providerExecuted == true)
        #expect(search.state == .outputAvailable)
        #expect(search.input?["query"] == "Lisbon events this weekend")
        #expect(search.output?["status"] == "completed")
        #expect(reply.sourceURLParts.map(\.url) == ["https://www.lisboa.pt/en/events", "https://www.visitlisboa.com/en/events"])
        #expect(reply.text == "Lisbon hosts a jazz festival this weekend.")
        #expect(reply.metadata?["usage"]?["cachedInputTokens"] == 256)
    }

    @Test func incompleteResponsesFinishWithLength() async throws {
        var finish: ChatFinishEvent?
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("responses-incomplete.sse")])), configuration: ChatConfiguration(onFinish: { finish = $0 }))
        await chat.sendMessage("Tell me a story")
        #expect(finish?.finishReason == .length)
        #expect(chat.messages.last?.text == "Once upon a")
        #expect(chat.status == .ready)
    }

    @Test func failedResponsesKeepThePartialText() async throws {
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("responses-failed.sse")])))
        await chat.sendMessage("Hi")
        #expect(chat.status == .error)
        #expect(chat.error?.code == "server_error")
        #expect(chat.error?.isRetryable == true)
        #expect(chat.messages.last?.text == "Partial")
    }

    @Test func truncatedStreamsAreDisconnects() async throws {
        let chat = Chat(transport: transport(StubHTTPClient([try Fixture.stream("responses-truncated.sse")])))
        await chat.sendMessage("Hi")
        #expect(chat.error?.isDisconnect == true)
        #expect(chat.messages.last?.text == "Half a sen")
    }

    @Test func httpErrorsCarryTheOpenAICode() async throws {
        let http = StubHTTPClient([StubHTTPClient.Stub(statusCode: 401, headers: ["x-request-id": "req_401", "content-type": "application/json"], chunks: [try Fixture.data("http-error.json")])])
        let chat = Chat(transport: transport(http))
        await chat.sendMessage("Hi")
        let error = try #require(chat.error)
        #expect(error.statusCode == 401)
        #expect(error.code == "invalid_api_key")
        #expect(error.message == "Incorrect API key provided: sk-test.")
        #expect(!error.isRetryable)
    }

    @Test func convertsAttachments() async throws {
        let http = StubHTTPClient([try Fixture.stream("responses-incomplete.sse")])
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let pdf = Data("%PDF-1.7".utf8)
        let chat = Chat(messages: [UIMessage(role: .user, parts: [
            .file(data: png, mediaType: "image/png", filename: "dot.png"),
            .file(url: "https://example.com/photo.jpg", mediaType: "image/jpeg"),
            .file(data: pdf, mediaType: "application/pdf", filename: "report.pdf"),
            .file(url: "https://example.com/paper.pdf", mediaType: "application/pdf"),
            .file(data: Data("notes".utf8), mediaType: "text/plain", filename: "notes.txt"),
            .text("Summarize"),
            .data(name: "screenContext", data: ["screen": "home"]),
        ])], transport: transport(http) { $0.dataPartConverter = { "Context: \($0.data.jsonString)" } })
        await chat.submit()
        let content = try #require(http.requestBodies.first?["input"]?[0]?["content"]?.arrayValue)
        #expect(content == [
            ["type": "input_image", "image_url": .string("data:image/png;base64,\(png.base64EncodedString())"), "detail": "auto"],
            ["type": "input_image", "image_url": "https://example.com/photo.jpg", "detail": "auto"],
            ["type": "input_file", "filename": "report.pdf", "file_data": .string("data:application/pdf;base64,\(pdf.base64EncodedString())")],
            ["type": "input_file", "file_url": "https://example.com/paper.pdf"],
            ["type": "input_text", "text": "notes.txt:\nnotes"],
            ["type": "input_text", "text": "Summarize"],
            ["type": "input_text", "text": #"Context: {"screen":"home"}"#],
        ])
    }
}
