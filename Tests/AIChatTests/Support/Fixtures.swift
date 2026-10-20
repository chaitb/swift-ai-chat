import AIChat
import Foundation

enum Fixtures {
    static func url(_ path: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    static func text(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }

    static func json(_ path: String) throws -> JSONValue {
        try JSONValue(parsing: data(path))
    }

    /// Decodes every chunk of a recorded `text/event-stream` body.
    static func chunks(_ path: String) throws -> [UIMessageChunk] {
        var parser = ServerSentEventParser()
        var events = parser.consume(try data(path))
        if let last = parser.finish() { events.append(last) }
        return try events.compactMap { try UIMessageStream.decodeEvent($0.data) }
    }
}
