import Foundation

/// The head and the streaming body of an HTTP response.
public struct HTTPStreamResponse: Sendable {
    public var statusCode: Int
    /// Response headers with lowercased names.
    public var headers: [String: String]
    public var url: URL?
    /// The body, delivered in chunks as it arrives.
    public var body: AsyncThrowingStream<Data, any Error>

    public init(statusCode: Int, headers: [String: String], url: URL? = nil, body: AsyncThrowingStream<Data, any Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.url = url
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// The header value for a case-insensitive name.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Reads the rest of the body, up to `limit` bytes.
    public func collectBody(limit: Int = 65_536) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk.prefix(max(0, limit - data.count)))
            if data.count >= limit { break }
        }
        return data
    }
}

/// Sends HTTP requests and streams their responses.
///
/// The default, ``URLSessionStreamingClient``, uses `URLSession`. Provide your own to
/// add authentication, logging or a custom networking stack, or to stub responses in tests.
public protocol HTTPStreamingClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPStreamResponse
}

/// An ``HTTPStreamingClient`` backed by `URLSession`.
public struct URLSessionStreamingClient: HTTPStreamingClient {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw ChatError(kind: .network, message: "The server sent a response that isn't HTTP.")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key.lowercased()] = value as? String ?? String(describing: value)
        }
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                var buffer = Data()
                buffer.reserveCapacity(4096)
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A || buffer.count >= 16_384 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                bytes.task.cancel()
            }
        }
        return HTTPStreamResponse(statusCode: http.statusCode, headers: headers, url: http.url, body: body)
    }
}

extension HTTPStreamResponse {
    /// Turns a non-success response into a ``ChatError``, reading up to 64 KB of the body.
    ///
    /// `parseError` extracts a provider's error message and code from the body.
    public func failure(
        operation: String,
        parseError: (@Sendable (Data) -> (message: String?, code: String?))? = nil
    ) async -> ChatError {
        let data = (try? await collectBody()) ?? Data()
        let bodyText = String(decoding: data, as: UTF8.self)
        let parsed = parseError?(data)
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = parsed?.message
            ?? Self.genericErrorMessage(in: data)
            ?? (trimmed.isEmpty ? "The server responded with status \(statusCode)." : String(trimmed.prefix(1_000)))
        return ChatError(
            kind: .http,
            message: message,
            code: parsed?.code ?? Self.genericErrorCode(in: data),
            statusCode: statusCode,
            requestID: header("x-request-id") ?? header("request-id") ?? header("cf-ray"),
            retryAfter: retryAfter,
            responseBody: bodyText.isEmpty ? nil : bodyText,
            operation: operation
        )
    }

    /// The `retry-after` or `retry-after-ms` header as a duration.
    public var retryAfter: Duration? {
        if let milliseconds = header("retry-after-ms").flatMap(Double.init) {
            return .milliseconds(Int64(milliseconds))
        }
        guard let value = header("retry-after") else { return nil }
        if let seconds = Double(value) { return .milliseconds(Int64(seconds * 1_000)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .milliseconds(Int64(max(0, date.timeIntervalSinceNow) * 1_000))
    }

    private static func genericErrorMessage(in data: Data) -> String? {
        guard let value = try? JSONValue(parsing: data) else { return nil }
        if let message = value["error"]?["message"]?.stringValue { return message }
        if let message = value["error"]?.stringValue { return message }
        if let message = value["message"]?.stringValue { return message }
        return nil
    }

    private static func genericErrorCode(in data: Data) -> String? {
        guard let value = try? JSONValue(parsing: data) else { return nil }
        return value["error"]?["code"]?.stringValue
            ?? value["error"]?["type"]?.stringValue
            ?? value["failure"]?["code"]?.stringValue
            ?? value["code"]?.stringValue
    }
}
