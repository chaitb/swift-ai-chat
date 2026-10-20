import AIChat
import Foundation

/// A ``ChatTransport`` that answers with scripted responses and records every request.
///
/// ```swift
/// let transport = MockChatTransport(responses: [.chunks(.textResponse("Hi there"))])
/// let chat = Chat(transport: transport)
/// await chat.sendMessage("Hello")
/// #expect(chat.messages.last?.text == "Hi there")
/// ```
public final class MockChatTransport: ChatTransport, @unchecked Sendable {
    public enum Response: Sendable {
        /// Streams the chunks, waiting `delay` between them.
        case chunks([UIMessageChunk], delay: Duration? = nil)
        /// Throws before streaming.
        case failure(ChatError)
        /// Streams the chunks, then fails.
        case chunksThenFailure([UIMessageChunk], ChatError)
        /// Streams the chunks, then waits until the request is cancelled.
        case chunksThenHang([UIMessageChunk])
    }

    public let resumeStreamIsReplay: Bool
    private let lock = NSLock()
    private var responses: [Response]
    private var reconnectResponses: [Response?]
    private var recordedRequests: [ChatTransportRequest] = []
    private var recordedReconnects: [ChatReconnectRequest] = []

    /// - Parameters:
    ///   - responses: Answers for `sendMessages`, in order. Extra requests get an empty response.
    ///   - reconnectResponses: Answers for `reconnectToStream`, in order. `nil` means nothing to resume.
    ///   - resumeStreamIsReplay: Whether reconnecting replays the whole response.
    public init(responses: [Response] = [], reconnectResponses: [Response?] = [], resumeStreamIsReplay: Bool = false) {
        self.responses = responses
        self.reconnectResponses = reconnectResponses
        self.resumeStreamIsReplay = resumeStreamIsReplay
    }

    public var requests: [ChatTransportRequest] {
        lock.withLock { recordedRequests }
    }

    public var reconnectRequests: [ChatReconnectRequest] {
        lock.withLock { recordedReconnects }
    }

    public func enqueue(_ response: Response) {
        lock.withLock { responses.append(response) }
    }

    public func enqueueReconnect(_ response: Response?) {
        lock.withLock { reconnectResponses.append(response) }
    }

    public func sendMessages(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream {
        let response: Response = lock.withLock {
            recordedRequests.append(request)
            return responses.isEmpty ? .chunks([]) : responses.removeFirst()
        }
        return try Self.stream(for: response)
    }

    public func reconnectToStream(_ request: ChatReconnectRequest) async throws -> UIMessageChunkStream? {
        let response: Response? = lock.withLock {
            recordedReconnects.append(request)
            return reconnectResponses.isEmpty ? nil : reconnectResponses.removeFirst()
        }
        guard let response else { return nil }
        return try Self.stream(for: response)
    }

    private static func stream(for response: Response) throws -> UIMessageChunkStream {
        switch response {
        case .failure(let error):
            throw error
        case .chunks(let chunks, let delay):
            return stream(chunks, delay: delay, then: nil, hang: false)
        case .chunksThenFailure(let chunks, let error):
            return stream(chunks, delay: nil, then: error, hang: false)
        case .chunksThenHang(let chunks):
            return stream(chunks, delay: nil, then: nil, hang: true)
        }
    }

    private static func stream(_ chunks: [UIMessageChunk], delay: Duration?, then failure: ChatError?, hang: Bool) -> UIMessageChunkStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in chunks {
                    if let delay { try? await Task.sleep(for: delay) }
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                if hang {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
