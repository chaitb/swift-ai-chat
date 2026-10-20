import Foundation

/// One server-sent event.
public struct ServerSentEvent: Hashable, Sendable {
    /// The `event:` field, or `nil` for the default `message` type.
    public var event: String?
    /// The `data:` lines joined with newlines.
    public var data: String
    /// The `id:` field.
    public var id: String?
    /// The `retry:` field in milliseconds.
    public var retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// An incremental parser for `text/event-stream` bodies, following the WHATWG
/// event stream rules: LF, CRLF and CR line endings, `:` comments, multi-line
/// `data:` fields, and a single optional space after the colon.
///
/// Feed it bytes as they arrive; it returns each event once its blank line is seen.
public struct ServerSentEventParser: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var hasData = false
    private var eventType: String?
    private var eventID: String?
    private var retry: Int?
    private var lastByteWasCR = false
    private var startedStream = false
    /// The number of `:` comment lines seen, such as keep-alive pings.
    public private(set) var commentCount = 0

    public init() {}

    /// Consumes a chunk of the body and returns the events it completed.
    public mutating func consume(_ data: Data) -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                if let event = consume(byte: byte) { events.append(event) }
            }
        }
        return events
    }

    /// Consumes one byte and returns an event when the byte completed one.
    public mutating func consume(byte: UInt8) -> ServerSentEvent? {
        if byte == 0x0A {
            if lastByteWasCR {
                lastByteWasCR = false
                return nil
            }
            return endLine()
        }
        if byte == 0x0D {
            lastByteWasCR = true
            return endLine()
        }
        lastByteWasCR = false
        line.append(byte)
        return nil
    }

    /// Ends the stream, returning an event that was still pending when the body ended.
    public mutating func finish() -> ServerSentEvent? {
        var event: ServerSentEvent?
        if !line.isEmpty { event = endLine() }
        if event == nil, hasData { event = dispatch() }
        return event
    }

    private mutating func endLine() -> ServerSentEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if !startedStream {
            startedStream = true
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        if line.isEmpty { return dispatch() }
        if line.first == UInt8(ascii: ":") {
            commentCount += 1
            return nil
        }
        let field: String
        let value: String
        if let colon = line.firstIndex(of: UInt8(ascii: ":")) {
            field = String(decoding: line[..<colon], as: UTF8.self)
            var valueStart = line.index(after: colon)
            if valueStart < line.endIndex, line[valueStart] == UInt8(ascii: " ") { valueStart = line.index(after: valueStart) }
            value = String(decoding: line[valueStart...], as: UTF8.self)
        } else {
            field = String(decoding: line, as: UTF8.self)
            value = ""
        }
        switch field {
        case "data":
            dataLines.append(value)
            hasData = true
        case "event":
            eventType = value
        case "id":
            if !value.contains("\0") { eventID = value }
        case "retry":
            if !value.isEmpty, value.allSatisfy(\.isASCIIDigit) { retry = Int(value) }
        default:
            break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            hasData = false
            eventType = nil
            retry = nil
        }
        guard hasData else { return nil }
        let type = eventType.flatMap { $0.isEmpty ? nil : $0 }
        return ServerSentEvent(event: type, data: dataLines.joined(separator: "\n"), id: eventID, retry: retry)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
