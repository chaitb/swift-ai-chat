import AIChat
import AIChatTesting
import Foundation
import Testing

@MainActor
@Suite("Chat")
struct ChatTests {
    private func sequentialIDs() -> @Sendable () -> String {
        let counter = Counter()
        return { "id-\(counter.next())" }
    }

    @Test func sendsAMessageAndStreamsTheReply() async throws {
        let transport = MockChatTransport(responses: [.chunks(.textResponse("Hi there", messageId: "server-1"))])
        let chat = Chat(id: "chat-1", transport: transport)
        await chat.sendMessage("Hello")

        #expect(chat.status == .ready)
        #expect(chat.messages.count == 2)
        #expect(chat.messages[0].role == .user)
        #expect(chat.messages[0].text == "Hello")
        #expect(chat.messages[1].id == "server-1")
        #expect(chat.messages[1].text == "Hi there")
        let request = try #require(transport.requests.first)
        #expect(request.chatID == "chat-1")
        #expect(request.trigger == .submitMessage)
        #expect(request.messages.map(\.text) == ["Hello"])
    }

    @Test func movesThroughSubmittedAndStreaming() async throws {
        let transport = MockChatTransport(responses: [.chunks(.textResponse("One two three"), delay: .milliseconds(20))])
        let chat = Chat(transport: transport)
        let task = Task { await chat.sendMessage("Go") }
        try await waitUntil { chat.status == .streaming }
        await task.value
        #expect(chat.status == .ready)
    }

    @Test func sendsTheModelAndRequestOptions() async throws {
        let transport = MockChatTransport()
        let chat = Chat(modelID: "claude-opus-5-5", transport: transport, configuration: ChatConfiguration(
            requestOptions: ChatRequestOptions(headers: ["x-app": "1"], body: ["threadId": "t1"])
        ))
        await chat.sendMessage("Hi", options: ChatRequestOptions(headers: ["x-request": "2"], body: ["flow": "onboarding"], metadata: ["m": 1]))
        let request = try #require(transport.requests.first)
        #expect(request.modelID == "claude-opus-5-5")
        #expect(request.headers == ["x-app": "1", "x-request": "2"])
        #expect(request.body == ["threadId": "t1", "flow": "onboarding"])
        #expect(request.metadata == ["m": 1])

        await chat.sendMessage("Again", options: ChatRequestOptions(modelID: "claude-haiku-5-5"))
        #expect(transport.requests.last?.modelID == "claude-haiku-5-5")
    }

    @Test func stopKeepsTheStreamedText() async throws {
        let transport = MockChatTransport(responses: [.chunksThenHang([.start(messageId: "a"), .startStep, .textStart(id: "t"), .textDelta(id: "t", delta: "Partial")])])
        var finish: ChatFinishEvent?
        let chat = Chat(transport: transport, configuration: ChatConfiguration(onFinish: { finish = $0 }))
        let task = Task { await chat.sendMessage("Go") }
        try await waitUntil { chat.messages.last?.text == "Partial" }
        chat.stop()
        await task.value
        #expect(chat.status == .ready)
        #expect(chat.error == nil)
        #expect(chat.messages.last?.text == "Partial")
        #expect(finish?.isAbort == true)
        #expect(finish?.isError == false)
    }

    @Test func failuresSetTheErrorStatus() async throws {
        let failure = ChatError(kind: .http, message: "Overloaded", code: "overloaded_error", statusCode: 529)
        var reported: ChatError?
        let chat = Chat(transport: MockChatTransport(responses: [.failure(failure)]), configuration: ChatConfiguration(onError: { reported = $0 }))
        await chat.sendMessage("Hi")
        #expect(chat.status == .error)
        #expect(chat.error?.code == "overloaded_error")
        #expect(chat.error?.isRetryable == true)
        #expect(reported?.statusCode == 529)
        chat.clearError()
        #expect(chat.status == .ready)
        #expect(chat.error == nil)
    }

    @Test func errorChunksFailTheResponse() async throws {
        let chat = Chat(transport: MockChatTransport(responses: [.chunks([.start(), .error(errorText: "Gateway provider error: boom")])]))
        await chat.sendMessage("Hi")
        #expect(chat.status == .error)
        #expect(chat.error?.kind == .stream)
        #expect(chat.error?.message == "Gateway provider error: boom")
    }

