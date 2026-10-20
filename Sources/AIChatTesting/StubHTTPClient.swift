import AIChat
import Foundation

/// An ``HTTPStreamingClient`` that serves canned responses and records every request.
///
/// Use it to test transports against recorded streams without a network.
public final class StubHTTPClient: HTTPStreamingClient, @unchecked Sendable {
    public struct Stub: Sendable {
        public var statusCode: Int
        public var headers: [String: String]
        /// The body, split into the chunks the client receives.
        public var chunks: [Data]
        /// A pause before each chunk.
        public var delay: Duration?
        /// An error thrown after the chunks, to simulate a dropped connection.
        public var failure: ChatError?

        public init(statusCode: Int = 200, headers: [String: String] = [:], chunks: [Data], delay: Duration? = nil, failure: ChatError? = nil) {
            self.statusCode = statusCode
            self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
            self.chunks = chunks
            self.delay = delay
            self.failure = failure
        }

        /// A `text/event-stream` response, split into chunks of `chunkSize` bytes to
        /// exercise events that span chunk boundaries.
        public static func eventStream(_ body: Data, chunkSize: Int = 64, statusCode: Int = 200, headers: [String: String] = [:]) -> Stub {
            var all = ["content-type": "text/event-stream"]
            all.merge(headers) { _, new in new }
            return Stub(statusCode: statusCode, headers: all, chunks: split(body, size: chunkSize))
        }

        public static func eventStream(_ body: String, chunkSize: Int = 64, statusCode: Int = 200, headers: [String: String] = [:]) -> Stub {
            eventStream(Data(body.utf8), chunkSize: chunkSize, statusCode: statusCode, headers: headers)
        }

        /// A JSON response.
        public static func json(_ value: JSONValue, statusCode: Int = 200, headers: [String: String] = [:]) -> Stub {
            var all = ["content-type": "application/json"]
            all.merge(headers) { _, new in new }
            return Stub(statusCode: statusCode, headers: all, chunks: [(try? value.jsonData()) ?? Data()])
        }

        /// A response with a raw body.
        public static func body(_ text: String, statusCode: Int, headers: [String: String] = [:]) -> Stub {
            Stub(statusCode: statusCode, headers: headers, chunks: [Data(text.utf8)])
        }

        private static func split(_ data: Data, size: Int) -> [Data] {
            guard size > 0, data.count > size else { return [data] }
            return stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<Swift.min($0 + size, data.count)) }
        }
    }

    private let lock = NSLock()
    private var stubs: [Stub]
    private var handler: (@Sendable (URLRequest) async throws -> Stub)?
    private var recorded: [URLRequest] = []

    /// Serves `stubs` in order. Requests beyond them fail.
    public init(_ stubs: [Stub]) {
        self.stubs = stubs
    }

    /// Answers every request with `handler`.
    public init(handler: @escaping @Sendable (URLRequest) async throws -> Stub) {
        stubs = []
        self.handler = handler
    }

    public var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    /// The JSON bodies of the recorded requests.
    public var requestBodies: [JSONValue] {
        requests.compactMap { request in request.httpBody.flatMap { try? JSONValue(parsing: $0) } }
    }

    public func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let (next, stubHandler): (Stub?, (@Sendable (URLRequest) async throws -> Stub)?) = lock.withLock {
            recorded.append(request)
            if let handler = self.handler { return (nil, handler) }
            return (stubs.isEmpty ? nil : stubs.removeFirst(), nil)
        }
        let stub: Stub
        if let stubHandler {
            stub = try await stubHandler(request)
        } else if let next {
            stub = next
        } else {
            throw ChatError(kind: .network, message: "No stubbed response left for \(request.url?.absoluteString ?? "request").")
        }
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                for chunk in stub.chunks {
                    if let delay = stub.delay { try? await Task.sleep(for: delay) }
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                if let failure = stub.failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(statusCode: stub.statusCode, headers: stub.headers, url: request.url, body: body)
    }
}
