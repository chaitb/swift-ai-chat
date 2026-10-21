import AIChat
import Foundation

/// Converts UI messages to the Messages API request format.
///
/// Each assistant step becomes an assistant turn, and the results of its client-side
/// tool calls become the user turn that follows, as the API requires. Thinking blocks
/// keep their signatures so they can be passed back unchanged.
enum AnthropicMessageConverter {
    struct Converted {
        var system: [JSONValue]
        var messages: [JSONValue]
    }

    static func convert(_ messages: [UIMessage], configuration: AnthropicConfiguration) async throws -> Converted {
        var system: [JSONValue] = []
        if let prompt = configuration.system, !prompt.isEmpty {
            system.append(["type": "text", "text": .string(prompt)])
        }
        var turns: [(role: String, content: [JSONValue])] = []

        for message in messages {
            switch message.role {
            case .system:
                let text = message.text
                if !text.isEmpty { system.append(["type": "text", "text": .string(text)]) }
            case .user:
                let content = try await userContent(message, configuration: configuration)
                if !content.isEmpty { turns.append(("user", content)) }
            case .assistant:
                for step in message.steps {
                    let (assistant, results) = assistantStep(step)
                    if !assistant.isEmpty { turns.append(("assistant", assistant)) }
                    if !results.isEmpty { turns.append(("user", results)) }
                }
            }
        }

        var merged: [(role: String, content: [JSONValue])] = []
        for turn in turns {
            if let last = merged.last, last.role == turn.role {
                if turn.role == "user" {
                    let results = (last.content + turn.content).filter { $0["type"] == "tool_result" }
                    let others = (last.content + turn.content).filter { $0["type"] != "tool_result" }
                    merged[merged.count - 1].content = results + others
                } else {
                    merged[merged.count - 1].content += turn.content
                }
            } else {
                merged.append(turn)
            }
        }
        return Converted(
            system: system,
            messages: merged.map { ["role": .string($0.role), "content": .array($0.content)] }
        )
    }

    static func userContent(_ message: UIMessage, configuration: AnthropicConfiguration) async throws -> [JSONValue] {
        var content: [JSONValue] = []
        for part in message.parts {
            if let block = try await userBlock(part, configuration: configuration) {
                content.append(block)
            }
        }
        return content
    }

    private static func userBlock(_ part: UIMessagePart, configuration: AnthropicConfiguration) async throws -> JSONValue? {
        switch part {
        case .text(let text):
            return text.text.isEmpty ? nil : ["type": "text", "text": .string(text.text)]
        case .file(let file):
            guard let resolved = try await configuration.fileResolver(file) else { return nil }
            return try fileBlock(resolved, filename: file.filename)
        case .data(let data):
            guard let text = configuration.dataPartConverter?(data), !text.isEmpty else { return nil }
            return ["type": "text", "text": .string(text)]
        default:
            return nil
        }
    }

    static func fileBlock(_ file: ResolvedFile, filename: String?) throws -> JSONValue {
        let mediaType = file.mediaType.lowercased()
        let isImage = mediaType.hasPrefix("image/")
        let source: JSONValue
        switch file {
        case .data(let data, _):
            if !isImage, mediaType.hasPrefix("text/") {
                source = ["type": "text", "media_type": "text/plain", "data": .string(String(decoding: data, as: UTF8.self))]
            } else {
                source = ["type": "base64", "media_type": .string(file.mediaType), "data": .string(data.base64EncodedString())]
            }
        case .url(let url, _):
            source = ["type": "url", "url": .string(url.absoluteString)]
        case .text(let text, _):
            source = ["type": "text", "media_type": "text/plain", "data": .string(text)]
        case .providerFileID(let id, _):
            source = ["type": "file", "file_id": .string(id)]
        }
        if isImage {
            return ["type": "image", "source": source]
        }
        guard mediaType == "application/pdf" || mediaType.hasPrefix("text/") || isTextSource(source) else {
            throw ChatError(
                kind: .configuration,
                message: "Claude can't read \(file.mediaType) attachments. Send images, PDFs or text.",
                code: "unsupported_media_type"
            )
        }
        var block: [String: JSONValue] = ["type": "document", "source": source]
        if let filename { block["title"] = .string(filename) }
        return .object(block)
    }

    private static func isTextSource(_ source: JSONValue) -> Bool {
        source["type"] == "text" || source["type"] == "file"
    }

    static func assistantStep(_ parts: [UIMessagePart]) -> (assistant: [JSONValue], results: [JSONValue]) {
        var assistant: [JSONValue] = []
        var results: [JSONValue] = []
        for part in parts {
            switch part {
            case .text(let text):
                if !text.text.isEmpty { assistant.append(["type": "text", "text": .string(text.text)]) }
            case .reasoning(let reasoning):
                let metadata = reasoning.providerMetadata?["anthropic"]
                if let signature = metadata?["signature"]?.stringValue {
                    assistant.append(["type": "thinking", "thinking": .string(reasoning.text), "signature": .string(signature)])
                } else if let data = metadata?["redactedData"]?.stringValue {
                    assistant.append(["type": "redacted_thinking", "data": .string(data)])
                }
            case .tool(let tool):
                let input = toolInput(tool)
                if tool.providerExecuted == true {
                    guard tool.callProviderMetadata?["anthropic"] != nil else { continue }
                    let useType = tool.callProviderMetadata?["anthropic"]?["type"]?.stringValue ?? "server_tool_use"
                    var use: [String: JSONValue] = ["type": .string(useType), "id": .string(tool.toolCallId), "name": .string(tool.toolName), "input": input]
                    if let serverName = tool.callProviderMetadata?["anthropic"]?["serverName"] { use["server_name"] = serverName }
                    assistant.append(.object(use))
                    if let output = tool.output ?? tool.resultProviderMetadata?["anthropic"]?["errorContent"] {
                        let resultType = tool.resultProviderMetadata?["anthropic"]?["type"]?.stringValue ?? "\(tool.toolName)_tool_result"
                        assistant.append(["type": .string(resultType), "tool_use_id": .string(tool.toolCallId), "content": output])
                    }
                } else {
                    assistant.append(["type": "tool_use", "id": .string(tool.toolCallId), "name": .string(tool.toolName), "input": input])
                    results.append(toolResult(tool))
                }
            default:
                continue
            }
        }
        return (assistant, results)
    }

    static func toolInput(_ tool: ToolPart) -> JSONValue {
        switch tool.input {
        case .object?: tool.input ?? [:]
        case nil, .null?: [:]
        case let value?: ["input": value]
        }
    }

    static func toolResult(_ tool: ToolPart) -> JSONValue {
        let result = tool.modelResult
        var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(tool.toolCallId), "content": .string(result.text)]
        if result.isError { block["is_error"] = true }
        return .object(block)
    }
}