    @Test func disconnectsAreFlagged() async throws {
        var finish: ChatFinishEvent?
        let drop = ChatError(kind: .network, message: "The network connection was lost.")
        let chat = Chat(
            transport: MockChatTransport(responses: [.chunksThenFailure([.start(), .startStep, .textStart(id: "t"), .textDelta(id: "t", delta: "Par")], drop)]),
            configuration: ChatConfiguration(onFinish: { finish = $0 })
        )
        await chat.sendMessage("Hi")
        #expect(chat.status == .error)
        #expect(finish?.isDisconnect == true)
        #expect(finish?.message.text == "Par")
    }

    @Test func regenerateReplacesTheLastAnswer() async throws {
        let transport = MockChatTransport(responses: [
            .chunks(.textResponse("First", messageId: "a1")),
            .chunks(.textResponse("Second", messageId: "a2")),
        ])
        let chat = Chat(transport: transport)
        await chat.sendMessage("Hi")
        await chat.regenerate()
        #expect(chat.messages.map(\.text) == ["Hi", "Second"])
        #expect(transport.requests.last?.trigger == .regenerateMessage)
        #expect(transport.requests.last?.messages.map(\.role) == [.user])
    }

    @Test func editingAUserMessageDropsWhatFollows() async throws {
        let transport = MockChatTransport(responses: [
            .chunks(.textResponse("Paris")),
            .chunks(.textResponse("Rome")),
        ])
        let chat = Chat(transport: transport)
        await chat.sendMessage("Capital of France?")
        let userID = chat.messages[0].id
        await chat.editMessage(userID, text: "Capital of Italy?")
        #expect(chat.messages.map(\.text) == ["Capital of Italy?", "Rome"])
        #expect(chat.messages[0].id == userID)
        #expect(transport.requests.last?.messageID == userID)
    }

    @Test func runsRegisteredToolsAndContinues() async throws {
        let transport = MockChatTransport(responses: [
            .chunks(.toolCallResponse(toolName: "getWeather", input: ["city": "Paris"], messageId: "a1")),
            .chunks([.start(messageId: "a1"), .startStep, .textStart(id: "t"), .textDelta(id: "t", delta: "It's 21°C."), .textEnd(id: "t"), .finishStep, .finish()]),
        ])
        let weather = ChatTool.typed(
            name: "getWeather",
            description: "Current weather",
            inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]
        ) { (input: WeatherInput) in WeatherOutput(city: input.city, celsius: 21) }
        let chat = Chat(transport: transport, configuration: ChatConfiguration(tools: [weather]))
        await chat.sendMessage("Weather in Paris?")
        try await waitUntil { transport.requests.count == 2 && chat.status == .ready }

