import AIChat
import Foundation
import Testing

@Suite("ServerSentEventParser")
struct ServerSentEventParserTests {
    private func parse(_ text: String, chunkSize: Int = .max) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        let data = Data(text.utf8)
        var events: [ServerSentEvent] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            events += parser.consume(data.subdata(in: offset..<end))
            offset = end
        }
        if let last = parser.finish() { events.append(last) }
        return events
    }

    @Test func parsesDataEvents() {
        let events = parse("data: {\"a\":1}\n\ndata: [DONE]\n\n")
        #expect(events.map(\.data) == [#"{"a":1}"#, "[DONE]"])
    }

    @Test(arguments: [1, 2, 3, 7, 64])
    func handlesEventsSplitAcrossChunks(chunkSize: Int) {
        let events = parse("event: message_start\r\ndata: {\"type\":\"message_start\"}\r\n\r\ndata: é🍰\n\n", chunkSize: chunkSize)
        #expect(events == [
            ServerSentEvent(event: "message_start", data: #"{"type":"message_start"}"#),
            ServerSentEvent(data: "é🍰"),
        ])
    }

    @Test func skipsCommentsAndCountsThem() {
        var parser = ServerSentEventParser()
        let events = parser.consume(Data(": keep-alive\n\ndata: x\n\n: ping\n\n".utf8))
        #expect(events.map(\.data) == ["x"])
        #expect(parser.commentCount == 2)
    }

    @Test func joinsMultilineData() {
        #expect(parse("data: one\ndata: two\ndata:three\n\n").map(\.data) == ["one\ntwo\nthree"])
    }

    @Test func acceptsCarriageReturnLineEndings() {
        #expect(parse("data: a\r\rdata: b\r\r").map(\.data) == ["a", "b"])
    }

    @Test func readsIdAndRetry() {
        let events = parse("id: 7\nretry: 1500\nevent: update\ndata: x\n\n")
        #expect(events == [ServerSentEvent(event: "update", data: "x", id: "7", retry: 1500)])
    }

    @Test func ignoresEventsWithoutData() {
        #expect(parse("event: ping\n\n").isEmpty)
    }

    @Test func dispatchesATrailingEventWithoutBlankLine() {
        #expect(parse("data: last").map(\.data) == ["last"])
    }

    @Test func stripsByteOrderMark() {
        #expect(parse("\u{FEFF}data: x\n\n").map(\.data) == ["x"])
    }

    @Test func keepsOnlyOneLeadingSpace() {
        #expect(parse("data:  two spaces\n\n").map(\.data) == [" two spaces"])
    }
}
