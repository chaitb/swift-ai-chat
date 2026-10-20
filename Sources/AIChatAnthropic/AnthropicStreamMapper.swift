import AIChat
import Foundation

/// Token counts reported by the Messages API.
public struct AnthropicUsage: Sendable, Hashable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheCreationInputTokens = 0
    public var cacheReadInputTokens = 0

    public init() {}

    mutating func update(from value: JSONValue?) {
        guard let value else { return }
        if let tokens = value["input_tokens"]?.intValue { inputTokens = tokens }
        if let tokens = value["output_tokens"]?.intValue { outputTokens = tokens }
        if let tokens = value["cache_creation_input_tokens"]?.intValue { cacheCreationInputTokens = tokens }
        if let tokens = value["cache_read_input_tokens"]?.intValue { cacheReadInputTokens = tokens }
    }

    static func + (lhs: AnthropicUsage, rhs: AnthropicUsage) -> AnthropicUsage {
        var sum = AnthropicUsage()
        sum.inputTokens = lhs.inputTokens + rhs.inputTokens
        sum.outputTokens = lhs.outputTokens + rhs.outputTokens
        sum.cacheCreationInputTokens = lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens
        sum.cacheReadInputTokens = lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        return sum
    }

    var jsonValue: JSONValue {
        [
            "inputTokens": .number(Double(inputTokens)),
            "outputTokens": .number(Double(outputTokens)),
            "cacheCreationInputTokens": .number(Double(cacheCreationInputTokens)),
            "cacheReadInputTokens": .number(Double(cacheReadInputTokens)),
        ]
    }
}

/// Maps the events of one streamed Messages API call to UI message chunks, and
/// rebuilds the response's content blocks for `pause_turn` continuations.
struct AnthropicStreamMapper: Sendable {
    private enum Kind: Sendable {
        case text
        case thinking
        case redactedThinking
        case toolUse(providerExecuted: Bool)
        case toolResult
        case other
    }

    private struct Block: Sendable {
        var kind: Kind
        var partID: String
        var raw: [String: JSONValue]
        var json = ""
        var citations: [TextCitation] = []
        var rawCitations: [JSONValue] = []
    }

    private(set) var partPrefix: String
    private var blocks: [Int: Block] = [:]
    private var emittedSources: Set<String> = []
    private(set) var messageID: String?
    private(set) var model: String?
    private(set) var stopReason: String?
    private(set) var stopDetails: JSONValue?
    private(set) var usage = AnthropicUsage()
    private(set) var finished = false

    init(partPrefix: String) {
        self.partPrefix = partPrefix
    }

    /// The response's content blocks, in order, as they would appear in a non-streamed response.
    var contentBlocks: [JSONValue] {
        blocks.keys.sorted().compactMap { index in
            guard var raw = blocks[index]?.raw, let block = blocks[index] else { return nil }
            if case .toolUse = block.kind, raw["input"] == nil || raw["input"] == [:] {
                raw["input"] = Self.parseInput(block.json) ?? [:]
            }
            if !block.rawCitations.isEmpty { raw["citations"] = .array(block.rawCitations) }
            return .object(raw)
        }
    }

