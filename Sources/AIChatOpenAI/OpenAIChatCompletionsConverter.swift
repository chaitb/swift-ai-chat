import AIChat
import Foundation

/// Converts UI messages to Chat Completions messages.
///
/// Each assistant step becomes one assistant message with its tool calls, followed by
/// one `tool` message per call. Reasoning and hosted tool calls are left out, since
/// Chat Completions has no way to send them back.
enum OpenAIChatCompletionsConverter {
    static func convert(_ messages: [UIMessage], configuration: OpenAIConfiguration) async throws -> [JSONValue] {
        var result: [JSONValue] = []
        let systemRole = JSONValue.string(configuration.systemMessageRole.rawValue)
        if let system = configuration.system, !system.isEmpty {
            result.append(["role": systemRole, "content": .string(system)])
        }
        for message in messages {
            switch message.role {
            case .system:
                let text = message.text
                if !text.isEmpty { result.append(["role": systemRole, "content": .string(text)]) }
            case .user:
                let content = try await userContent(message, configuration: configuration)
                guard !content.isEmpty else { continue }
                if content.allSatisfy({ $0["type"] == "text" }) {
                    let text = content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n")
                    result.append(["role": "user", "content": .string(text)])
                } else {
                    result.append(["role": "user", "content": .array(content)])
                }
            case .assistant:
                for step in message.steps {
                    result += assistantStep(step)
                }
            }
        }
        return result
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
        if mediaType.hasPrefix("image/") {
            switch file {
            case .data(let data, _):
                return ["type": "image_url", "image_url": ["url": .string("data:\(file.mediaType);base64,\(data.base64EncodedString())")]]
            case .url(let url, _):
                return ["type": "image_url", "image_url": ["url": .string(url.absoluteString)]]
            case .providerFileID(let id, _):
                return ["type": "file", "file": ["file_id": .string(id)]]
            case .text:
                break
            }
        }
        switch file {
        case .text(let text, _):
            return ["type": "text", "text": .string(OpenAIFiles.textAttachment(text, filename: filename))]
        case .data(let data, _) where mediaType.hasPrefix("text/"):
            return ["type": "text", "text": .string(OpenAIFiles.textAttachment(String(decoding: data, as: UTF8.self), filename: filename))]
        case .data(let data, _):
            return ["type": "file", "file": [
                "filename": .string(filename ?? OpenAIFiles.defaultFilename(mediaType: mediaType)),
                "file_data": .string("data:\(file.mediaType);base64,\(data.base64EncodedString())"),
            ]]
        case .providerFileID(let id, _):
            return ["type": "file", "file": ["file_id": .string(id)]]
        case .url:
            throw ChatError(
                kind: .configuration,
                message: "Chat Completions can't fetch \(file.mediaType) files from a URL. Use FileResolution.downloading to send the bytes.",
                code: "unsupported_file_url"
            )
        }
    }

    static func assistantStep(_ parts: [UIMessagePart]) -> [JSONValue] {
        var text = ""
        var calls: [JSONValue] = []
        var results: [JSONValue] = []
        for part in parts {
            switch part {
            case .text(let part):
                text += part.text
            case .tool(let tool) where tool.providerExecuted != true:
                calls.append([
                    "id": .string(tool.toolCallId),
                    "type": "function",
                    "function": ["name": .string(tool.toolName), "arguments": .string(OpenAIResponsesConverter.arguments(tool))],
                ])
                results.append(["role": "tool", "tool_call_id": .string(tool.toolCallId), "content": .string(tool.modelResult.text)])
            default:
                continue
            }
        }
        guard !text.isEmpty || !calls.isEmpty else { return [] }
        var message: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
        if !calls.isEmpty { message["tool_calls"] = .array(calls) }
        return [.object(message)] + results
    }
}
