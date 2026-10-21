import AIChat
import Foundation
import Testing

/// Scenarios ported from the AI SDK's `process-ui-message-stream.test.ts`.
@Suite("StreamingMessageState")
struct StreamingMessageStateTests {
    private func run(_ chunks: [UIMessageChunk], state: StreamingMessageState = StreamingMessageState(messageID: "msg-123")) throws -> (StreamingMessageState, [StreamingMessageState.Update]) {
        var state = state
        var updates: [StreamingMessageState.Update] = []
        for chunk in chunks { updates.append(try state.apply(chunk)) }
        return (state, updates)
    }

    @Test func streamsText() throws {
        let (state, updates) = try run([
            .start(messageId: "msg-123"),
            .startStep,
            .textStart(id: "text-1"),
            .textDelta(id: "text-1", delta: "Hello, "),
            .textDelta(id: "text-1", delta: "world!"),
            .textEnd(id: "text-1"),
            .finishStep,
            .finish(finishReason: .stop),
        ])
        #expect(state.message.parts == [.stepStart, .text(TextPart(text: "Hello, world!", state: .done))])
        #expect(state.finishReason == .stop)
        #expect(updates[0].messageChanged && !updates[0].updatesStatus)
        #expect(updates.filter(\.messageChanged).count == 6)
    }

    @Test func startSetsTheServerMessageID() throws {
        let (state, _) = try run([.start(messageId: "server-id", messageMetadata: ["threadId": "t-1"])])
        #expect(state.message.id == "server-id")
        #expect(state.message.metadata == ["threadId": "t-1"])
    }

    @Test func mergesMetadataAcrossChunks() throws {
        let (state, updates) = try run([
            .start(messageMetadata: ["threadId": "t-1", "usage": ["input": 3]]),
            .messageMetadata(["usage": ["output": 7]]),
            .messageMetadata(["usage": ["output": 7]]),
            .finish(messageMetadata: ["model": "m"]),
        ])
        #expect(state.message.metadata == ["threadId": "t-1", "usage": ["input": 3, "output": 7], "model": "m"])
        #expect(updates.map(\.messageChanged) == [true, true, false, true])
    }