    mutating func map(_ event: ServerSentEvent) throws -> [UIMessageChunk] {
        let value: JSONValue
        do {
            value = try JSONValue(parsing: event.data)
        } catch {
            throw ChatError(kind: .decoding, message: "Anthropic sent an event that isn't valid JSON.", operation: "anthropic.stream", underlying: String(describing: error))
        }
        switch value["type"]?.stringValue ?? event.event {
        case "message_start":
            let message = value["message"]
            messageID = message?["id"]?.stringValue
            if let messageID { partPrefix = messageID }
            model = message?["model"]?.stringValue
            usage.update(from: message?["usage"])
            return [.startStep]
        case "content_block_start":
            guard let index = value["index"]?.intValue, let block = value["content_block"]?.objectValue else { return [] }
            return start(block: block, at: index)
        case "content_block_delta":
            guard let index = value["index"]?.intValue, let delta = value["delta"] else { return [] }
            return apply(delta: delta, at: index)
        case "content_block_stop":
            guard let index = value["index"]?.intValue else { return [] }
            return stop(at: index)
        case "message_delta":
            if let reason = value["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            if let details = value["delta"]?["stop_details"], !details.isNull { stopDetails = details }
            usage.update(from: value["usage"])
            return []
        case "message_stop":
            finished = true
            return [.finishStep]
        case "error":
            throw Self.streamError(value["error"])
        default:
            return []
        }
    }

    static func streamError(_ error: JSONValue?) -> ChatError {
        let type = error?["type"]?.stringValue ?? "api_error"
        let message = error?["message"]?.stringValue ?? "Anthropic reported an error."
        let retryable = ["overloaded_error", "api_error", "rate_limit_error", "timeout_error"].contains(type)
        return ChatError(kind: .stream, message: message, code: type, isRetryable: retryable, operation: "anthropic.stream")
    }

    // MARK: - Blocks

    private mutating func start(block: [String: JSONValue], at index: Int) -> [UIMessageChunk] {
        let type = block["type"]?.stringValue ?? ""
        let partID = "\(partPrefix)-\(index)"
        switch type {
        case "text":
            blocks[index] = Block(kind: .text, partID: partID, raw: ["type": "text", "text": ""])
            var chunks: [UIMessageChunk] = [.textStart(id: partID)]
            if let text = block["text"]?.stringValue, !text.isEmpty {
                blocks[index]?.raw["text"] = .string(text)
                chunks.append(.textDelta(id: partID, delta: text))
            }
            return chunks
        case "thinking":
            blocks[index] = Block(kind: .thinking, partID: partID, raw: ["type": "thinking", "thinking": "", "signature": ""])
            var chunks: [UIMessageChunk] = [.reasoningStart(id: partID)]
            if let text = block["thinking"]?.stringValue, !text.isEmpty {
                blocks[index]?.raw["thinking"] = .string(text)
                chunks.append(.reasoningDelta(id: partID, delta: text))
            }
            return chunks
        case "redacted_thinking":
            blocks[index] = Block(kind: .redactedThinking, partID: partID, raw: block)
            return [.reasoningStart(id: partID, providerMetadata: ["anthropic": ["redactedData": block["data"] ?? ""]])]
        case "tool_use", "server_tool_use", "mcp_tool_use":
            let providerExecuted = type != "tool_use"
            blocks[index] = Block(kind: .toolUse(providerExecuted: providerExecuted), partID: partID, raw: block)
            guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return [] }
            var metadata: [String: JSONValue] = [:]
            if type != "tool_use" { metadata["type"] = .string(type) }
            if let serverName = block["server_name"] { metadata["serverName"] = serverName }
            return [.toolInputStart(ToolInputStartChunk(
                toolCallId: id,
                toolName: name,
                providerExecuted: providerExecuted ? true : nil,
                providerMetadata: metadata.isEmpty ? nil : ["anthropic": .object(metadata)],
                dynamic: type == "mcp_tool_use" ? true : nil
            ))]
        default:
            if type.hasSuffix("_tool_result"), let toolUseID = block["tool_use_id"]?.stringValue {
                blocks[index] = Block(kind: .toolResult, partID: partID, raw: block)
                return toolResult(type: type, toolUseID: toolUseID, content: block["content"] ?? .null)
            }
            blocks[index] = Block(kind: .other, partID: partID, raw: block)
            if type == "fallback" {
                return [.custom(kind: "anthropic.fallback", providerMetadata: ["anthropic": .object(block)])]
            }
            return []
        }
    }

    private mutating func apply(delta: JSONValue, at index: Int) -> [UIMessageChunk] {
        guard var block = blocks[index] else { return [] }
        defer { blocks[index] = block }
        switch delta["type"]?.stringValue {
        case "text_delta":
            guard let text = delta["text"]?.stringValue, !text.isEmpty else { return [] }
            block.raw["text"] = .string((block.raw["text"]?.stringValue ?? "") + text)
            return [.textDelta(id: block.partID, delta: text)]
        case "thinking_delta":
            guard let text = delta["thinking"]?.stringValue, !text.isEmpty else { return [] }
            block.raw["thinking"] = .string((block.raw["thinking"]?.stringValue ?? "") + text)
            return [.reasoningDelta(id: block.partID, delta: text)]
        case "signature_delta":
            guard case .thinking = block.kind, let signature = delta["signature"]?.stringValue else { return [] }
            block.raw["signature"] = .string(signature)
            return [.reasoningDelta(id: block.partID, delta: "", providerMetadata: ["anthropic": ["signature": .string(signature)]])]
        case "input_json_delta":
            guard let json = delta["partial_json"]?.stringValue, !json.isEmpty else { return [] }
            block.json += json
            guard let id = block.raw["id"]?.stringValue else { return [] }
            return [.toolInputDelta(toolCallId: id, inputTextDelta: json)]
        case "citations_delta":
            guard let citation = delta["citation"] else { return [] }
            block.rawCitations.append(citation)
            guard let (textCitation, chunk) = Self.citation(from: citation) else { return [] }
            block.citations.append(textCitation)
            return emitSource(chunk)
        default:
            return []
        }
    }

