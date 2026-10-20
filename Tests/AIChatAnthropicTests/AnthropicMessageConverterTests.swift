import AIChat
import AIChatAnthropic
import AIChatTesting
import Foundation
import Testing

@MainActor
@Suite("Anthropic message conversion")
struct AnthropicMessageConverterTests {
    private func sentBody(_ messages: [UIMessage], configure: (inout AnthropicConfiguration) -> Void = { _ in }) async throws -> JSONValue {
        let http = StubHTTPClient([.eventStream("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")])
        var configuration = AnthropicConfiguration(authentication: .apiKey("k"), httpClient: http)
        configure(&configuration)
        let chat = Chat(messages: messages, transport: AnthropicChatTransport(configuration: configuration))
        await chat.submit()
        return try #require(http.requestBodies.first)
    }

    @Test func convertsAttachmentsAndSystemMessages() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let body = try await sentBody([
            .system("Answer in French."),
            UIMessage(role: .user, parts: [
                .file(data: png, mediaType: "image/png", filename: "dot.png"),
                .file(url: "https://example.com/report.pdf", mediaType: "application/pdf", filename: "report.pdf"),
                .file(data: Data("notes".utf8), mediaType: "text/plain", filename: "notes.txt"),
                .text("Summarize these"),
                .data(name: "screenContext", data: ["screen": "home"]),
            ]),
        ]) { configuration in
            configuration.system = "Be brief."
            configuration.dataPartConverter = { part in "Context: \(part.data.jsonString)" }
        }
        #expect(body["system"] == [["type": "text", "text": "Be brief."], ["type": "text", "text": "Answer in French."]])
        let content = try #require(body["messages"]?[0]?["content"]?.arrayValue)
        #expect(content[0] == ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(png.base64EncodedString())]])
        #expect(content[1] == ["type": "document", "title": "report.pdf", "source": ["type": "url", "url": "https://example.com/report.pdf"]])
        #expect(content[2] == ["type": "document", "title": "notes.txt", "source": ["type": "text", "media_type": "text/plain", "data": "notes"]])
        #expect(content[3] == ["type": "text", "text": "Summarize these"])
        #expect(content[4] == ["type": "text", "text": #"Context: {"screen":"home"}"#])
    }

    @Test func splitsAssistantStepsIntoToolTurns() async throws {
        let assistant = UIMessage(id: "a1", role: .assistant, parts: [
            .stepStart,
            .reasoning(ReasoningPart(text: "Let me check.", providerMetadata: ["anthropic": ["signature": "sig-1"]])),
            .reasoning(ReasoningPart(text: "", providerMetadata: ["anthropic": ["redactedData": "opaque"]])),
            .reasoning(ReasoningPart(text: "From another provider")),
            .text("Checking both."),
            .tool(ToolPart(toolName: "get_weather", toolCallId: "t1", state: .outputAvailable, input: ["city": "Paris"], output: ["celsius": 21])),
            .tool(ToolPart(toolName: "get_time", toolCallId: "t2", state: .outputError, input: [:], errorText: "Clock unavailable")),
            .stepStart,
            .tool(ToolPart(toolName: "delete_file", toolCallId: "t3", state: .outputDenied, input: ["path": "a"], approval: ToolApproval(id: "ap", approved: false, reason: "Keep it"))),
            .tool(ToolPart(toolName: "ask", toolCallId: "t4", state: .inputAvailable, input: .string("raw"))),
            .text("Done."),
        ])
        let body = try await sentBody([.user("Weather and time?"), assistant, .user("Thanks")])
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.map { $0["role"] } == ["user", "assistant", "user", "assistant", "user"])
        #expect(messages[1]["content"] == [
            ["type": "thinking", "thinking": "Let me check.", "signature": "sig-1"],
            ["type": "redacted_thinking", "data": "opaque"],
            ["type": "text", "text": "Checking both."],
            ["type": "tool_use", "id": "t1", "name": "get_weather", "input": ["city": "Paris"]],
            ["type": "tool_use", "id": "t2", "name": "get_time", "input": [:]],
        ])
        #expect(messages[2]["content"] == [
            ["type": "tool_result", "tool_use_id": "t1", "content": #"{"celsius":21}"#],
            ["type": "tool_result", "tool_use_id": "t2", "content": "Clock unavailable", "is_error": true],
        ])
        #expect(messages[3]["content"] == [
            ["type": "tool_use", "id": "t3", "name": "delete_file", "input": ["path": "a"]],
            ["type": "tool_use", "id": "t4", "name": "ask", "input": ["input": "raw"]],
            ["type": "text", "text": "Done."],
        ])
        #expect(messages[4]["content"] == [
            ["type": "tool_result", "tool_use_id": "t3", "content": "The user denied this tool call. Reason: Keep it", "is_error": true],
            ["type": "tool_result", "tool_use_id": "t4", "content": "The tool call did not finish, so it has no result.", "is_error": true],
            ["type": "text", "text": "Thanks"],
        ])
    }

    @Test func replaysServerToolsInTheAssistantTurn() async throws {
        let assistant = UIMessage(role: .assistant, parts: [
            .tool(ToolPart(
                toolName: "web_search",
                toolCallId: "srv1",
                state: .outputAvailable,
                input: ["query": "x"],
                output: [["type": "web_search_result", "url": "https://a.com", "title": "A", "encrypted_content": "e"]],
                providerExecuted: true,
                resultProviderMetadata: ["anthropic": ["type": "web_search_tool_result"]]
            )),
            .text("Found it."),
        ])
        let body = try await sentBody([.user("Search"), assistant, .user("More")])
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 3)
        #expect(messages[1]["content"]?.arrayValue?.map { $0["type"] } == ["server_tool_use", "web_search_tool_result", "text"])
    }

    @Test func rejectsUnsupportedAttachments() async throws {
        let http = StubHTTPClient([])
        let chat = Chat(transport: AnthropicChatTransport(configuration: AnthropicConfiguration(authentication: .apiKey("k"), httpClient: http)))
        await chat.sendMessage("Play this", files: [FilePart(data: Data([1]), mediaType: "audio/mpeg")])
        #expect(chat.error?.code == "unsupported_media_type")
        #expect(http.requests.isEmpty)
    }

    @Test func relativeURLsNeedAResolver() async throws {
        let http = StubHTTPClient([])
        let chat = Chat(transport: AnthropicChatTransport(configuration: AnthropicConfiguration(authentication: .apiKey("k"), httpClient: http)))
        await chat.sendMessage("Look", files: [FilePart(mediaType: "image/jpeg", url: "/api/chat/attachments/abc")])
        #expect(chat.error?.code == "unsupported_file_url")
    }

    @Test func downloadingResolverFetchesRelativeURLs() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF])
        let files = StubHTTPClient([StubHTTPClient.Stub(statusCode: 200, headers: ["content-type": "image/jpeg"], chunks: [jpeg])])
        let body = try await sentBody([UIMessage(role: .user, parts: [.file(url: "/api/chat/attachments/abc", mediaType: "image/jpeg"), .text("Look")])]) { configuration in
            configuration.fileResolver = FileResolution.downloading(baseURL: URL(string: "https://baseline.test"), headers: ["Cookie": "session=1"], httpClient: files)
        }
        #expect(files.requests.first?.url?.absoluteString == "https://baseline.test/api/chat/attachments/abc")
        #expect(files.requests.first?.value(forHTTPHeaderField: "Cookie") == "session=1")
        #expect(body["messages"]?[0]?["content"]?[0] == ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": .string(jpeg.base64EncodedString())]])
    }
}
