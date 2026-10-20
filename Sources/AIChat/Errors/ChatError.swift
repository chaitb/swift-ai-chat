import Foundation

/// Every failure the package reports.
///
/// The error keeps everything needed to explain or retry a failure: a stable
/// ``Kind``, the provider's error code, the HTTP status, the request id, retry
/// timing and the operation that failed.
public struct ChatError: Error, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// The server answered with a non-success HTTP status.
        case http
        /// The connection failed or dropped before the response finished.
        case network
        /// A request, chunk or stored value could not be encoded or decoded.
        case decoding
        /// The model provider or backend reported an error inside the stream.
        case stream
        /// The stream broke the UI message stream protocol.
        case protocolViolation
        /// A client-side tool failed.
        case tool
        /// A ``ChatStore`` failed to load or save.
        case persistence
        /// The request was cancelled by ``Chat/stop()`` or task cancellation.
        case cancelled
        /// The chat or a transport was configured in a way that can't work.
        case configuration
        /// Any other failure.
        case unknown
    }

    public var kind: Kind
    public var message: String
    /// The provider's error code or type, such as `overloaded_error` or `rate_limit_exceeded`.
    public var code: String?
    /// The HTTP status code, when the failure came from an HTTP response.
    public var statusCode: Int?
    /// The request id the server returned, useful for support tickets.
    public var requestID: String?
    /// How long the server asked the client to wait before retrying.
    public var retryAfter: Duration?
    /// Whether retrying the same request may succeed.
    public var isRetryable: Bool
    /// Up to 64 KB of the response body for HTTP failures.
    public var responseBody: String?
    /// What was running when the failure happened, such as `anthropic.messages.stream`.
    public var operation: String?
    /// A description of the underlying error, when one caused this failure.
    public var underlying: String?

    public init(
        kind: Kind,
        message: String,
        code: String? = nil,
        statusCode: Int? = nil,
        requestID: String? = nil,
        retryAfter: Duration? = nil,
        isRetryable: Bool? = nil,
        responseBody: String? = nil,
        operation: String? = nil,
        underlying: String? = nil
    ) {
        self.kind = kind
        self.message = message
        self.code = code
        self.statusCode = statusCode
        self.requestID = requestID
        self.retryAfter = retryAfter
        self.isRetryable = isRetryable ?? Self.defaultRetryable(kind: kind, statusCode: statusCode)
        self.responseBody = responseBody
        self.operation = operation
        self.underlying = underlying
    }

    /// Whether the failure is a dropped or unreachable connection, where resuming
    /// the stream can recover the response.
    public var isDisconnect: Bool {
        kind == .network
    }

    public var isCancelled: Bool { kind == .cancelled }

    /// Returns a copy with `operation` filled in when it was missing.
    public func within(operation: String) -> ChatError {
        guard self.operation == nil else { return self }
        var copy = self
        copy.operation = operation
        return copy
    }

    static func defaultRetryable(kind: Kind, statusCode: Int?) -> Bool {
        switch kind {
        case .network: return true
        case .http:
            guard let statusCode else { return false }
            return statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
        default: return false
        }
    }

    public static let cancelled = ChatError(kind: .cancelled, message: "The request was cancelled.")

    /// Maps any error thrown by Foundation or a transport into a `ChatError`.
    public static func from(_ error: any Error, operation: String? = nil) -> ChatError {
        if let error = error as? ChatError { return operation.map(error.within(operation:)) ?? error }
        if error is CancellationError { return ChatError(kind: .cancelled, message: Self.cancelled.message, operation: operation) }
        if let error = error as? URLError {
            if error.code == .cancelled { return ChatError(kind: .cancelled, message: Self.cancelled.message, operation: operation) }
            return ChatError(
                kind: .network,
                message: error.localizedDescription,
                code: "url_error_\(error.code.rawValue)",
                operation: operation,
                underlying: String(describing: error)
            )
        }
        if error is DecodingError || error is EncodingError {
            return ChatError(kind: .decoding, message: String(describing: error), operation: operation, underlying: String(describing: error))
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorCancelled { return ChatError(kind: .cancelled, message: Self.cancelled.message, operation: operation) }
            return ChatError(kind: .network, message: nsError.localizedDescription, code: "url_error_\(nsError.code)", operation: operation)
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code >= 3840, nsError.code <= 3851 {
            return ChatError(kind: .decoding, message: nsError.localizedDescription, operation: operation, underlying: String(describing: error))
        }
        return ChatError(kind: .unknown, message: error.localizedDescription, operation: operation, underlying: String(describing: error))
    }
}

extension ChatError: LocalizedError {
    public var errorDescription: String? { message }
}

extension ChatError: CustomStringConvertible {
    public var description: String {
        var fields = ["\(kind.rawValue): \(message)"]
        if let code { fields.append("code=\(code)") }
        if let statusCode { fields.append("status=\(statusCode)") }
        if let requestID { fields.append("request=\(requestID)") }
        if let operation { fields.append("operation=\(operation)") }
        return fields.joined(separator: " ")
    }
}
