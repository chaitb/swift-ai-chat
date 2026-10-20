import AIChat
import Foundation

extension Array where Element == UIMessageChunk {
    /// A complete response that streams `text` word by word.
    public static func textResponse(
        _ text: String,
        messageId: String? = nil,
        metadata: JSONValue? = nil,
        finishReason: FinishReason = .stop
    ) -> [UIMessageChunk] {
        var chunks: [UIMessageChunk] = [.start(messageId: messageId, messageMetadata: metadata), .startStep, .textStart(id: "text-1")]
        chunks += words(of: text).map { UIMessageChunk.textDelta(id: "text-1", delta: $0) }
        chunks += [.textEnd(id: "text-1"), .finishStep, .finish(finishReason: finishReason)]
        return chunks
    }

    /// A complete response that calls one tool and stops for the client to answer it.
    public static func toolCallResponse(
        toolName: String,
        toolCallId: String = "call-1",
        input: JSONValue,
        messageId: String? = nil,
        dynamic: Bool? = nil
    ) -> [UIMessageChunk] {
        [
            .start(messageId: messageId),
            .startStep,
            .toolInputStart(ToolInputStartChunk(toolCallId: toolCallId, toolName: toolName, dynamic: dynamic)),
            .toolInputDelta(toolCallId: toolCallId, inputTextDelta: input.jsonString),
            .toolInputAvailable(ToolInputAvailableChunk(toolCallId: toolCallId, toolName: toolName, input: input, dynamic: dynamic)),
            .finishStep,
            .finish(finishReason: .toolCalls),
        ]
    }

    private static func words(of text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
