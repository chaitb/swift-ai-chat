import AIChat
import Foundation

/// Token counts reported by the OpenAI API.
public struct OpenAIUsage: Sendable, Hashable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cachedInputTokens = 0
    public var reasoningTokens = 0

    public init() {}

    mutating func updateFromResponses(_ value: JSONValue?) {
        guard let value, !value.isNull else { return }
        if let tokens = value["input_tokens"]?.intValue { inputTokens = tokens }
        if let tokens = value["output_tokens"]?.intValue { outputTokens = tokens }
        if let tokens = value["input_tokens_details"]?["cached_tokens"]?.intValue { cachedInputTokens = tokens }
        if let tokens = value["output_tokens_details"]?["reasoning_tokens"]?.intValue { reasoningTokens = tokens }
    }

    mutating func updateFromChatCompletions(_ value: JSONValue?) {
        guard let value, !value.isNull else { return }
        if let tokens = value["prompt_tokens"]?.intValue { inputTokens = tokens }
        if let tokens = value["completion_tokens"]?.intValue { outputTokens = tokens }
        if let tokens = value["prompt_tokens_details"]?["cached_tokens"]?.intValue { cachedInputTokens = tokens }
        if let tokens = value["completion_tokens_details"]?["reasoning_tokens"]?.intValue { reasoningTokens = tokens }
    }

    var jsonValue: JSONValue {
        [
            "inputTokens": .number(Double(inputTokens)),
            "outputTokens": .number(Double(outputTokens)),
            "cachedInputTokens": .number(Double(cachedInputTokens)),
            "reasoningTokens": .number(Double(reasoningTokens)),
        ]
    }
}

/// Maps the events of one streamed Responses API call to UI message chunks.
struct OpenAIResponsesStreamMapper: Sendable {
    private enum Kind: Sendable {
        case message(phase: JSONValue?)
        case reasoning(openSummaries: [Int])
        case functionCall(callID: String, name: String)
        case hostedTool(name: String)
        case other
    }

    private struct Item: Sendable {
        var kind: Kind
        var id: String
    }

    private var items: [Int: Item] = [:]
    private var itemIndexByID: [String: Int] = [:]
    private var emittedSources: Set<String> = []
    private(set) var responseID: String?
    private(set) var model: String?
    private(set) var status: String?
    private(set) var incompleteReason: String?
    private(set) var usage = OpenAIUsage()
    private(set) var finished = false
    private(set) var calledFunctions = false
    private(set) var refused = false

    mutating func map(_ event: ServerSentEvent) throws -> [UIMessageChunk] {
        let value: JSONValue
        do {
            value = try JSONValue(parsing: event.data)
        } catch {
            throw ChatError(kind: .decoding, message: "OpenAI sent an event that isn't valid JSON.", operation: "openai.responses.stream", underlying: String(describing: error))
        }
        switch value["type"]?.stringValue ?? event.event {
        case "response.created":
            readResponse(value["response"])
            return [.startStep]
        case "response.in_progress":
            readResponse(value["response"])
            return []
        case "response.output_item.added":
            guard let index = value["output_index"]?.intValue, let item = value["item"] else { return [] }
            return added(item, at: index)
        case "response.output_item.done":
            guard let index = value["output_index"]?.intValue, let item = value["item"] else { return [] }
            return done(item, at: index)
        case "response.output_text.delta":
            guard let id = value["item_id"]?.stringValue, let delta = value["delta"]?.stringValue, !delta.isEmpty else { return [] }
            return [.textDelta(id: id, delta: delta)]
        case "response.refusal.delta":
            guard let id = value["item_id"]?.stringValue, let delta = value["delta"]?.stringValue, !delta.isEmpty else { return [] }
            refused = true
            return [.textDelta(id: id, delta: delta)]
        case "response.output_text.annotation.added":
            return source(value["annotation"])
        case "response.reasoning_summary_part.added":
            guard let id = value["item_id"]?.stringValue, let summary = value["summary_index"]?.intValue else { return [] }
            return openSummary(summary, itemID: id)
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let id = value["item_id"]?.stringValue, let delta = value["delta"]?.stringValue, !delta.isEmpty else { return [] }
            let summary = value["summary_index"]?.intValue ?? 0
            var chunks = openSummary(summary, itemID: id)
            chunks.append(.reasoningDelta(id: "\(id):\(summary)", delta: delta))
            return chunks
        case "response.function_call_arguments.delta":
            guard
                let id = value["item_id"]?.stringValue,
                let index = itemIndexByID[id],
                case .functionCall(let callID, _)? = items[index]?.kind,
                let delta = value["delta"]?.stringValue,
                !delta.isEmpty
            else { return [] }
            return [.toolInputDelta(toolCallId: callID, inputTextDelta: delta)]
        case "response.completed", "response.incomplete":
            readResponse(value["response"])
            finished = true
            return [.finishStep]
        case "response.failed":
            readResponse(value["response"])
            throw Self.streamError(value["response"]?["error"])
        case "error":
            throw Self.streamError(value["error"] ?? value)
        default:
            return []
        }
    }

