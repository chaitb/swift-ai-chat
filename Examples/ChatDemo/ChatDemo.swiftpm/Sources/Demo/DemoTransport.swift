import AIChat
import Foundation

struct DemoTransport: ChatTransport {
    func sendMessages(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream {
        let beats = DemoScript.beats(for: request.messages, continuing: request.messageID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for beat in beats {
                        try await play(beat, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func play(_ beat: DemoBeat, into continuation: AsyncThrowingStream<UIMessageChunk, any Error>.Continuation) async throws {
        switch beat {
        case .chunk(let chunk):
            continuation.yield(chunk)
        case .wait(let range):
            try await Task.sleep(for: .milliseconds(Int.random(in: range)))
        case .text(let id, let text):
            continuation.yield(.textStart(id: id))
            for token in Self.tokens(of: text) {
                try await Task.sleep(for: .milliseconds(Self.delay(after: token, base: 16...48)))
                continuation.yield(.textDelta(id: id, delta: token))
            }
            continuation.yield(.textEnd(id: id))
        case .reasoning(let id, let text):
            continuation.yield(.reasoningStart(id: id))
            for token in Self.tokens(of: text) {
                try await Task.sleep(for: .milliseconds(Self.delay(after: token, base: 14...36)))
                continuation.yield(.reasoningDelta(id: id, delta: token))
            }
            continuation.yield(.reasoningEnd(id: id))
        case .toolInput(let callID, let name, let input):
            continuation.yield(.toolInputStart(ToolInputStartChunk(toolCallId: callID, toolName: name)))
            var json = Substring(input.jsonString)
            while !json.isEmpty {
                let size = Int.random(in: 3...7)
                try await Task.sleep(for: .milliseconds(Int.random(in: 30...70)))
                continuation.yield(.toolInputDelta(toolCallId: callID, inputTextDelta: String(json.prefix(size))))
                json = json.dropFirst(size)
            }
            continuation.yield(.toolInputAvailable(ToolInputAvailableChunk(toolCallId: callID, toolName: name, input: input)))
        }
    }

    private static func tokens(of text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var words = 0
        let target = { Int.random(in: 1...2) }
        var limit = target()
        for character in text {
            current.append(character)
            if character == " " || character == "\n" {
                words += 1
                if words >= limit || character == "\n" {
                    tokens.append(current)
                    current = ""
                    words = 0
                    limit = target()
                }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func delay(after token: String, base: ClosedRange<Int>) -> Int {
        var delay = Int.random(in: base)
        if token.hasSuffix("\n") { delay += Int.random(in: 90...200) }
        else if let last = token.trimmingCharacters(in: .whitespaces).last, ".!?:".contains(last) { delay += Int.random(in: 60...160) }
        else if token.hasSuffix(", ") { delay += Int.random(in: 20...60) }
        if Int.random(in: 0..<24) == 0 { delay += Int.random(in: 120...280) }
        return delay
    }
}

enum DemoBeat: Sendable {
    case chunk(UIMessageChunk)
    case wait(ClosedRange<Int>)
    case text(id: String, String)
    case reasoning(id: String, String)
    case toolInput(callID: String, name: String, input: JSONValue)
}
