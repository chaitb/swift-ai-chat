import AIChat
import AIChatTesting
import Foundation
import Testing

/// Replays streams recorded from the Baseline API (`POST /api/chat`, AI SDK 6 on
/// Cloudflare Workers) and checks the requests the package sends match the ones
/// the server accepted.
@MainActor
@Suite("Baseline API compatibility")
struct BaselineCompatibilityTests {
    /// Baseline keeps the history on the server: clients send only the newest message
    /// and the thread id, and learn the thread id from the `X-Thread-Id` header.
    final class BaselineSession: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        var threadID: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }

        func transport(httpClient: any HTTPStreamingClient) -> AISDKChatTransport {
            AISDKChatTransport(
                api: URL(string: "https://baseline.test/api/chat")!,
                httpClient: httpClient,
                prepareSendMessagesRequest: { [self] request, prepared in
                    var prepared = prepared
                    let flow = request.metadata?["flow"]?.stringValue
                    let continued = request.messageID.flatMap { id in request.messages.last { $0.id == id } }
                    let sent = flow == nil ? (continued ?? request.messages.last).map { [$0.jsonValue] } ?? [] : []
                    var body: [String: JSONValue] = ["messages": .array(sent)]
                    if let threadID { body["threadId"] = .string(threadID) }
                    prepared.body = .object(body)
                    if let flow {
                        var components = URLComponents(url: prepared.url, resolvingAgainstBaseURL: false)!
                        var query = [URLQueryItem(name: "flow", value: flow)]
                        if let flowID = request.metadata?["flowId"]?.stringValue {
                            query.append(URLQueryItem(name: "flow_id", value: flowID))
                        }
                        components.queryItems = query
                        prepared.url = components.url!
                    }
                    return prepared
                },
                onResponse: { [self] head in
                    if let id = head.header("X-Thread-Id"), !id.isEmpty { threadID = id }
                }
            )
        }
    }

    private func stub(_ name: String, chunkSize: Int = 97) throws -> StubHTTPClient.Stub {
        try Self.recordedStub(name, chunkSize: chunkSize)
    }

    nonisolated static func recordedStub(_ name: String, chunkSize: Int = 97) throws -> StubHTTPClient.Stub {
        let meta = try Fixtures.json("baseline/\(name).meta.json")
        var headers: [String: String] = [:]
        for (key, value) in meta["headers"]?.objectValue ?? [:] { headers[key] = value.stringValue }
        return StubHTTPClient.Stub(
            statusCode: meta["status"]?.intValue ?? 200,
            headers: headers,
            chunks: split(try Fixtures.data("baseline/\(name).sse"), size: chunkSize)
        )
    }

    private func split(_ data: Data, size: Int) -> [Data] {
        Self.split(data, size: size)
    }

    nonisolated static func split(_ data: Data, size: Int) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
    }

    private func recordedRequestBody(_ name: String) throws -> JSONValue {
        try #require(try Fixtures.json("baseline/\(name).meta.json")["request"]?["body"])
    }

    @Test(arguments: ["text-reply", "follow-up", "tool-call", "tool-approval", "tool-approval-continue", "survey", "onboarding-flow", "provider-error", "keep-alive"])
    func decodesEveryRecordedStream(name: String) throws {
        let chunks = try Fixtures.chunks("baseline/\(name).sse")
        #expect(!chunks.isEmpty)
        #expect(!chunks.contains { if case .unknown = $0 { true } else { false } })
        for chunk in chunks {
            let reencoded = try UIMessageChunk(jsonObject: chunk.jsonObject)
            #expect(reencoded == chunk)
        }
    }

    @Test func textReplyBuildsOneTextPart() async throws {
        let session = BaselineSession()
        let http = StubHTTPClient([try stub("text-reply")])
        let chat = Chat(transport: session.transport(httpClient: http))
        await chat.sendMessage("How much sleep do I need?")

        #expect(chat.status == .ready)
        let reply = try #require(chat.messages.last)
        #expect(reply.role == .assistant)
        #expect(!reply.text.isEmpty)
        #expect(reply.metadata?["threadId"]?.stringValue == session.threadID)
        #expect(reply.id == reply.metadata?["messageId"]?.stringValue)
        #expect(session.threadID == "5425b0e7-1254-4b7f-874e-5f6c0dc14fad")

        let sent = try #require(http.requestBodies.first)
        let recorded = try recordedRequestBody("text-reply")
        #expect(sent["messages"]?[0]?["role"] == recorded["messages"]?[0]?["role"])
        #expect(sent["messages"]?[0]?["parts"] == recorded["messages"]?[0]?["parts"])
        #expect(sent.objectValue?.keys.sorted() == ["messages"])
    }

    @Test func followUpSendsTheThreadID() async throws {
        let session = BaselineSession()
        let http = StubHTTPClient([try stub("text-reply"), try stub("follow-up")])
        let chat = Chat(transport: session.transport(httpClient: http))
        await chat.sendMessage("How much sleep do I need?")
        await chat.sendMessage("Any tips?")

        let second = try #require(http.requestBodies.last)
        #expect(second["threadId"] == .string("5425b0e7-1254-4b7f-874e-5f6c0dc14fad"))
        #expect(second["messages"]?.arrayValue?.count == 1)
        #expect(second["messages"]?[0]?["role"] == "user")
        #expect(chat.messages.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    @Test func toolCallStreamsBecomeStepsWithToolParts() async throws {
        let chat = Chat(transport: BaselineSession().transport(httpClient: StubHTTPClient([try stub("tool-call", chunkSize: 13)])))
        await chat.sendMessage("What did I eat today?")

        let reply = try #require(chat.messages.last)
        #expect(reply.parts.map(\.type) == ["step-start", "tool-loadTools", "step-start", "tool-user.foodLog.listByDate", "step-start", "text"])
        let load = try #require(reply.toolPart(callID: "call-1-0"))
        #expect(load.state == .outputAvailable)
        #expect(load.input == ["namespace": "user", "dataset": "foodLog"])
        let list = try #require(reply.toolPart(callID: "call-2-0"))
        #expect(list.state == .outputAvailable)
        #expect(list.output?["entries"] == [])
        #expect(!reply.text.isEmpty)
    }

    @Test func approvalRoundTripMatchesTheRequestTheServerAccepted() async throws {
        let session = BaselineSession()
        let http = StubHTTPClient([try stub("tool-approval"), try stub("tool-approval-continue")])
        let chat = Chat(
            transport: session.transport(httpClient: http),
            configuration: ChatConfiguration(sendAutomaticallyWhen: .lastAssistantMessageIsCompleteWithApprovalResponses)
        )
        await chat.sendMessage("Remove the Greek yogurt")

        let pending = try #require(chat.messages.last)
        #expect(pending.id == "76ed2042-c1b8-475e-8278-d3b7f538e378")
        let delete = try #require(pending.toolPart(callID: "call-2-0"))
        #expect(delete.toolName == "user.foodLog.deleteItem")
        #expect(delete.state == .approvalRequested)
        #expect(pending.toolParts.count == 2)

        await chat.addToolApprovalResponse(approvalID: try #require(delete.approval?.id), approved: true)

        let continuation = try #require(http.requestBodies.last)
        let accepted = try recordedRequestBody("tool-approval-continue")
        var sentMessage = try #require(continuation["messages"]?[0]?.objectValue)
        let metadata = sentMessage.removeValue(forKey: "metadata")
        #expect(JSONValue.object(sentMessage) == accepted["messages"]?[0])
        #expect(continuation["threadId"] == accepted["threadId"])
        let metadataKeys = Set(metadata?.objectValue.map { Array($0.keys) } ?? [])
        #expect(metadataKeys.isSubset(of: ["messageId", "threadId", "model", "provider", "feedback", "hidden"]))

        let reply = try #require(chat.messages.last)
        #expect(chat.messages.count == 2)
        #expect(reply.id == pending.id)
        #expect(reply.toolPart(callID: "call-2-0")?.state == .outputAvailable)
        #expect(reply.toolPart(callID: "call-2-0")?.approval?.approved == true)
        #expect(!reply.text.isEmpty)
    }

    @Test func surveyWaitsForTheAppToAnswer() async throws {
        var calls: [ToolCall] = []
        let chat = Chat(
            transport: BaselineSession().transport(httpClient: StubHTTPClient([try stub("survey")])),
            configuration: ChatConfiguration(onToolCall: { calls.append($0) })
        )
        await chat.sendMessage("Help me set goals")
        #expect(calls.map(\.toolName) == ["user.survey.ask"])
        #expect(chat.messages.last?.toolParts.last?.state == .inputAvailable)
        #expect(chat.status == .ready)
    }

    @Test func onboardingFlowStartsWithNoMessages() async throws {
        let session = BaselineSession()
        let http = StubHTTPClient([try stub("onboarding-flow")])
        let chat = Chat(transport: session.transport(httpClient: http))
        await chat.submit(options: ChatRequestOptions(metadata: ["flow": "onboarding"]))

        let request = try #require(http.requests.first)
        #expect(request.url?.query == "flow=onboarding")
        let recorded = try recordedRequestBody("onboarding-flow")
        #expect(http.requestBodies.first == recorded)
        #expect(chat.messages.count == 1)
        #expect(chat.messages[0].role == .assistant)
        #expect(session.threadID == "2531b0a5-cebf-4bf1-87da-941caf53f7f7")
    }

    @Test func keepAliveCommentsAreSkipped() async throws {
        let chat = Chat(transport: BaselineSession().transport(httpClient: StubHTTPClient([try stub("keep-alive", chunkSize: 5)])))
        await chat.sendMessage("Hi")
        #expect(chat.status == .ready)
        #expect(!(chat.messages.last?.text.isEmpty ?? true))
    }

    @Test func providerErrorsEndInTheErrorState() async throws {
        let chat = Chat(transport: BaselineSession().transport(httpClient: StubHTTPClient([try stub("provider-error")])))
        await chat.sendMessage("Hi")
        #expect(chat.status == .error)
        #expect(chat.error?.message == "Gateway provider error: boom")
    }

    @Test func consentErrorsKeepTheServerFailure() async throws {
        let chat = Chat(transport: BaselineSession().transport(httpClient: StubHTTPClient([try stub("consent-required")])))
        await chat.sendMessage("Hi")
        let error = try #require(chat.error)
        #expect(error.kind == .http)
        #expect(error.statusCode == 403)
        #expect(error.message == "AI processing is disabled in Privacy settings")
        #expect(error.code == "ai_processing_consent_required")
        #expect(error.requestID == "544a1888-ddb8-4f6f-b546-b044df1ebb37")
        #expect(!error.isRetryable)
    }

    @Test func invalidInputErrorsReadTheErrorField() async throws {
        let chat = Chat(transport: BaselineSession().transport(httpClient: StubHTTPClient([try stub("error-invalid-input")])))
        await chat.sendMessage("Hi")
        #expect(chat.error?.message == "invalid chat input")
        #expect(chat.error?.statusCode == 400)
    }

    /// Since #371 the workout analysis runs in the main thread, which usually ends with a
    /// reply. The server answers the flow with a new message, so it must not merge into it.
    @Test func workoutFlowInTheMainThreadAddsANewReply() async throws {
        let session = BaselineSession()
        session.threadID = "2531b0a5-cebf-4bf1-87da-941caf53f7f7"
        let http = StubHTTPClient([try stub("onboarding-flow")])
        let earlier = UIMessage.assistant("Your squat volume is up 8% this week.", id: "6f0c1d2e-8a8b-4c4d-9e9f-0a1b2c3d4e5f")
        let chat = Chat(messages: [.user("How was my week?", id: "u1"), earlier], transport: session.transport(httpClient: http))
        await chat.submit(options: ChatRequestOptions(metadata: ["flow": "workout", "flowId": "9b1f0e2a-3c4d-4e5f-8a9b-0c1d2e3f4a5b"]))

        let request = try #require(http.requests.first)
        #expect(request.url?.query == "flow=workout&flow_id=9b1f0e2a-3c4d-4e5f-8a9b-0c1d2e3f4a5b")
        #expect(http.requestBodies.first == ["messages": [], "threadId": "2531b0a5-cebf-4bf1-87da-941caf53f7f7"])
        #expect(chat.status == .ready)
        #expect(chat.messages.map(\.id) == ["u1", earlier.id, "1fb0091b-2648-4d39-ae1c-558f07edb477"])
        #expect(chat.messages[1] == earlier)
        #expect(!(chat.messages.last?.text.isEmpty ?? true))
    }

    @Test func answeringTheSurveySendsTheReplyBackToContinueIt() async throws {
        let session = BaselineSession()
        session.threadID = "5425b0e7-1254-4b7f-874e-5f6c0dc14fad"
        let requestCount = Counter()
        let http = StubHTTPClient(handler: { request in
            if requestCount.next() == 1 {
                return try BaselineCompatibilityTests.recordedStub("survey")
            }
            let body = try JSONValue(parsing: request.httpBody ?? Data())
            let replyID = body["messages"]?[0]?["id"]?.stringValue ?? "missing"
            return .eventStream(try UIMessageStream.encode(.textResponse("Saved your goals.", messageId: replyID)))
        })
        var calls: [ToolCall] = []
        let chat = Chat(transport: session.transport(httpClient: http), configuration: ChatConfiguration(
            sendAutomaticallyWhen: .any(.lastAssistantMessageIsCompleteWithToolCalls, .lastAssistantMessageIsCompleteWithApprovalResponses),
            onToolCall: { calls.append($0) }
        ))
        await chat.sendMessage("Help me set goals")
        let survey = try #require(calls.first { $0.toolName == "user.survey.ask" })
        let pending = try #require(chat.messages.last)
        #expect(http.requests.count == 1)

        let answer: JSONValue = ["answers": [["questionId": "goal", "value": "Lose fat"]]]
        await chat.addToolOutput(toolCallId: survey.toolCallId, output: answer)

        #expect(http.requests.count == 2)
        let body = try #require(http.requestBodies.last)
        #expect(body.objectValue?.keys.sorted() == ["messages", "threadId"])
        let sent = try #require(body["messages"]?.arrayValue)
        #expect(sent.count == 1)
        #expect(sent[0]["id"] == .string(pending.id))
        #expect(sent[0]["role"] == "assistant")
        let sentSurvey = sent[0]["parts"]?.arrayValue?.first { $0["toolCallId"] == .string(survey.toolCallId) }
        #expect(sentSurvey?["state"] == "output-available")
        #expect(sentSurvey?["output"] == answer)
        #expect(chat.messages.count == 2)
        #expect(chat.messages.last?.id == pending.id)
        #expect(chat.messages.last?.text.hasSuffix("Saved your goals.") == true)
        #expect(chat.status == .ready)
    }

    @Test func anApprovalAnsweredAfterTheConversationMovedOnContinuesThatReply() async throws {
        let session = BaselineSession()
        let http = StubHTTPClient([try stub("tool-approval"), try stub("text-reply"), try stub("tool-approval-continue")])
        let chat = Chat(transport: session.transport(httpClient: http), configuration: ChatConfiguration(sendAutomaticallyWhen: .never))
        await chat.sendMessage("Remove the Greek yogurt")
        let pending = try #require(chat.messages.last)
        let delete = try #require(pending.toolPart(callID: "call-2-0"))
        await chat.sendMessage("How much sleep do I need?")
        let later = try #require(chat.messages.last)
        #expect(later.id != pending.id)

        await chat.addToolApprovalResponse(approvalID: try #require(delete.approval?.id), approved: true)
        #expect(http.requests.count == 2)
        await chat.submit(continuing: pending.id)

        #expect(http.requests.count == 3)
        let sent = try #require(http.requestBodies.last?["messages"]?.arrayValue)
        #expect(sent.count == 1)
        #expect(sent.first?["id"] == .string(pending.id))
        let sentDelete = sent.first?["parts"]?.arrayValue?.first { $0["toolCallId"] == "call-2-0" }
        #expect(sentDelete?["state"] == "approval-responded")
        #expect(chat.messages.count == 4)
        #expect(chat.messages[1].id == pending.id)
        #expect(chat.messages[1].toolPart(callID: "call-2-0")?.state == .outputAvailable)
        #expect(chat.messages[1].text.count > pending.text.count)
        #expect(chat.messages.last == later)
        #expect(chat.status == .ready)
    }

    /// The server keeps generating after a disconnect and saves the reply, and has no
    /// resume endpoint, so the app recovers a dropped reply from the saved transcript.
    struct SavedTranscriptTransport: ChatTransport {
        let base: AISDKChatTransport
        let session: BaselineSession
        let savedMessages: @Sendable (_ threadID: String) async throws -> [UIMessage]

        var resumeStreamIsReplay: Bool { true }

        func sendMessages(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream {
            try await base.sendMessages(request)
        }

        func reconnectToStream(_ request: ChatReconnectRequest) async throws -> UIMessageChunkStream? {
            guard let threadID = session.threadID, let replyID = request.messageID else { return nil }
            for _ in 0..<5 {
                if let saved = try await savedMessages(threadID).first(where: { $0.id == replyID }) {
                    return UIMessageStream.replaying(saved, finishReason: .stop)
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            return nil
        }
    }

    @Test func aDroppedReplyIsRecoveredFromTheSavedTranscript() async throws {
        var finished = StreamingMessageState(messageID: "unsaved")
        for chunk in try Fixtures.chunks("baseline/tool-call.sse") { _ = try finished.apply(chunk) }
        let saved = finished.message

        let sse = try Fixtures.data("baseline/tool-call.sse")
        let events = String(decoding: sse, as: UTF8.self).components(separatedBy: "\n\n")
        let delivered = Data((events.prefix(events.count / 2).joined(separator: "\n\n") + "\n\n").utf8)
        var cut = try stub("tool-call")
        cut.chunks = split(delivered, size: 97)
        cut.failure = ChatError(kind: .network, message: "The network connection was lost.")

        let session = BaselineSession()
        let polls = Counter()
        let transport = SavedTranscriptTransport(
            base: session.transport(httpClient: StubHTTPClient([cut])),
            session: session,
            savedMessages: { _ in polls.next() < 3 ? [] : [saved] }
        )
        var reported: [String] = []
        let chat = Chat(transport: transport, configuration: ChatConfiguration(
            onToolOutput: { reported.append($0.toolName) },
            resumePolicy: ResumePolicy(attempts: 1, initialDelay: .milliseconds(1))
        ))
        await chat.sendMessage("What did I eat today?")

        #expect(chat.status == .ready)
        #expect(chat.error == nil)
        #expect(chat.messages.count == 2)
        #expect(chat.messages.last == saved)
        #expect(reported == ["loadTools", "user.foodLog.listByDate"])
    }

    @Test func toolOutputsReachTheAppAsTheyFinish() async throws {
        var reported: [String] = []
        let chat = Chat(
            transport: BaselineSession().transport(httpClient: StubHTTPClient([try stub("tool-call", chunkSize: 13)])),
            configuration: ChatConfiguration(onToolOutput: { reported.append($0.toolName) })
        )
        await chat.sendMessage("What did I eat today?")
        #expect(reported == ["loadTools", "user.foodLog.listByDate"])
    }

    @Test func replayingAStoredReplyRebuildsIt() async throws {
        let chat = Chat(transport: BaselineSession().transport(httpClient: StubHTTPClient([try stub("tool-call")])))
        await chat.sendMessage("What did I eat today?")
        let reply = try #require(chat.messages.last)

        var state = StreamingMessageState(messageID: "placeholder")
        var toolCalls: [ToolCall] = []
        for chunk in reply.replayChunks(finishReason: .stop) {
            if let call = try state.apply(chunk).toolCall { toolCalls.append(call) }
        }
        #expect(state.message == reply)
        #expect(toolCalls.isEmpty)
    }
}