        #expect(transport.requests.first?.tools.map(\.name) == ["getWeather"])
        let continuation = try #require(transport.requests.last)
        let sentTool = try #require(continuation.messages.last?.toolParts.first)
        #expect(sentTool.state == .outputAvailable)
        #expect(sentTool.output == ["city": "Paris", "celsius": 21])
        #expect(chat.messages.count == 2)
        #expect(chat.messages.last?.id == "a1")
        #expect(chat.messages.last?.parts.map(\.type) == ["step-start", "tool-getWeather", "step-start", "text"])
        #expect(chat.messages.last?.text == "It's 21°C.")
    }

    @Test func anEmptyReplyAfterAToolResultEndsTheLoop() async throws {
        let empty: [UIMessageChunk] = [.start(messageId: "a1"), .startStep, .finishStep, .finish()]
        let transport = MockChatTransport(responses: [
            .chunks(.toolCallResponse(toolName: "ping", input: [:], messageId: "a1")),
            .chunks(empty),
            .chunks(empty),
            .chunks(empty),
        ])
        let chat = Chat(transport: transport, configuration: ChatConfiguration(tools: [ChatTool(name: "ping") { _ in "pong" }]))
        await chat.sendMessage("Ping")
        try await waitUntil { transport.requests.count >= 2 && chat.status == .ready && !chat.isBusy }
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.requests.count == 2)
        #expect(chat.messages.last?.parts.map(\.type) == ["step-start", "tool-ping", "step-start"])
    }

    @Test func stopCancelsAnApprovedTool() async throws {
        let transport = MockChatTransport(responses: [
            .chunks(.toolCallResponse(toolName: "slow", input: [:], messageId: "a1")),
            .chunks(.textResponse("Done.", messageId: "a1")),
        ])
        let tool = ChatTool(name: "slow", needsApproval: true) { _ in
            try await Task.sleep(for: .seconds(5))
            return "finished"
        }
        let chat = Chat(transport: transport, configuration: ChatConfiguration(tools: [tool]))
        await chat.sendMessage("Run it")
        let approvalID = try #require(chat.messages.last?.toolParts.first?.approval?.id)
        let approving = Task { await chat.addToolApprovalResponse(approvalID: approvalID, approved: true) }
        try await waitUntil { chat.isBusy }
        chat.stop()
        await approving.value
        #expect(!chat.isBusy)
        #expect(transport.requests.count == 1)
        #expect(chat.messages.last?.toolParts.first?.state == .outputError)
        #expect(chat.messages.last?.toolParts.first?.isRunning == false)
    }

    @Test func toolErrorsBecomeOutputErrors() async throws {
        let transport = MockChatTransport(responses: [
            .chunks(.toolCallResponse(toolName: "fail", input: [:])),
            .chunks(.textResponse("Sorry")),
        ])
        let tool = ChatTool(name: "fail") { _ in throw ChatError(kind: .tool, message: "No signal") }
        let chat = Chat(transport: transport, configuration: ChatConfiguration(tools: [tool]))
        await chat.sendMessage("Try")
        try await waitUntil { transport.requests.count == 2 && chat.status == .ready }
        let part = try #require(transport.requests.last?.messages.last?.toolParts.first)
        #expect(part.state == .outputError)
        #expect(part.errorText == "No signal")
    }

    @Test func humanInTheLoopToolsWaitForTheApp() async throws {
        let transport = MockChatTransport(responses: [
            .chunks(.toolCallResponse(toolName: "askUser", input: ["question": "Size?"], messageId: "a1")),
            .chunks([.start(messageId: "a1"), .startStep, .textStart(id: "t"), .textDelta(id: "t", delta: "Large it is."), .textEnd(id: "t"), .finishStep, .finish()]),
        ])
        var calls: [ToolCall] = []
        let chat = Chat(transport: transport, configuration: ChatConfiguration(
            tools: [ChatTool(name: "askUser")],
            onToolCall: { calls.append($0) }
        ))
        await chat.sendMessage("Order a shirt")
        #expect(calls.map(\.toolName) == ["askUser"])
        #expect(transport.requests.count == 1)
        #expect(chat.messages.last?.toolParts.first?.state == .inputAvailable)

        await chat.addToolOutput(toolCallId: "call-1", output: ["answer": "Large"])
        #expect(transport.requests.count == 2)
        #expect(chat.messages.last?.text == "Large it is.")
    }

    @Test func toolsNeedingApprovalWaitForTheUser() async throws {
        let transport = MockChatTransport(responses: [
            .chunks(.toolCallResponse(toolName: "deleteFile", input: ["path": "a.txt"], messageId: "a1")),
            .chunks(.textResponse("Deleted.", messageId: "a1")),
            .chunks(.toolCallResponse(toolName: "deleteFile", toolCallId: "call-2", input: ["path": "b.txt"], messageId: "a2")),
            .chunks(.textResponse("Kept it.", messageId: "a2")),
        ])
        let deleted = Counter()
        let tool = ChatTool(name: "deleteFile", needsApproval: true) { _ in
            _ = deleted.next()
            return ["deleted": true]
        }
        let chat = Chat(transport: transport, configuration: ChatConfiguration(tools: [tool], generateID: sequentialIDs()))
        await chat.sendMessage("Delete a.txt")
        let pending = try #require(chat.messages.last?.toolParts.first)
        #expect(pending.state == .approvalRequested)
        let approvalID = try #require(pending.approval?.id)

        await chat.addToolApprovalResponse(approvalID: approvalID, approved: true)
        try await waitUntil { transport.requests.count == 2 && chat.status == .ready }
        #expect(deleted.value == 1)
        #expect(transport.requests[1].messages.last?.toolParts.first?.state == .outputAvailable)

        await chat.sendMessage("Delete b.txt")
        let second = try #require(chat.messages.last?.toolParts.first(where: { $0.toolCallId == "call-2" }))
        await chat.addToolApprovalResponse(approvalID: try #require(second.approval?.id), approved: false, reason: "Not that one")
        try await waitUntil { transport.requests.count == 4 && chat.status == .ready }
        #expect(deleted.value == 1)
        let denied = try #require(transport.requests[3].messages.last?.toolParts.first(where: { $0.toolCallId == "call-2" }))
        #expect(denied.state == .outputDenied)
        #expect(denied.approval?.approved == false)
        #expect(denied.approval?.reason == "Not that one")
    }

    @Test func serverApprovalsAreSentBackWithThePolicy() async throws {
        let request: [UIMessageChunk] = [
            .start(messageId: "a1"),
            .startStep,
            .toolInputAvailable(ToolInputAvailableChunk(toolCallId: "c1", toolName: "user.foodLog.deleteItem", input: ["log_item_id": "x"])),
            .toolApprovalRequest(ToolApprovalRequestChunk(approvalId: "ap-1", toolCallId: "c1")),
            .finishStep,
            .finish(finishReason: .toolCalls),
        ]
        let continuation: [UIMessageChunk] = [
            .start(messageId: "a1"),
            .toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: "c1", output: ["ok": true])),
            .startStep,
            .textStart(id: "t"),
            .textDelta(id: "t", delta: "Removed."),
            .textEnd(id: "t"),
            .finishStep,
            .finish(),
        ]
        let transport = MockChatTransport(responses: [.chunks(request), .chunks(continuation)])
        let chat = Chat(transport: transport, configuration: ChatConfiguration(sendAutomaticallyWhen: .lastAssistantMessageIsCompleteWithApprovalResponses))
        await chat.sendMessage("Remove the yogurt")
        await chat.addToolApprovalResponse(approvalID: "ap-1", approved: true)

        let sent = try #require(transport.requests.last?.messages.last)
        #expect(sent.id == "a1")
        #expect(sent.toolParts.first?.state == .approvalResponded)
        #expect(sent.toolParts.first?.approval == ToolApproval(id: "ap-1", approved: true))
        #expect(chat.messages.count == 2)
        #expect(chat.messages.last?.toolParts.first?.state == .outputAvailable)
        #expect(chat.messages.last?.text == "Removed.")
    }

    @Test func automaticSendsAreCapped() async throws {
        let transport = MockChatTransport(responses: (0..<10).map { index in
            .chunks(.toolCallResponse(toolName: "loop", toolCallId: "c\(index)", input: [:], messageId: "a"))
        })
        let chat = Chat(transport: transport, configuration: ChatConfiguration(
            tools: [ChatTool(name: "loop") { _ in "again" }],
            maxAutomaticSends: 3
        ))
        await chat.sendMessage("Go")
        try await waitUntil { transport.requests.count == 4 && chat.status == .ready }
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.requests.count == 4)
    }

    @Test func resumeDoesNothingWithoutAnActiveStream() async throws {
        let transport = MockChatTransport(reconnectResponses: [nil])
        let chat = Chat(messages: [.user("Hi")], transport: transport)
        await chat.resumeStream()
        #expect(chat.status == .ready)
        #expect(chat.messages.count == 1)
        #expect(transport.reconnectRequests.count == 1)
    }

    @Test func resumeStreamsTheActiveResponse() async throws {
        let transport = MockChatTransport(reconnectResponses: [.chunks(.textResponse("Resumed answer", messageId: "a1"))], resumeStreamIsReplay: true)
        let chat = Chat(messages: [.user("Hi")], transport: transport)
        await chat.resumeStream()
        #expect(chat.messages.map(\.text) == ["Hi", "Resumed answer"])
        #expect(chat.messages.last?.id == "a1")
    }

    @Test func replayingResumeReplacesThePartialMessage() async throws {
        let partial = UIMessage(id: "a1", role: .assistant, parts: [.stepStart, .text(TextPart(text: "Resumed", state: .streaming))])
        let transport = MockChatTransport(reconnectResponses: [.chunks(.textResponse("Resumed answer", messageId: "a1"))], resumeStreamIsReplay: true)
        let chat = Chat(messages: [.user("Hi"), partial], transport: transport)
        await chat.resumeStream()
        #expect(chat.messages.map(\.text) == ["Hi", "Resumed answer"])
    }

    @Test func reconnectsAfterADisconnect() async throws {
        let drop = ChatError(kind: .network, message: "The network connection was lost.")
        let transport = MockChatTransport(
            responses: [.chunksThenFailure([.start(messageId: "a1"), .startStep, .textStart(id: "t"), .textDelta(id: "t", delta: "Hel")], drop)],
            reconnectResponses: [.chunks(.textResponse("Hello world", messageId: "a1"))],
            resumeStreamIsReplay: true
        )
        let chat = Chat(transport: transport, configuration: ChatConfiguration(resumePolicy: ResumePolicy(attempts: 2, initialDelay: .milliseconds(1))))
        await chat.sendMessage("Hi")
        #expect(chat.status == .ready)
        #expect(chat.messages.map(\.text) == ["Hi", "Hello world"])
    }

    @Test func continuingResumeKeepsWhatAlreadyStreamed() async throws {
        let drop = ChatError(kind: .network, message: "Lost")
        let transport = MockChatTransport(
            responses: [.chunksThenFailure([.start(messageId: "a1"), .startStep, .textStart(id: "t"), .textDelta(id: "t", delta: "Hel")], drop)],
            reconnectResponses: [.chunks([.textDelta(id: "t", delta: "lo"), .textEnd(id: "t"), .finishStep, .finish()])],
            resumeStreamIsReplay: false
        )
        let chat = Chat(transport: transport)
        await chat.sendMessage("Hi")
        #expect(chat.status == .error)
        await chat.resumeStream()
        #expect(chat.status == .ready)
        #expect(chat.messages.map(\.text) == ["Hi", "Hello"])
    }

    @Test func transientDataGoesToOnData() async throws {
        var received: [DataChunk] = []
        let chat = Chat(
            transport: MockChatTransport(responses: [.chunks([.start(), .data(DataChunk(name: "status", data: "thinking", transient: true)), .finish()])]),
            configuration: ChatConfiguration(onData: { received.append($0) })
        )
        await chat.sendMessage("Hi")
        #expect(received.map(\.data) == ["thinking"])
        #expect(chat.messages.last?.role == .user)
    }

    @Test func throttlesUpdatesButKeepsTheFinalText() async throws {
        let words = (1...50).map { "w\($0) " }.joined()
        let transport = MockChatTransport(responses: [.chunks(.textResponse(words), delay: .milliseconds(1))])
        let chat = Chat(transport: transport, configuration: ChatConfiguration(updateInterval: .milliseconds(40)))
        await chat.sendMessage("Go")
        #expect(chat.messages.last?.text == words)
    }

    @Test func savesToTheStore() async throws {
        let store = InMemoryChatStore()
        let chat = Chat(id: "saved", modelID: "m1", transport: MockChatTransport(responses: [.chunks(.textResponse("Stored reply"))]), configuration: ChatConfiguration(store: store))
        await chat.sendMessage("Remember this conversation")
        await chat.waitForPendingSaves()
        let snapshot = try #require(try await store.loadChat(id: "saved"))
        #expect(snapshot.messages.map(\.text) == ["Remember this conversation", "Stored reply"])
        #expect(snapshot.modelID == "m1")
        #expect(snapshot.title == "Remember this conversation")

        let restored = try await Chat.restore(id: "saved", transport: MockChatTransport(), configuration: ChatConfiguration(store: store))
        #expect(restored.messages == chat.messages)
        #expect(restored.modelID == "m1")
        #expect(try await store.listChats().map(\.id) == ["saved"])
    }

    @Test func sendingWhileStreamingStopsTheOldResponse() async throws {
        let transport = MockChatTransport(responses: [
            .chunksThenHang([.start(messageId: "a1"), .startStep, .textStart(id: "t"), .textDelta(id: "t", delta: "Long")]),
            .chunks(.textResponse("Short", messageId: "a2")),
        ])
        let chat = Chat(transport: transport)
        let first = Task { await chat.sendMessage("First") }
        try await waitUntil { chat.messages.last?.text == "Long" }
        await chat.sendMessage("Second")
        await first.value
        #expect(chat.messages.map(\.text) == ["First", "Long", "Second", "Short"])
        #expect(chat.status == .ready)
    }
}

struct WeatherInput: Codable, Sendable { let city: String }
struct WeatherOutput: Codable, Sendable { let city: String; let celsius: Int }

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int { lock.withLock { count } }
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
