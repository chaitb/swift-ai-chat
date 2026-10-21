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
                    var body: [String: JSONValue] = ["messages": .array(request.messages.suffix(1).map(\.jsonValue))]
                    if let threadID { body["threadId"] = .string(threadID) }
                    prepared.body = .object(body)
                    if let flow = request.metadata?["flow"]?.stringValue {
                        var components = URLComponents(url: prepared.url, resolvingAgainstBaseURL: false)!
                        components.queryItems = [URLQueryItem(name: "flow", value: flow)]
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