    private mutating func readResponse(_ response: JSONValue?) {
        guard let response else { return }
        if let id = response["id"]?.stringValue { responseID = id }
        if let model = response["model"]?.stringValue { self.model = model }
        if let status = response["status"]?.stringValue { self.status = status }
        if let reason = response["incomplete_details"]?["reason"]?.stringValue { incompleteReason = reason }
        usage.updateFromResponses(response["usage"])
    }

    static func streamError(_ error: JSONValue?) -> ChatError {
        let code = error?["code"]?.stringValue ?? error?["type"]?.stringValue ?? "server_error"
        let message = error?["message"]?.stringValue ?? "OpenAI reported an error."
        let retryable = ["server_error", "rate_limit_exceeded", "overloaded", "server_is_overloaded", "slow_down"].contains(code)
        return ChatError(kind: .stream, message: message, code: code, isRetryable: retryable, operation: "openai.responses.stream")
    }

    var finishReason: FinishReason {
        if status == "incomplete" {
            switch incompleteReason {
            case "max_output_tokens": return .length
            case "content_filter": return .contentFilter
            case let reason?: return .unknown(reason)
            case nil: return .other
            }
        }
        if refused { return .contentFilter }
        return calledFunctions ? .toolCalls : .stop
    }

    // MARK: - Items

    private mutating func added(_ item: JSONValue, at index: Int) -> [UIMessageChunk] {
        let type = item["type"]?.stringValue ?? ""
        let id = item["id"]?.stringValue ?? "\(responseID ?? "item")-\(index)"
        itemIndexByID[id] = index
        switch type {
        case "message":
            items[index] = Item(kind: .message(phase: item["phase"]), id: id)
            return [.textStart(id: id, providerMetadata: textMetadata(id: id, phase: item["phase"]))]
        case "reasoning":
            items[index] = Item(kind: .reasoning(openSummaries: [0]), id: id)
            return [.reasoningStart(id: "\(id):0", providerMetadata: ["openai": ["itemId": .string(id)]])]
        case "function_call":
            let callID = item["call_id"]?.stringValue ?? id
            let name = item["name"]?.stringValue ?? "function"
            items[index] = Item(kind: .functionCall(callID: callID, name: name), id: id)
            return [.toolInputStart(ToolInputStartChunk(
                toolCallId: callID,
                toolName: name,
                providerMetadata: ["openai": ["itemId": .string(id)]]
            ))]
        default:
            guard type.hasSuffix("_call") else {
                items[index] = Item(kind: .other, id: id)
                return []
            }
            let name = String(type.dropLast("_call".count))
            items[index] = Item(kind: .hostedTool(name: name), id: id)
            return [.toolInputStart(ToolInputStartChunk(
                toolCallId: id,
                toolName: name,
                providerExecuted: true,
                providerMetadata: ["openai": ["itemId": .string(id)]]
            ))]
        }
    }

