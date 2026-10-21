import AIChat
import Foundation
import Testing

@Suite("UIMessage coding")
struct UIMessageCodingTests {
    static let aiSDKMessage = #"""
    {
      "id": "msg-1",
      "role": "assistant",
      "metadata": {"threadId": "t-1", "model": "claude-sonnet-5.5"},
      "parts": [
        {"type": "step-start"},
        {"type": "reasoning", "text": "Thinking", "state": "done", "providerMetadata": {"anthropic": {"signature": "sig"}}},
        {"type": "text", "text": "Hello", "state": "done"},
        {"type": "tool-getWeather", "toolCallId": "call-1", "state": "output-available", "input": {"city": "Paris"}, "output": {"celsius": 21}},
        {"type": "dynamic-tool", "toolName": "mcp_search", "toolCallId": "call-2", "state": "output-error", "input": {"q": "x"}, "errorText": "boom"},
        {"type": "tool-deleteItem", "toolCallId": "call-3", "state": "approval-requested", "input": {"id": "a"}, "approval": {"id": "approval-1"}},
        {"type": "source-url", "sourceId": "s1", "url": "https://example.com", "title": "Example"},
        {"type": "source-document", "sourceId": "s2", "mediaType": "application/pdf", "title": "Doc", "filename": "doc.pdf"},
        {"type": "file", "mediaType": "image/png", "url": "data:image/png;base64,iVBORw0KGgo=", "filename": "dot.png"},
        {"type": "data-weather", "id": "w1", "data": {"status": "loading"}},
        {"type": "custom", "kind": "openai.compaction", "providerMetadata": {"openai": {"id": "c"}}},
        {"type": "reasoning-file", "mediaType": "image/png", "url": "https://example.com/r.png"},
        {"type": "future-part", "payload": [1, 2, 3]}
      ],
      "someFutureField": true
    }
    """#

    @Test func decodesEveryPartType() throws {
        let message = try UIMessage(jsonData: Data(Self.aiSDKMessage.utf8))
        #expect(message.id == "msg-1")
        #expect(message.role == .assistant)
        #expect(message.metadata?["threadId"] == "t-1")
        #expect(message.parts.map(\.type) == [
            "step-start", "reasoning", "text", "tool-getWeather", "dynamic-tool", "tool-deleteItem",
            "source-url", "source-document", "file", "data-weather", "custom", "reasoning-file", "future-part",
        ])
        let weather = try #require(message.toolPart(callID: "call-1"))
        #expect(weather.toolName == "getWeather")
        #expect(!weather.isDynamic)
        #expect(weather.state == .outputAvailable)
        #expect(weather.output == ["celsius": 21])
        let dynamic = try #require(message.toolPart(callID: "call-2"))
        #expect(dynamic.isDynamic)
        #expect(dynamic.toolName == "mcp_search")
        #expect(dynamic.errorText == "boom")
        #expect(message.toolPart(callID: "call-3")?.approval?.id == "approval-1")
        #expect(message.text == "Hello")
        #expect(message.reasoningText == "Thinking")
        #expect(message.dataParts(named: "weather").first?.id == "w1")
        #expect(message.fileParts.first?.inlineData?.count == 8)
        #expect(message.extra["someFutureField"] == true)
    }

    @Test func roundTripsToTheSameJSON() throws {
        let original = try JSONValue(parsing: Self.aiSDKMessage)
        let message = try UIMessage(jsonData: Data(Self.aiSDKMessage.utf8))
        #expect(message.jsonValue == original)
    }

    @Test func roundTripsThroughCodable() throws {
        let message = try UIMessage(jsonData: Data(Self.aiSDKMessage.utf8))
        let data = try JSONEncoder().encode([message])
        let decoded = try JSONDecoder().decode([UIMessage].self, from: data)
        #expect(decoded == [message])
    }

    @Test func distinguishesMissingAndNullToolOutput() throws {
        let json = #"{"id":"m","role":"assistant","parts":[{"type":"tool-a","toolCallId":"c","state":"output-available","input":{},"output":null}]}"#
        let message = try UIMessage(jsonData: Data(json.utf8))
        #expect(message.toolParts.first?.output == .null)
        let expected = try JSONValue(parsing: json)
        #expect(message.jsonValue == expected)
    }

    @Test func staticToolPartsDoNotWriteToolName() {
        let part = UIMessagePart.tool(ToolPart(toolName: "lookup", toolCallId: "c", state: .inputAvailable, input: [:]))
        #expect(part.jsonObject["toolName"] == nil)
        #expect(part.jsonObject["type"] == "tool-lookup")
    }

    @Test func toolNamesWithDotsAndDashesSurvive() throws {
        let json = #"{"type":"tool-user.foodLog.list-by-date","toolCallId":"c","state":"input-streaming"}"#
        let part = try UIMessagePart(jsonData: Data(json.utf8))
        #expect(part.toolPart?.toolName == "user.foodLog.list-by-date")
        let expected = try JSONValue(parsing: json)
        #expect(part.jsonValue == expected)
    }

    @Test func rejectsMessagesWithoutParts() {
        #expect(throws: ChatError.self) {
            try UIMessage(jsonData: Data(#"{"id":"m","role":"user"}"#.utf8))
        }
    }

    @Test func rejectsUnknownRoles() {
        #expect(throws: ChatError.self) {
            try UIMessage(jsonData: Data(#"{"id":"m","role":"tool","parts":[]}"#.utf8))
        }
    }

    @Test func buildsUserMessagesWithFilesFirst() {
        let message = UIMessage.user("Describe this", files: [FilePart(data: Data([1, 2, 3]), mediaType: "image/jpeg")])
        #expect(message.parts.map(\.type) == ["file", "text"])
        #expect(message.fileParts.first?.url.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test func splitsSteps() throws {
        let message = try UIMessage(jsonData: Data(Self.aiSDKMessage.utf8))
        #expect(message.steps.count == 1)
        #expect(message.lastStepParts.count == message.parts.count - 1)
    }

    @Test func emptyMeansNothingVisible() {
        #expect(UIMessage(role: .assistant, parts: [.stepStart, .data(name: "x", data: 1)]).isEmpty)
        #expect(!UIMessage(role: .assistant, parts: [.text("hi")]).isEmpty)
    }
}
