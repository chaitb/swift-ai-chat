import AIChat
import Foundation

/// Converts UI messages to Responses API input items.
///
/// Each assistant step becomes its reasoning, message and function call items, followed
/// by the function call outputs. With `store` off, reasoning goes back as encrypted
/// content so the model keeps its chain of thought between tool calls. With `store` on,
/// reasoning and hosted tool calls are passed as item references.
enum OpenAIResponsesConverter {
    static func convert(_ messages: [UIMessage], configuration: OpenAIConfiguration) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        if let system = configuration.system, !system.isEmpty {
            items.append(["role": .string(configuration.systemMessageRole.rawValue), "content": .string(system)])
        }
        for message in messages {
            switch message.role {
            case .system:
                let text = message.text
                if !text.isEmpty {
                    items.append(["role": .string(configuration.systemMessageRole.rawValue), "content": .string(text)])
                }
            case .user:
                let content = try await userContent(message, configuration: configuration)
                if !content.isEmpty { items.append(["role": "user", "content": .array(content)]) }
            case .assistant:
                for step in message.steps {
                    items += assistantStep(step, store: configuration.store)
                }
            }
        }
        return items
    }

    static func userContent(_ message: UIMessage, configuration: OpenAIConfiguration) async throws -> [JSONValue] {
        var content: [JSONValue] = []
        for part in message.parts {
            if let block = try await userBlock(part, configuration: configuration) {
                content.append(block)
            }
        }
        return content
    }

    private static func userBlock(_ part: UIMessagePart, configuration: OpenAIConfiguration) async throws -> JSONValue? {
        switch part {
        case .text(let text):
            return text.text.isEmpty ? nil : ["type": "input_text", "text": .string(text.text)]
        case .file(let file):
            guard let resolved = try await configuration.fileResolver(file) else { return nil }
            return try fileBlock(resolved, filename: file.filename)
        case .data(let data):
            guard let text = configuration.dataPartConverter?(data), !text.isEmpty else { return nil }
            return ["type": "input_text", "text": .string(text)]
        default:
            return nil
        }
    }

    static func fileBlock(_ file: ResolvedFile, filename: String?) throws -> JSONValue {
        let mediaType = file.mediaType.lowercased()
        if mediaType.hasPrefix("image/") {
            switch file {
            case .data(let data, _):
                return ["type": "input_image", "image_url": .string("data:\(file.mediaType);base64,\(data.base64EncodedString())"), "detail": "auto"]
            case .url(let url, _):
                return ["type": "input_image", "image_url": .string(url.absoluteString), "detail": "auto"]
            case .providerFileID(let id, _):
                return ["type": "input_image", "file_id": .string(id), "detail": "auto"]
            case .text:
                break
            }
        }
        if case .text(let text, _) = file {
            return ["type": "input_text", "text": .string(OpenAIFiles.textAttachment(text, filename: filename))]
        }
        if mediaType.hasPrefix("text/"), case .data(let data, _) = file {
            return ["type": "input_text", "text": .string(OpenAIFiles.textAttachment(String(decoding: data, as: UTF8.self), filename: filename))]
        }
        var block: [String: JSONValue] = ["type": "input_file"]
        switch file {
        case .data(let data, _):
            block["file_data"] = .string("data:\(file.mediaType);base64,\(data.base64EncodedString())")
            block["filename"] = .string(filename ?? OpenAIFiles.defaultFilename(mediaType: mediaType))
        case .url(let url, _):
            block["file_url"] = .string(url.absoluteString)
        case .providerFileID(let id, _):
            block["file_id"] = .string(id)
        case .text:
            break
        }
        return .object(block)
    }

    static func assistantStep(_ parts: [UIMessagePart], store: Bool) -> [JSONValue] {
        var items: [JSONValue] = []
        var outputs: [JSONValue] = []
        var reasoningIndex: [String: Int] = [:]
        var pendingText: (text: String, metadata: JSONValue?)?

        func flushText() {
            guard let text = pendingText else { return }
            pendingText = nil
            var item: [String: JSONValue] = [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": .string(text.text)]],
            ]
            if let phase = text.metadata?["phase"] { item["phase"] = phase }
            if store, let id = text.metadata?["itemId"] { item["id"] = id }
            items.append(.object(item))
        }

        for part in parts {
            switch part {
            case .text(let text):
                guard !text.text.isEmpty else { continue }
                let metadata = text.providerMetadata?["openai"]
                if let pending = pendingText, pending.metadata?["itemId"] == metadata?["itemId"] {
                    pendingText = (pending.text + text.text, pending.metadata)
                } else {
                    flushText()
                    pendingText = (text.text, metadata)
                }
            case .reasoning(let reasoning):
                flushText()
                let metadata = reasoning.providerMetadata?["openai"]
                guard let id = metadata?["itemId"]?.stringValue else { continue }
                if store {
                    if reasoningIndex[id] == nil {
                        reasoningIndex[id] = items.count
                        items.append(["type": "item_reference", "id": .string(id)])
                    }
                    continue
                }
                let summary: [JSONValue] = reasoning.text.isEmpty ? [] : [["type": "summary_text", "text": .string(reasoning.text)]]
                if let index = reasoningIndex[id], case .object(var item) = items[index] {
                    item["summary"] = .array((item["summary"]?.arrayValue ?? []) + summary)
                    if let encrypted = metadata?["encryptedContent"], !encrypted.isNull { item["encrypted_content"] = encrypted }
                    items[index] = .object(item)
                } else {
                    var item: [String: JSONValue] = ["type": "reasoning", "id": .string(id), "summary": .array(summary)]
                    if let encrypted = metadata?["encryptedContent"], !encrypted.isNull { item["encrypted_content"] = encrypted }
                    reasoningIndex[id] = items.count
                    items.append(.object(item))
                }
            case .tool(let tool):
                flushText()
                let metadata = tool.callProviderMetadata?["openai"]
                if tool.providerExecuted == true {
                    if store {
                        items.append(["type": "item_reference", "id": metadata?["itemId"] ?? .string(tool.toolCallId)])
                    }
                    continue
                }
                var call: [String: JSONValue] = [
                    "type": "function_call",
                    "call_id": .string(tool.toolCallId),
                    "name": .string(tool.toolName),
                    "arguments": .string(arguments(tool)),
                ]
                if store, let id = metadata?["itemId"] { call["id"] = id }
                items.append(.object(call))
                outputs.append([
                    "type": "function_call_output",
                    "call_id": .string(tool.toolCallId),
                    "output": .string(tool.modelResult.text),
                ])
            default:
                continue
            }
        }
        flushText()
        return items.filter { item in
            guard item["type"] == "reasoning" else { return true }
            return item["encrypted_content"] != nil
        } + outputs
    }

    static func arguments(_ tool: ToolPart) -> String {
        switch tool.input {
        case nil, .null?: "{}"
        case .string(let text)?: text
        case let value?: value.jsonString
        }
    }
}

enum OpenAIFiles {
    static func textAttachment(_ text: String, filename: String?) -> String {
        guard let filename else { return text }
        return "\(filename):\n\(text)"
    }

    static func defaultFilename(mediaType: String) -> String {
        mediaType == "application/pdf" ? "file.pdf" : "file"
    }
}
