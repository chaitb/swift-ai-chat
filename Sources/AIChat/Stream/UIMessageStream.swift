import Foundation

/// A stream of UI message chunks, as returned by a ``ChatTransport``.
public typealias UIMessageChunkStream = AsyncThrowingStream<UIMessageChunk, any Error>

/// Maps server-sent events to UI message chunks. Transports for other providers
/// implement one and hand it to ``UIMessageStream/chunks(from:mapper:)``.
public protocol ServerSentEventMapper: Sendable {
    /// Maps one event. Return ``UIMessageStream/EventResult/done`` to stop reading the body.
    mutating func map(_ event: ServerSentEvent) throws -> UIMessageStream.EventResult
    /// Called once when the body ends without a `done` result.
    mutating func end() throws -> [UIMessageChunk]
}

extension ServerSentEventMapper {
    public mutating func end() throws -> [UIMessageChunk] { [] }
}

/// Reading and writing the AI SDK UI message stream protocol (v1).
public enum UIMessageStream {
    /// What a server-sent event mapped to.
    public enum EventResult: Sendable {
        case chunks([UIMessageChunk])
        case done
    }

    /// The response headers the AI SDK sends with a UI message stream.
    public static let headers: [String: String] = [
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        "connection": "keep-alive",
        "x-vercel-ai-ui-message-stream": "v1",
        "x-accel-buffering": "no",
    ]

    /// Encodes one chunk as a server-sent event.
    public static func encode(_ chunk: UIMessageChunk) throws -> Data {
        var data = Data("data: ".utf8)
        data.append(try chunk.jsonData())
        data.append(contentsOf: [0x0A, 0x0A])
        return data
    }

    /// The final `[DONE]` event.
    public static let done = Data("data: [DONE]\n\n".utf8)

    /// Encodes a whole stream of chunks as a `text/event-stream` body, ending with `[DONE]`.
    public static func encode(_ chunks: [UIMessageChunk]) throws -> Data {
        var data = Data()
        for chunk in chunks { data.append(try encode(chunk)) }
        data.append(done)
        return data
    }

    /// Decodes the data of one server-sent event into a chunk.
    /// Returns `nil` for the `[DONE]` sentinel.
    public static func decodeEvent(_ data: String) throws(ChatError) -> UIMessageChunk? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" { return nil }
        let value: JSONValue
        do {
            value = try JSONValue(parsing: data)
        } catch {
            throw ChatError(
                kind: .decoding,
                message: "The stream sent an event that isn't valid JSON: \(trimmed.prefix(200))",
                underlying: String(describing: error)
            )
        }
        guard let object = value.objectValue else {
            throw ChatError(kind: .decoding, message: "The stream sent an event that isn't a JSON object: \(trimmed.prefix(200))")
        }
        return try UIMessageChunk(jsonObject: object)
    }

    /// Parses a `text/event-stream` body of UI message chunks.
    ///
    /// Keep-alive comments are skipped and the stream ends at `[DONE]` or when the body ends.
    public static func chunks<Body: AsyncSequence & Sendable>(from body: Body) -> UIMessageChunkStream where Body.Element == Data {
        chunks(from: body, mapper: UIMessageChunkEventMapper())
    }

    /// Parses a `text/event-stream` body and maps each event to chunks with `mapper`.
    public static func chunks<Body: AsyncSequence & Sendable, Mapper: ServerSentEventMapper>(
        from body: Body,
        mapper: Mapper
    ) -> UIMessageChunkStream where Body.Element == Data {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = ServerSentEventParser()
                var mapper = mapper
                do {
                    var ended = false
                    reading: for try await data in body {
                        for event in parser.consume(data) {
                            switch try mapper.map(event) {
                            case .chunks(let chunks):
                                for chunk in chunks { continuation.yield(chunk) }
                            case .done:
                                ended = true
                                break reading
                            }
                        }
                    }
                    try Task.checkCancellation()
                    if !ended, let event = parser.finish() {
                        switch try mapper.map(event) {
                        case .chunks(let chunks):
                            for chunk in chunks { continuation.yield(chunk) }
                        case .done:
                            ended = true
                        }
                    }
                    if !ended {
                        for chunk in try mapper.end() { continuation.yield(chunk) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Maps the events of an AI SDK UI message stream.
public struct UIMessageChunkEventMapper: ServerSentEventMapper {
    public init() {}

    public mutating func map(_ event: ServerSentEvent) throws -> UIMessageStream.EventResult {
        guard let chunk = try UIMessageStream.decodeEvent(event.data) else { return .done }
        return .chunks([chunk])
    }
}
