import AIChat
import AIChatTesting
import Foundation
import Testing

@MainActor
@Suite("Transports")
struct TransportTests {
    private let api = URL(string: "https://example.com/api/chat")!

    @Test func aiSDKTransportSendsTheDefaultChatTransportBody() async throws {
        let http = StubHTTPClient([.eventStream(try UIMessageStream.encode(.textResponse("Hi")))])
        let transport = AISDKChatTransport(api: api, headers: ["Authorization": "Bearer t"], body: ["sessionId": "s1"], httpClient: http)
        let chat = Chat(id: "chat-9", modelID: "anthropic/claude-sonnet-5.5", transport: transport)
        await chat.sendMessage("Hello", options: ChatRequestOptions(headers: ["X-Trace": "1"], body: ["extra": true]))

        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == api)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(request.value(forHTTPHeaderField: "X-Trace") == "1")
        let body = try #require(http.requestBodies.first)
        #expect(body.objectValue?.keys.sorted() == ["extra", "id", "messages", "model", "sessionId", "trigger"])
        #expect(body["id"] == "chat-9")
        #expect(body["trigger"] == "submit-message")
        #expect(body["model"] == "anthropic/claude-sonnet-5.5")
        #expect(body["messages"]?[0]?["parts"] == [["type": "text", "text": "Hello"]])
        #expect(chat.messages.last?.text == "Hi")
    }

    @Test func aiSDKTransportResolvesDynamicHeaders() async throws {
        let http = StubHTTPClient([.eventStream(try UIMessageStream.encode(.textResponse("Hi")))])
        let transport = AISDKChatTransport(api: api, dynamicHeaders: { ["Authorization": "Bearer fresh"] }, httpClient: http)
        await Chat(transport: transport).sendMessage("Hello")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
    }

    @Test func aiSDKTransportReconnects() async throws {
        let http = StubHTTPClient([
            .body("", statusCode: 204),
            .eventStream(try UIMessageStream.encode(.textResponse("Back again", messageId: "a1"))),
        ])
        let transport = AISDKChatTransport(api: URL(string: "https://example.com/api/chat?region=eu")!, httpClient: http)
        #expect(try await transport.reconnectToStream(ChatReconnectRequest(chatID: "chat/1")) == nil)
        let chat = Chat(id: "chat 2", messages: [.user("Hi")], transport: transport)
        await chat.resumeStream()
        #expect(http.requests.map(\.httpMethod) == ["GET", "GET"])
        #expect(http.requests[0].url?.absoluteString == "https://example.com/api/chat/chat%2F1/stream?region=eu")
        #expect(http.requests[1].url?.absoluteString == "https://example.com/api/chat/chat%202/stream?region=eu")
        #expect(chat.messages.last?.text == "Back again")
    }

    @Test func aiSDKTransportReportsHTTPErrors() async throws {
        let http = StubHTTPClient([.json(["error": ["message": "Rate limited", "type": "rate_limit_error"]], statusCode: 429, headers: ["retry-after": "7", "x-request-id": "req-1"])])
        let chat = Chat(transport: AISDKChatTransport(api: api, httpClient: http))
        await chat.sendMessage("Hi")
        let error = try #require(chat.error)
        #expect(error.kind == .http)
        #expect(error.statusCode == 429)
        #expect(error.message == "Rate limited")
        #expect(error.code == "rate_limit_error")
        #expect(error.retryAfter == .seconds(7))
        #expect(error.requestID == "req-1")
        #expect(error.isRetryable)
    }

    @Test func aiSDKTransportRejectsInvalidChunks() async throws {
        let http = StubHTTPClient([.eventStream("data: {not json}\n\n")])
        let chat = Chat(transport: AISDKChatTransport(api: api, httpClient: http))
        await chat.sendMessage("Hi")
        #expect(chat.error?.kind == .decoding)
    }

    @Test func aiSDKTransportReportsDroppedConnections() async throws {
        let body = try UIMessageStream.encode([.start(), .startStep, .textStart(id: "t"), .textDelta(id: "t", delta: "Par")])
        var stub = StubHTTPClient.Stub.eventStream(body)
        stub.chunks = [body.prefix(body.count - UIMessageStream.done.count)]
        stub.failure = ChatError(kind: .network, message: "The network connection was lost.")
        let chat = Chat(transport: AISDKChatTransport(api: api, httpClient: StubHTTPClient([stub])))
        await chat.sendMessage("Hi")
        #expect(chat.error?.isDisconnect == true)
        #expect(chat.messages.last?.text == "Par")
    }

    @Test func textStreamTransportBuildsATextPart() async throws {
        let http = StubHTTPClient([StubHTTPClient.Stub(statusCode: 200, headers: ["content-type": "text/plain"], chunks: [Data("Hello ".utf8), Data([0xC3]), Data([0xA9, 0x21])])])
        let chat = Chat(transport: TextStreamChatTransport(api: api, httpClient: http))
        await chat.sendMessage("Hi")
        #expect(chat.status == .ready)
        #expect(chat.messages.last?.text == "Hello é!")
        #expect(chat.messages.last?.parts.map(\.type) == ["step-start", "text"])
    }

    @Test func routingSplitsTheProviderPrefix() async throws {
        let anthropic = MockChatTransport(responses: [.chunks(.textResponse("from anthropic"))])
        let openai = MockChatTransport(responses: [.chunks(.textResponse("from openai"))])
        let routing = RoutingChatTransport(routes: ["anthropic": anthropic, "openai": openai])
        let chat = Chat(modelID: "openai/gpt-6-sol", transport: routing)
        await chat.sendMessage("Hi")
        #expect(openai.requests.first?.modelID == "gpt-6-sol")
        #expect(anthropic.requests.isEmpty)
        chat.modelID = "anthropic/claude-opus-5-5"
        await chat.sendMessage("Again")
        #expect(anthropic.requests.first?.modelID == "claude-opus-5-5")
        #expect(chat.messages.map(\.text) == ["Hi", "from openai", "Again", "from anthropic"])
    }

    @Test func routingFailsClearlyWithoutARoute() async throws {
        let chat = Chat(modelID: "mistral/large", transport: RoutingChatTransport(routes: ["openai": MockChatTransport()]))
        await chat.sendMessage("Hi")
        #expect(chat.error?.kind == .configuration)
    }

    @Test func encodesAStreamTheAISDKClientCanRead() throws {
        let data = try UIMessageStream.encode([.start(messageId: "m"), .textStart(id: "t"), .textDelta(id: "t", delta: "a\nb"), .textEnd(id: "t"), .finish()])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix(#"data: {"messageId":"m","type":"start"}"#))
        #expect(text.hasSuffix("data: [DONE]\n\n"))
        var parser = ServerSentEventParser()
        let decoded = try parser.consume(data).compactMap { try UIMessageStream.decodeEvent($0.data) }
        #expect(decoded.count == 5)
    }

    @Test func utf8DecoderHoldsBackSplitCharacters() {
        var decoder = UTF8StreamDecoder()
        let bytes = Array("a🍰é".utf8)
        var text = ""
        for byte in bytes { text += decoder.decode(Data([byte])) }
        text += decoder.flush()
        #expect(text == "a🍰é")
    }
}