    private mutating func stop(at index: Int) -> [UIMessageChunk] {
        guard let block = blocks[index] else { return [] }
        switch block.kind {
        case .text:
            return [.textEnd(id: block.partID, citations: block.citations.isEmpty ? nil : block.citations)]
        case .thinking, .redactedThinking:
            return [.reasoningEnd(id: block.partID)]
        case .toolUse(let providerExecuted):
            guard let id = block.raw["id"]?.stringValue, let name = block.raw["name"]?.stringValue else { return [] }
            let type = block.raw["type"]?.stringValue ?? "tool_use"
            var metadata: [String: JSONValue] = [:]
            if type != "tool_use" { metadata["type"] = .string(type) }
            if let serverName = block.raw["server_name"] { metadata["serverName"] = serverName }
            let providerMetadata: JSONValue? = metadata.isEmpty ? nil : ["anthropic": .object(metadata)]
            let initial = block.raw["input"].flatMap { $0 == [:] ? nil : $0 }
            let text = block.json.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                blocks[index]?.raw["input"] = initial ?? [:]
                return [.toolInputAvailable(ToolInputAvailableChunk(
                    toolCallId: id,
                    toolName: name,
                    input: initial ?? [:],
                    providerExecuted: providerExecuted ? true : nil,
                    providerMetadata: providerMetadata,
                    dynamic: type == "mcp_tool_use" ? true : nil
                ))]
            }
            guard let input = Self.parseInput(text) else {
                return [.toolInputError(ToolInputErrorChunk(
                    toolCallId: id,
                    toolName: name,
                    input: .string(block.json),
                    errorText: "The tool input isn't valid JSON.",
                    providerExecuted: providerExecuted ? true : nil,
                    providerMetadata: providerMetadata,
                    dynamic: type == "mcp_tool_use" ? true : nil
                ))]
            }
            blocks[index]?.raw["input"] = input
            return [.toolInputAvailable(ToolInputAvailableChunk(
                toolCallId: id,
                toolName: name,
                input: input,
                providerExecuted: providerExecuted ? true : nil,
                providerMetadata: providerMetadata,
                dynamic: type == "mcp_tool_use" ? true : nil
            ))]
        case .toolResult, .other:
            return []
        }
    }

    private static func parseInput(_ text: String) -> JSONValue? {
        guard !text.isEmpty, let value = try? JSONValue(parsing: text), case .object = value else { return nil }
        return value
    }

    // MARK: - Tool results and sources

    private mutating func toolResult(type: String, toolUseID: String, content: JSONValue) -> [UIMessageChunk] {
        let metadata: JSONValue = ["anthropic": ["type": .string(type)]]
        if let errorCode = content["error_code"]?.stringValue {
            return [.toolOutputError(ToolOutputErrorChunk(toolCallId: toolUseID, errorText: errorCode, providerExecuted: true, providerMetadata: metadata))]
        }
        var chunks: [UIMessageChunk] = [
            .toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: toolUseID, output: content, providerExecuted: true, providerMetadata: metadata)),
        ]
        if type == "web_search_tool_result", let results = content.arrayValue {
            for result in results {
                guard let url = result["url"]?.stringValue else { continue }
                var providerMetadata: JSONValue?
                if let pageAge = result["page_age"], !pageAge.isNull { providerMetadata = ["anthropic": ["pageAge": pageAge]] }
                chunks += emitSource(.sourceURL(SourceURLPart(sourceId: url, url: url, title: result["title"]?.stringValue, providerMetadata: providerMetadata)))
            }
        }
        return chunks
    }

    private mutating func emitSource(_ chunk: UIMessageChunk) -> [UIMessageChunk] {
        let key: String
        switch chunk {
        case .sourceURL(let source): key = "url:\(source.url)"
        case .sourceDocument(let source): key = "doc:\(source.sourceId)"
        default: return [chunk]
        }
        guard emittedSources.insert(key).inserted else { return [] }
        return [chunk]
    }

    static func citation(from value: JSONValue) -> (TextCitation, UIMessageChunk)? {
        let citedText = value["cited_text"]?.stringValue
        switch value["type"]?.stringValue {
        case "web_search_result_location":
            guard let url = value["url"]?.stringValue else { return nil }
            let source = SourceURLPart(sourceId: url, url: url, title: value["title"]?.stringValue)
            return (TextCitation(source: .url(source), citedText: citedText), .sourceURL(source))
        case "search_result_location":
            guard let url = value["source"]?.stringValue else { return nil }
            let source = SourceURLPart(sourceId: url, url: url, title: value["title"]?.stringValue)
            return (TextCitation(source: .url(source), citedText: citedText), .sourceURL(source))
        case "char_location", "page_location", "content_block_location":
            let index = value["document_index"]?.intValue ?? 0
            let mediaType = value["type"] == "page_location" ? "application/pdf" : "text/plain"
            let title = value["document_title"]?.stringValue ?? "Document \(index + 1)"
            let source = SourceDocumentPart(sourceId: "document-\(index)", mediaType: mediaType, title: title)
            return (TextCitation(source: .document(source), citedText: citedText), .sourceDocument(source))
        default:
            return nil
        }
    }
}