    @Test func keepsActivePartsAcrossInterleavedStepBoundaries() throws {
        let (state, _) = try run([
            .textStart(id: "text-1"),
            .textDelta(id: "text-1", delta: "first "),
            .reasoningStart(id: "reasoning-1"),
            .reasoningDelta(id: "reasoning-1", delta: "thinking "),
            .startStep,
            .finishStep,
            .textDelta(id: "text-1", delta: "second"),
            .reasoningDelta(id: "reasoning-1", delta: "continued"),
            .textEnd(id: "text-1"),
            .reasoningEnd(id: "reasoning-1"),
        ])
        #expect(state.message.parts == [
            .text(TextPart(text: "first second", state: .done)),
            .reasoning(ReasoningPart(text: "thinking continued", state: .done, id: "reasoning-1")),
            .stepStart,
        ])
    }

    @Test func resetStepRemovesTheCurrentStep() throws {
        let (state, _) = try run([
            .startStep,
            .textStart(id: "completed-text"),
            .textDelta(id: "completed-text", delta: "Completed step"),
            .textEnd(id: "completed-text"),
            .finishStep,
            .startStep,
            .toolInputStart(ToolInputStartChunk(toolCallId: "stale-tool", toolName: "deleteFile")),
            .toolInputDelta(toolCallId: "stale-tool", inputTextDelta: #"{"path":"partial"#),
            .resetStep,
            .toolInputStart(ToolInputStartChunk(toolCallId: "retried-tool", toolName: "deleteFile")),
            .toolInputDelta(toolCallId: "retried-tool", inputTextDelta: #"{"path":"target"}"#),
            .toolInputAvailable(ToolInputAvailableChunk(toolCallId: "retried-tool", toolName: "deleteFile", input: ["path": "target"])),
        ])
        #expect(state.message.parts.map(\.type) == ["step-start", "text", "step-start", "tool-deleteFile"])
        let tool = try #require(state.message.toolParts.first)
        #expect(tool.toolCallId == "retried-tool")
        #expect(tool.state == .inputAvailable)
        #expect(tool.input == ["path": "target"])
        #expect(tool.rawInput == nil)
    }

    @Test func streamsToolInputAsPartialJSON() throws {
        var state = StreamingMessageState(messageID: "m")
        _ = try state.apply(.toolInputStart(ToolInputStartChunk(toolCallId: "call-1", toolName: "getWeather")))
        #expect(state.message.toolParts.first?.state == .inputStreaming)
        #expect(state.message.toolParts.first?.input == nil)
        _ = try state.apply(.toolInputDelta(toolCallId: "call-1", inputTextDelta: #"{"city":"San Fr"#))
        #expect(state.message.toolParts.first?.input == ["city": "San Fr"])
        #expect(state.message.toolParts.first?.rawInput == .string(#"{"city":"San Fr"#))
        _ = try state.apply(.toolInputDelta(toolCallId: "call-1", inputTextDelta: #"ancisco"}"#))
        let update = try state.apply(.toolInputAvailable(ToolInputAvailableChunk(toolCallId: "call-1", toolName: "getWeather", input: ["city": "San Francisco"])))
        #expect(update.toolCall == ToolCall(toolCallId: "call-1", toolName: "getWeather", input: ["city": "San Francisco"]))
        let tool = try #require(state.message.toolParts.first)
        #expect(tool.state == .inputAvailable)
        #expect(tool.rawInput == nil)
        #expect(state.message.parts.count == 1)
    }

    @Test func streamsTextEncodedToolInput() throws {
        var state = StreamingMessageState(messageID: "m")
        _ = try state.apply(.toolInputStart(ToolInputStartChunk(toolCallId: "c", toolName: "shell", inputEncoding: "text")))
        _ = try state.apply(.toolInputDelta(toolCallId: "c", inputTextDelta: "ls -"))
        #expect(state.message.toolParts.first?.input == "ls -")
        #expect(state.message.toolParts.first?.inputEncoding == "text")
    }

    @Test func usesTheCompletedToolNameForAStreamedPart() throws {
        let (state, _) = try run([
            .startStep,
            .toolInputStart(ToolInputStartChunk(toolCallId: "tool-call-0", toolName: "originalTool")),
            .toolInputDelta(toolCallId: "tool-call-0", inputTextDelta: #"{"value":"test"}"#),
            .toolInputAvailable(ToolInputAvailableChunk(toolCallId: "tool-call-0", toolName: "renamedTool", input: ["value": "test"])),
            .toolApprovalRequest(ToolApprovalRequestChunk(approvalId: "approval-0", toolCallId: "tool-call-0")),
        ])
        let tool = try #require(state.message.toolParts.first)
        #expect(tool.type == "tool-renamedTool")
        #expect(tool.state == .approvalRequested)
        #expect(tool.approval?.id == "approval-0")
        #expect(tool.input == ["value": "test"])
    }

    @Test func serverSideToolRoundTrip() throws {
        let (state, updates) = try run([
            .start(messageId: "msg-123"),
            .startStep,
            .toolInputAvailable(ToolInputAvailableChunk(toolCallId: "tool-call-id", toolName: "tool-name", input: ["city": "London"])),
            .toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: "tool-call-id", output: ["weather": "sunny"])),
            .finishStep,
            .startStep,
            .textStart(id: "text-1"),
            .textDelta(id: "text-1", delta: "The weather in London is sunny."),
            .textEnd(id: "text-1"),
            .finishStep,
            .finish(),
        ])
        #expect(updates.compactMap(\.toolCall).map(\.toolCallId) == ["tool-call-id"])
        #expect(state.message.parts.map(\.type) == ["step-start", "tool-tool-name", "step-start", "text"])
        let tool = try #require(state.message.toolParts.first)
        #expect(tool.state == .outputAvailable)
        #expect(tool.input == ["city": "London"])
        #expect(tool.output == ["weather": "sunny"])
    }

    @Test func continuesAnExistingAssistantMessage() throws {
        let existing = UIMessage(id: "msg-123", role: .assistant, parts: [
            .stepStart,
            .tool(ToolPart(toolName: "approve", toolCallId: "call-1", state: .approvalResponded, input: ["id": "a"], approval: ToolApproval(id: "ap-1", approved: true))),
        ])
        let (state, _) = try run([
            .start(messageId: "msg-123"),
            .toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: "call-1", output: ["deleted": true])),
            .startStep,
            .textStart(id: "t"),
            .textDelta(id: "t", delta: "Deleted."),
            .textEnd(id: "t"),
        ], state: StreamingMessageState(continuing: existing))
        #expect(state.message.id == "msg-123")
        #expect(state.message.parts.map(\.type) == ["step-start", "tool-approve", "step-start", "text"])
        #expect(state.message.toolParts.first?.state == .outputAvailable)
        #expect(state.message.toolParts.first?.approval?.approved == true)
    }

    @Test func continuesToolInputThatWasStillStreaming() throws {
        let existing = UIMessage(id: "m", role: .assistant, parts: [
            .tool(ToolPart(toolName: "write", toolCallId: "c", state: .inputStreaming, input: ["path": "a"], rawInput: .string(#"{"path":"a"#))),
        ])
        var state = StreamingMessageState(continuing: existing)
        _ = try state.apply(.toolInputDelta(toolCallId: "c", inputTextDelta: #"bc"}"#))
        #expect(state.message.toolParts.first?.input == ["path": "abc"])
    }

    @Test func toolOutputErrorKeepsInput() throws {
        let (state, _) = try run([
            .startStep,
            .toolInputAvailable(ToolInputAvailableChunk(toolCallId: "c", toolName: "t", input: ["x": 1])),
            .toolOutputError(ToolOutputErrorChunk(toolCallId: "c", errorText: "boom")),
        ])
        let tool = try #require(state.message.toolParts.first)
        #expect(tool.state == .outputError)
        #expect(tool.errorText == "boom")
        #expect(tool.input == ["x": 1])
    }

    @Test func toolInputErrorUpdatesTheStreamedStaticPart() throws {
        let (state, _) = try run([
            .start(),
            .startStep,
            .toolInputStart(ToolInputStartChunk(toolCallId: "call-1", toolName: "nonExistentTool")),
            .toolInputDelta(toolCallId: "call-1", inputTextDelta: #"{ "foo": "bar" }"#),
            .toolInputError(ToolInputErrorChunk(
                toolCallId: "call-1",
                toolName: "nonExistentTool",
                input: .string(#"{ "foo": "bar" }"#),
                errorText: "Model tried to call unavailable tool 'nonExistentTool'.",
                dynamic: true
            )),
            .toolOutputError(ToolOutputErrorChunk(toolCallId: "call-1", errorText: "Model tried to call unavailable tool 'nonExistentTool'.")),
            .finishStep,
            .finish(),
        ])
        #expect(state.message.toolParts.count == 1)
        let tool = try #require(state.message.toolParts.first)
        #expect(tool.type == "tool-nonExistentTool")
        #expect(tool.state == .outputError)
        #expect(tool.input == .string(#"{ "foo": "bar" }"#))
        #expect(tool.rawInput == nil)
    }

    @Test func providerExecutedToolsDoNotAskTheClient() throws {
        let (state, updates) = try run([
            .startStep,
            .toolInputStart(ToolInputStartChunk(toolCallId: "s1", toolName: "web_search", providerExecuted: true, providerMetadata: ["anthropic": ["a": 1]])),
            .toolInputAvailable(ToolInputAvailableChunk(toolCallId: "s1", toolName: "web_search", input: ["query": "x"], providerExecuted: true)),
            .toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: "s1", output: ["results": []], providerExecuted: true, providerMetadata: ["anthropic": ["b": 2]])),
        ])
        #expect(updates.allSatisfy { $0.toolCall == nil })
        let tool = try #require(state.message.toolParts.first)
        #expect(tool.providerExecuted == true)
        #expect(tool.callProviderMetadata == ["anthropic": ["a": 1]])
        #expect(tool.resultProviderMetadata == ["anthropic": ["b": 2]])
    }

    @Test func dynamicToolsKeepTheirName() throws {
        let (state, updates) = try run([
            .toolInputStart(ToolInputStartChunk(toolCallId: "d", toolName: "mcp_lookup", dynamic: true, title: "Lookup")),
            .toolInputAvailable(ToolInputAvailableChunk(toolCallId: "d", toolName: "mcp_lookup", input: ["q": "a"], dynamic: true)),
            .toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: "d", output: "found", dynamic: true)),
        ])
        #expect(updates.compactMap(\.toolCall).first?.dynamic == true)
        let tool = try #require(state.message.toolParts.first)
        #expect(tool.isDynamic)
        #expect(tool.type == "dynamic-tool")
        #expect(tool.title == "Lookup")
        #expect(tool.output == "found")
    }

    @Test func preliminaryOutputsAreReplaced() throws {
        let (state, _) = try run([
            .toolInputAvailable(ToolInputAvailableChunk(toolCallId: "c", toolName: "t", input: [:])),
            .toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: "c", output: ["progress": 50], preliminary: true)),
            .toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: "c", output: ["progress": 100])),
        ])
        let tool = try #require(state.message.toolParts.first)
        #expect(tool.output == ["progress": 100])
        #expect(tool.preliminary == nil)
    }

    @Test func approvalRequestResponseAndDenial() throws {
        var (state, _) = try run([
            .toolInputAvailable(ToolInputAvailableChunk(toolCallId: "c1", toolName: "delete", input: [:])),
            .toolApprovalRequest(ToolApprovalRequestChunk(approvalId: "a1", toolCallId: "c1", approvalDescriptor: ["action": "delete"], reason: "Destructive", isAutomatic: false)),
        ])
        var tool = try #require(state.message.toolParts.first)
        #expect(tool.approval == ToolApproval(id: "a1", descriptor: ["action": "delete"], requestReason: "Destructive"))
        _ = try state.apply(.toolApprovalResponse(ToolApprovalResponseChunk(approvalId: "a1", approved: false, reason: "No")))
        tool = try #require(state.message.toolParts.first)
        #expect(tool.state == .approvalResponded)
        #expect(tool.approval?.approved == false)
        #expect(tool.approval?.reason == "No")
        _ = try state.apply(.toolOutputDenied(toolCallId: "c1"))
        #expect(state.message.toolParts.first?.state == .outputDenied)
    }

    @Test func dataPartsWithIDsAreReplaced() throws {
        let (state, updates) = try run([
            .start(messageId: "msg-123"),
            .startStep,
            .data(DataChunk(name: "test", data: ["a": "a1", "b": "b1"], id: "data-part-id")),
            .data(DataChunk(name: "test", data: ["b": "b2", "c": "c2"], id: "data-part-id")),
            .data(DataChunk(name: "progress", data: 0.5, transient: true)),
            .finishStep,
            .finish(),
        ])
        #expect(state.message.parts == [.stepStart, .data(DataPart(name: "test", data: ["b": "b2", "c": "c2"], id: "data-part-id"))])
        #expect(updates.compactMap(\.data).map(\.name) == ["test", "test", "progress"])
        #expect(updates[4].messageChanged == false)
    }

    @Test func sourcesAndFilesAreAppended() throws {
        let (state, _) = try run([
            .sourceURL(SourceURLPart(sourceId: "s1", url: "https://example.com", title: "Example")),
            .sourceDocument(SourceDocumentPart(sourceId: "s2", mediaType: "application/pdf", title: "Doc")),
            .file(url: "https://example.com/a.png", mediaType: "image/png", providerMetadata: ["p": 1]),
            .reasoningFile(url: "https://example.com/r.png", mediaType: "image/png"),
            .custom(kind: "openai.compaction"),
        ])
        #expect(state.message.parts.map(\.type) == ["source-url", "source-document", "file", "reasoning-file", "custom"])
        #expect(state.message.fileParts.first?.providerMetadata == ["p": 1])
    }

    @Test func textEndCarriesCitations() throws {
        let citation = TextCitation(source: .url(SourceURLPart(sourceId: "1", url: "https://a.com")), startIndex: 0, endIndex: 5, citedText: "Hello")
        let (state, _) = try run([.textStart(id: "t"), .textDelta(id: "t", delta: "Hello"), .textEnd(id: "t", citations: [citation])])
        #expect(state.message.parts.first?.textPart?.citations == [citation])
    }

    @Test func errorChunksAreReported() throws {
        let (_, updates) = try run([.start(), .error(errorText: "Gateway provider error: boom")])
        #expect(updates.last?.streamError == "Gateway provider error: boom")
    }

    @Test func providerMetadataUpdatesOnDeltasAndEnd() throws {
        let (state, _) = try run([
            .reasoningStart(id: "r"),
            .reasoningDelta(id: "r", delta: "think"),
            .reasoningDelta(id: "r", delta: "", providerMetadata: ["anthropic": ["signature": "sig"]]),
            .reasoningEnd(id: "r"),
        ])
        #expect(state.message.parts.first?.reasoningPart?.providerMetadata == ["anthropic": ["signature": "sig"]])
    }

    @Test func lenientModeOpensMissingParts() throws {
        let (state, _) = try run([
            .textDelta(id: "t", delta: "Hi"),
            .textEnd(id: "missing"),
            .toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: "unknown", output: 1)),
            .toolInputDelta(toolCallId: "unknown", inputTextDelta: "{"),
        ])
        #expect(state.message.parts == [.text(TextPart(text: "Hi", state: .streaming))])
    }

    @Test(arguments: [
        UIMessageChunk.textDelta(id: "t", delta: "x"),
        .textEnd(id: "t"),
        .reasoningDelta(id: "r", delta: "x"),
        .reasoningEnd(id: "r"),
        .toolInputDelta(toolCallId: "c", inputTextDelta: "{"),
        .toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: "c", output: 1)),
        .toolApprovalResponse(ToolApprovalResponseChunk(approvalId: "a", approved: true)),
    ])
    func strictModeRejectsChunksForMissingParts(chunk: UIMessageChunk) {
        var state = StreamingMessageState(messageID: "m", strict: true)
        #expect(throws: ChatError.self) { _ = try state.apply(chunk) }
    }

    @Test func replayResetsOnTheFirstStart() throws {
        let existing = UIMessage(id: "msg-123", role: .assistant, parts: [.text(TextPart(text: "old text", state: .streaming))], metadata: ["stale": true])
        var state = StreamingMessageState(continuing: existing, resumeBehavior: .init(resetsOnFirstStart: true, resetsOnMessageIDChange: true))
        for chunk: UIMessageChunk in [
            .start(messageId: "msg-123"),
            .startStep,
            .textStart(id: "text-1"),
            .textDelta(id: "text-1", delta: "Hello"),
            .start(messageId: "msg-123", messageMetadata: ["fresh": true]),
            .textDelta(id: "text-1", delta: " world!"),
            .textEnd(id: "text-1"),
        ] {
            _ = try state.apply(chunk)
        }
        #expect(state.message == UIMessage(id: "msg-123", role: .assistant, parts: [.stepStart, .text(TextPart(text: "Hello world!", state: .done))], metadata: ["fresh": true]))
    }

    @Test func resumeStartsOverForADifferentMessage() throws {
        let existing = UIMessage(id: "old", role: .assistant, parts: [.text(TextPart(text: "partial", state: .streaming))])
        var state = StreamingMessageState(continuing: existing, resumeBehavior: .init(resetsOnMessageIDChange: true))
        _ = try state.apply(.start(messageId: "new"))
        #expect(state.message.id == "new")
        #expect(state.message.parts.isEmpty)
    }
}