    private mutating func done(_ item: JSONValue, at index: Int) -> [UIMessageChunk] {
        guard let stored = items[index] else { return [] }
        let id = stored.id
        switch stored.kind {
        case .message(let phase):
            var chunks: [UIMessageChunk] = []
            for content in item["content"]?.arrayValue ?? [] {
                for annotation in content["annotations"]?.arrayValue ?? [] {
                    chunks += source(annotation)
                }
            }
            chunks.append(.textEnd(id: id, providerMetadata: textMetadata(id: id, phase: item["phase"] ?? phase)))
            return chunks
        case .reasoning(let openSummaries):
            var metadata: [String: JSONValue] = ["itemId": .string(id)]
            if let encrypted = item["encrypted_content"], !encrypted.isNull { metadata["encryptedContent"] = encrypted }
            return openSummaries.map { summary in
                .reasoningEnd(id: "\(id):\(summary)", providerMetadata: ["openai": .object(metadata)])
            }
        case .functionCall(let callID, let name):
            calledFunctions = true
            let text = (item["arguments"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let metadata: JSONValue = ["openai": ["itemId": .string(id)]]
            guard !text.isEmpty else {
                return [.toolInputAvailable(ToolInputAvailableChunk(toolCallId: callID, toolName: name, input: [:], providerMetadata: metadata))]
            }
            guard let input = try? JSONValue(parsing: text) else {
                return [.toolInputError(ToolInputErrorChunk(
                    toolCallId: callID,
                    toolName: name,
                    input: .string(text),
                    errorText: "The tool input isn't valid JSON.",
                    providerMetadata: metadata
                ))]
            }
            return [.toolInputAvailable(ToolInputAvailableChunk(toolCallId: callID, toolName: name, input: input, providerMetadata: metadata))]
        case .hostedTool(let name):
            let metadata: JSONValue = ["openai": ["itemId": .string(id)]]
            var output = item.objectValue ?? [:]
            for key in ["id", "type", "action", "arguments"] { output[key] = nil }
            var chunks: [UIMessageChunk] = [
                .toolInputAvailable(ToolInputAvailableChunk(
                    toolCallId: id,
                    toolName: name,
                    input: item["action"] ?? item["arguments"] ?? [:],
                    providerExecuted: true,
                    providerMetadata: metadata
                )),
            ]
            if item["status"] == "failed" {
                chunks.append(.toolOutputError(ToolOutputErrorChunk(
                    toolCallId: id,
                    errorText: item["error"]?.stringValue ?? "The \(name) call failed.",
                    providerExecuted: true,
                    providerMetadata: metadata
                )))
            } else {
                chunks.append(.toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: id, output: .object(output), providerExecuted: true, providerMetadata: metadata)))
            }
            for source in item["action"]?["sources"]?.arrayValue ?? [] {
                chunks += self.source(["type": "url_citation", "url": source["url"] ?? .null, "title": source["title"] ?? .null])
            }
            return chunks
        case .other:
            return []
        }
    }

    private mutating func openSummary(_ summary: Int, itemID: String) -> [UIMessageChunk] {
        guard let index = itemIndexByID[itemID], var item = items[index], case .reasoning(var open) = item.kind, !open.contains(summary) else { return [] }
        var chunks: [UIMessageChunk] = []
        let metadata: JSONValue = ["openai": ["itemId": .string(itemID)]]
        for previous in open {
            chunks.append(.reasoningEnd(id: "\(itemID):\(previous)", providerMetadata: metadata))
        }
        open = [summary]
        item.kind = .reasoning(openSummaries: open)
        items[index] = item
        chunks.append(.reasoningStart(id: "\(itemID):\(summary)", providerMetadata: metadata))
        return chunks
    }

    private func textMetadata(id: String, phase: JSONValue?) -> JSONValue {
        var metadata: [String: JSONValue] = ["itemId": .string(id)]
        if let phase, !phase.isNull { metadata["phase"] = phase }
        return ["openai": .object(metadata)]
    }

    private mutating func source(_ annotation: JSONValue?) -> [UIMessageChunk] {
        guard let annotation else { return [] }
        switch annotation["type"]?.stringValue {
        case "url_citation":
            guard let url = annotation["url"]?.stringValue, emittedSources.insert(url).inserted else { return [] }
            return [.sourceURL(SourceURLPart(sourceId: "source-\(emittedSources.count)", url: url, title: annotation["title"]?.stringValue))]
        case "file_citation":
            guard let fileID = annotation["file_id"]?.stringValue, emittedSources.insert(fileID).inserted else { return [] }
            let filename = annotation["filename"]?.stringValue
            return [.sourceDocument(SourceDocumentPart(
                sourceId: "source-\(emittedSources.count)",
                mediaType: "application/octet-stream",
                title: filename ?? fileID,
                filename: filename,
                providerMetadata: ["openai": ["fileId": .string(fileID)]]
            ))]
        default:
            return []
        }
    }
}
