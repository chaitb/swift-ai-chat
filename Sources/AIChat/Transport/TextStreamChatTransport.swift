import Foundation

/// A transport for backends that stream plain text, like the AI SDK's
/// `TextStreamChatTransport` and `toTextStreamResponse()`.
///
/// The request is the same as ``AISDKChatTransport``. The text becomes a single
/// text part of the assistant message.
public struct TextStreamChatTransport: ChatTransport {
    private let base: AISDKChatTransport

    public init(
        api: URL,
        headers: [String: String] = [:],
        dynamicHeaders: (@Sendable () async throws -> [String: String])? = nil,
        body: [String: JSONValue] = [:],
        modelBodyKey: String? = "model",
        httpClient: any HTTPStreamingClient = URLSessionStreamingClient(),
        timeout: TimeInterval = 600,
        prepareSendMessagesRequest: (@Sendable (ChatTransportRequest, AISDKChatTransport.PreparedRequest) async throws -> AISDKChatTransport.PreparedRequest)? = nil,
        onResponse: (@Sendable (HTTPResponseHead) async -> Void)? = nil
    ) {
        base = AISDKChatTransport(
            api: api,
            headers: headers,
            dynamicHeaders: dynamicHeaders,
            body: body,
            modelBodyKey: modelBodyKey,
            httpClient: TextStreamHTTPClient(base: httpClient),
            timeout: timeout,
            prepareSendMessagesRequest: prepareSendMessagesRequest,
            onResponse: onResponse
        )
    }

    public func sendMessages(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream {
        try await base.sendMessages(request)
    }
}

/// Wraps a plain-text response body as a UI message stream body.
private struct TextStreamHTTPClient: HTTPStreamingClient {
    let base: any HTTPStreamingClient

    func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
        var response = try await base.send(request)
        guard response.isSuccess else { return response }
        let text = response.body
        response.body = AsyncThrowingStream { continuation in
            let task = Task {
                func emit(_ chunk: UIMessageChunk) throws {
                    continuation.yield(try UIMessageStream.encode(chunk))
                }
                do {
                    try emit(.start())
                    try emit(.startStep)
                    try emit(.textStart(id: "text-1"))
                    var decoder = UTF8StreamDecoder()
                    for try await data in text {
                        let delta = decoder.decode(data)
                        if !delta.isEmpty { try emit(.textDelta(id: "text-1", delta: delta)) }
                    }
                    let rest = decoder.flush()
                    if !rest.isEmpty { try emit(.textDelta(id: "text-1", delta: rest)) }
                    try emit(.textEnd(id: "text-1"))
                    try emit(.finishStep)
                    try emit(.finish())
                    continuation.yield(UIMessageStream.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return response
    }
}

/// Decodes UTF-8 that arrives in arbitrary chunks, holding back a split character.
public struct UTF8StreamDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func decode(_ data: Data) -> String {
        pending.append(contentsOf: data)
        var end = pending.count
        var continuationBytes = 0
        while end > 0, continuationBytes < 4 {
            let byte = pending[end - 1]
            if byte & 0b1100_0000 == 0b1000_0000 {
                continuationBytes += 1
                end -= 1
                continue
            }
            let length: Int
            if byte & 0b1000_0000 == 0 {
                length = 1
            } else if byte & 0b1110_0000 == 0b1100_0000 {
                length = 2
            } else if byte & 0b1111_0000 == 0b1110_0000 {
                length = 3
            } else if byte & 0b1111_1000 == 0b1111_0000 {
                length = 4
            } else {
                length = 1
            }
            if continuationBytes + 1 < length {
                end -= 1
            } else {
                end = pending.count
            }
            break
        }
        if continuationBytes >= 4 { end = pending.count }
        let complete = pending[..<end]
        let text = String(decoding: complete, as: UTF8.self)
        pending.removeFirst(end)
        return text
    }

    public mutating func flush() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
