import AIChat
import Foundation

/// Maps the chunks of one streamed Chat Completions call to UI message chunks.
///
/// Text and reasoning parts open on their first delta. Tool calls stream their
/// arguments and are completed when the choice finishes. Reasoning deltas are read
/// from `reasoning_content` or `reasoning`, which OpenAI-compatible servers use.
struct OpenAIChatCompletionsStreamMapper: Sendable {
    private struct ToolCall: Sendable {
        var id: String
        var name: String
        var arguments: String
    }

    private let partPrefix: String
    private var started = false
    private var textOpen = false
    private var reasoningOpen = false
    private var reasoningCount = 0
    private var textCount = 0
    private var toolCalls: [Int: ToolCall] = [:]
    private var emittedSources: Set<String> = []
    private var closed = false
    private(set) var responseID: String?
    private(set) var model: String?
    private(set) var rawFinishReason: String?
    private(set) var usage = OpenAIUsage()
    private(set) var finished = false

    init(partPrefix: String) {
        self.partPrefix = partPrefix
    }

    mutating func map(_ event: ServerSentEvent) throws -> [UIMessageChunk] {
        if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            finished = true
            return close()
        }
        let value: JSONValue
        do {
            value = try JSONValue(parsing: event.data)
        } catch {
            throw ChatError(kind: .decoding, message: "The server sent a chunk that isn't valid JSON.", operation: "openai.chat.stream", underlying: String(describing: error))
        }
        if let error = value["error"], !error.isNull {
            throw Self.streamError(error)
        }
        var chunks: [UIMessageChunk] = []
        if !started {
            started = true
            chunks.append(.startStep)
        }
        if let id = value["id"]?.stringValue { responseID = id }
        if let model = value["model"]?.stringValue { self.model = model }
        usage.updateFromChatCompletions(value["usage"])

        guard let choice = value["choices"]?.arrayValue?.first(where: { ($0["index"]?.intValue ?? 0) == 0 }) else { return chunks }
        let delta = choice["delta"]
        if let reasoning = (delta?["reasoning_content"] ?? delta?["reasoning"])?.stringValue, !reasoning.isEmpty {
            if textOpen { chunks.append(endText()) }
            if !reasoningOpen {
                reasoningOpen = true
                reasoningCount += 1
                chunks.append(.reasoningStart(id: reasoningID))
            }
            chunks.append(.reasoningDelta(id: reasoningID, delta: reasoning))
        }
        if let content = (delta?["content"] ?? delta?["refusal"])?.stringValue, !content.isEmpty {
            if reasoningOpen { chunks.append(endReasoning()) }
            if !textOpen {
                textOpen = true
                textCount += 1
                chunks.append(.textStart(id: textID))
            }
            chunks.append(.textDelta(id: textID, delta: content))
        }
        for annotation in delta?["annotations"]?.arrayValue ?? [] {
            let citation = annotation["url_citation"] ?? annotation
            guard let url = citation["url"]?.stringValue, emittedSources.insert(url).inserted else { continue }
            chunks.append(.sourceURL(SourceURLPart(sourceId: "\(partPrefix)-source-\(emittedSources.count)", url: url, title: citation["title"]?.stringValue)))
        }
        for call in delta?["tool_calls"]?.arrayValue ?? [] {
            let index = call["index"]?.intValue ?? toolCalls.count
            let argumentsDelta = call["function"]?["arguments"]?.stringValue ?? ""
            if var existing = toolCalls[index] {
                existing.arguments += argumentsDelta
                toolCalls[index] = existing
                if !argumentsDelta.isEmpty {
                    chunks.append(.toolInputDelta(toolCallId: existing.id, inputTextDelta: argumentsDelta))
                }
            } else {
                if reasoningOpen { chunks.append(endReasoning()) }
                if textOpen { chunks.append(endText()) }
                let id = call["id"]?.stringValue ?? "\(partPrefix)-call-\(index)"
                let name = call["function"]?["name"]?.stringValue ?? "function"
                toolCalls[index] = ToolCall(id: id, name: name, arguments: argumentsDelta)
                chunks.append(.toolInputStart(ToolInputStartChunk(toolCallId: id, toolName: name)))
                if !argumentsDelta.isEmpty {
                    chunks.append(.toolInputDelta(toolCallId: id, inputTextDelta: argumentsDelta))
                }
            }
        }
        if let reason = choice["finish_reason"]?.stringValue {
            rawFinishReason = reason
        }
        return chunks
    }

    /// Closes open parts and completes tool calls. Safe to call more than once.
    mutating func close() -> [UIMessageChunk] {
        guard started, !closed else { return [] }
        closed = true
        var chunks: [UIMessageChunk] = []
        if reasoningOpen { chunks.append(endReasoning()) }
        if textOpen { chunks.append(endText()) }
        for index in toolCalls.keys.sorted() {
            guard let call = toolCalls[index] else { continue }
            let text = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                chunks.append(.toolInputAvailable(ToolInputAvailableChunk(toolCallId: call.id, toolName: call.name, input: [:])))
            } else if let input = try? JSONValue(parsing: text) {
                chunks.append(.toolInputAvailable(ToolInputAvailableChunk(toolCallId: call.id, toolName: call.name, input: input)))
            } else {
                chunks.append(.toolInputError(ToolInputErrorChunk(
                    toolCallId: call.id,
                    toolName: call.name,
                    input: .string(call.arguments),
                    errorText: "The tool input isn't valid JSON."
                )))
            }
        }
        chunks.append(.finishStep)
        return chunks
    }

    var hasFinishReason: Bool { rawFinishReason != nil }

    var finishReason: FinishReason {
        switch rawFinishReason {
        case "stop": .stop
        case "length": .length
        case "tool_calls", "function_call": .toolCalls
        case "content_filter": .contentFilter
        case nil: toolCalls.isEmpty ? .other : .toolCalls
        case let reason?: .unknown(reason)
        }
    }

    static func streamError(_ error: JSONValue) -> ChatError {
        let code = error["code"]?.stringValue ?? error["type"]?.stringValue ?? "server_error"
        let message = error["message"]?.stringValue ?? "The server reported an error."
        let retryable = ["server_error", "rate_limit_exceeded", "overloaded", "server_is_overloaded"].contains(code)
        return ChatError(kind: .stream, message: message, code: code, isRetryable: retryable, operation: "openai.chat.stream")
    }

    private var textID: String { "\(partPrefix)-text-\(textCount)" }
    private var reasoningID: String { "\(partPrefix)-reasoning-\(reasoningCount)" }

    private mutating func endText() -> UIMessageChunk {
        textOpen = false
        return .textEnd(id: textID)
    }

    private mutating func endReasoning() -> UIMessageChunk {
        reasoningOpen = false
        return .reasoningEnd(id: reasoningID)
    }
}
