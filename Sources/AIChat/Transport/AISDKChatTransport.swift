import Foundation

/// The status and headers of an HTTP response, without its body.
public struct HTTPResponseHead: Sendable, Hashable {
    public var statusCode: Int
    /// Headers with lowercased names.
    public var headers: [String: String]
    public var url: URL?

    public init(statusCode: Int, headers: [String: String], url: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.url = url
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// A transport for backends built with the Vercel AI SDK, speaking the UI message
/// stream protocol: the same contract as `DefaultChatTransport` and `useChat`.
///
/// It POSTs `{ id, messages, trigger, messageId, ...body }` as JSON to `api` and
/// reads the `text/event-stream` response. Reconnecting GETs `{api}/{chatId}/stream`,
/// where `204 No Content` means there is nothing to resume.
///
/// Use `prepareSendMessagesRequest` to reshape requests, for example to send only
/// the newest message to a server that keeps the history itself.
public struct AISDKChatTransport: ChatTransport {
    /// A request about to be sent. Change any field in `prepareSendMessagesRequest`.
    public struct PreparedRequest: Sendable {
        public var url: URL
        public var method: String
        public var headers: [String: String]
        /// The JSON body. `nil` sends no body.
        public var body: JSONValue?

        public init(url: URL, method: String = "POST", headers: [String: String], body: JSONValue?) {
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
        }
    }

    public var api: URL
    public var headers: [String: String]
    /// Headers resolved before every request, such as a fresh auth token.
    public var dynamicHeaders: (@Sendable () async throws -> [String: String])?
    /// Extra JSON body fields sent with every request.
    public var body: [String: JSONValue]
    /// The body key for the chat's selected model. `nil` leaves the model out.
    public var modelBodyKey: String?
    public var httpClient: any HTTPStreamingClient
    /// How long the connection may stay silent before it times out.
    public var timeout: TimeInterval
    public var prepareSendMessagesRequest: (@Sendable (ChatTransportRequest, PreparedRequest) async throws -> PreparedRequest)?
    public var prepareReconnectToStreamRequest: (@Sendable (ChatReconnectRequest, PreparedRequest) async throws -> PreparedRequest)?
    /// Called with the status and headers of every response, before its body is read.
    public var onResponse: (@Sendable (HTTPResponseHead) async -> Void)?
    /// Whether the resume endpoint replays the response from the start, as the
    /// `resumable-stream` package does.
    public var resumeStreamIsReplay: Bool

    public init(
        api: URL,
        headers: [String: String] = [:],
        dynamicHeaders: (@Sendable () async throws -> [String: String])? = nil,
        body: [String: JSONValue] = [:],
        modelBodyKey: String? = "model",
        httpClient: any HTTPStreamingClient = URLSessionStreamingClient(),
        timeout: TimeInterval = 600,
        prepareSendMessagesRequest: (@Sendable (ChatTransportRequest, PreparedRequest) async throws -> PreparedRequest)? = nil,
        prepareReconnectToStreamRequest: (@Sendable (ChatReconnectRequest, PreparedRequest) async throws -> PreparedRequest)? = nil,
        onResponse: (@Sendable (HTTPResponseHead) async -> Void)? = nil,
        resumeStreamIsReplay: Bool = true
    ) {
        self.api = api
        self.headers = headers
        self.dynamicHeaders = dynamicHeaders
        self.body = body
        self.modelBodyKey = modelBodyKey
        self.httpClient = httpClient
        self.timeout = timeout
        self.prepareSendMessagesRequest = prepareSendMessagesRequest
        self.prepareReconnectToStreamRequest = prepareReconnectToStreamRequest
        self.onResponse = onResponse
        self.resumeStreamIsReplay = resumeStreamIsReplay
    }

    public func sendMessages(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream {
        var fields = body.merging(request.body) { _, new in new }
        fields["id"] = .string(request.chatID)
        fields["messages"] = .array(request.messages.map(\.jsonValue))
        fields["trigger"] = .string(request.trigger.rawValue)
        if let messageID = request.messageID { fields["messageId"] = .string(messageID) }
        if let modelBodyKey, let modelID = request.modelID { fields[modelBodyKey] = .string(modelID) }

        var prepared = PreparedRequest(
            url: api,
            headers: try await resolvedHeaders(extra: request.headers),
            body: .object(fields)
        )
        if let prepareSendMessagesRequest {
            prepared = try await prepareSendMessagesRequest(request, prepared)
        }
        let response = try await send(prepared, operation: "aisdk.sendMessages")
        guard response.isSuccess else {
            throw await response.failure(operation: "aisdk.sendMessages")
        }
        return UIMessageStream.chunks(from: response.body)
    }

    public func reconnectToStream(_ request: ChatReconnectRequest) async throws -> UIMessageChunkStream? {
        var prepared = PreparedRequest(
            url: Self.reconnectURL(api: api, chatID: request.chatID),
            method: "GET",
            headers: try await resolvedHeaders(extra: request.headers),
            body: nil
        )
        if let prepareReconnectToStreamRequest {
            prepared = try await prepareReconnectToStreamRequest(request, prepared)
        }
        let response = try await send(prepared, operation: "aisdk.reconnectToStream")
        if response.statusCode == 204 { return nil }
        guard response.isSuccess else {
            throw await response.failure(operation: "aisdk.reconnectToStream")
        }
        return UIMessageStream.chunks(from: response.body)
    }

    /// `{api}/{chatId}/stream`, keeping any query string of `api`.
    static func reconnectURL(api: URL, chatID: String) -> URL {
        guard var components = URLComponents(url: api, resolvingAgainstBaseURL: false) else {
            return api.appendingPathComponent(chatID).appendingPathComponent("stream")
        }
        let encodedID = chatID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? chatID
        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path + "/" + encodedID + "/stream"
        return components.url ?? api
    }

    private func resolvedHeaders(extra: [String: String]) async throws -> [String: String] {
        var resolved = headers
        if let dynamicHeaders {
            resolved.merge(try await dynamicHeaders()) { _, new in new }
        }
        resolved.merge(extra) { _, new in new }
        return resolved
    }

    private func send(_ prepared: PreparedRequest, operation: String) async throws -> HTTPStreamResponse {
        var urlRequest = URLRequest(url: prepared.url, timeoutInterval: timeout)
        urlRequest.httpMethod = prepared.method
        if let body = prepared.body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try body.jsonData()
        }
        for (name, value) in prepared.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let response: HTTPStreamResponse
        do {
            response = try await httpClient.send(urlRequest)
        } catch {
            throw ChatError.from(error, operation: operation)
        }
        await onResponse?(HTTPResponseHead(statusCode: response.statusCode, headers: response.headers, url: response.url))
        return response
    }
}
