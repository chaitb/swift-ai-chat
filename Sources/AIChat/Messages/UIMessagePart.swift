import Foundation

/// One part of a ``UIMessage``, in the AI SDK `UIMessagePart` shape.
public enum UIMessagePart: Hashable, Sendable {
    case text(TextPart)
    case reasoning(ReasoningPart)
    /// A static `tool-<name>` or a `dynamic-tool` invocation.
    case tool(ToolPart)
    case sourceURL(SourceURLPart)
    case sourceDocument(SourceDocumentPart)
    case file(FilePart)
    /// A file the model produced while reasoning (AI SDK v7).
    case reasoningFile(FilePart)
    /// A `data-<name>` part.
    case data(DataPart)
    /// The boundary between two steps of a multi-step response.
    case stepStart
    case custom(CustomPart)
    case unknown(UnknownPart)
}

extension UIMessagePart {
    /// A text part.
    public static func text(_ text: String) -> UIMessagePart {
        .text(TextPart(text: text))
    }

    /// A file part.
    public static func file(url: String, mediaType: String, filename: String? = nil) -> UIMessagePart {
        .file(FilePart(mediaType: mediaType, url: url, filename: filename))
    }

    /// A file part with the bytes embedded as a `data:` URL.
    public static func file(data: Data, mediaType: String, filename: String? = nil) -> UIMessagePart {
        .file(FilePart(data: data, mediaType: mediaType, filename: filename))
    }

    /// A `data-<name>` part.
    public static func data(name: String, data: JSONValue, id: String? = nil) -> UIMessagePart {
        .data(DataPart(name: name, data: data, id: id))
    }

    /// The wire `type` of the part.
    public var type: String {
        switch self {
        case .text: "text"
        case .reasoning: "reasoning"
        case .tool(let tool): tool.type
        case .sourceURL: "source-url"
        case .sourceDocument: "source-document"
        case .file: "file"
        case .reasoningFile: "reasoning-file"
        case .data(let data): data.type
        case .stepStart: "step-start"
        case .custom: "custom"
        case .unknown(let unknown): unknown.type
        }
    }

    public var textPart: TextPart? {
        if case .text(let part) = self { return part }
        return nil
    }

    public var reasoningPart: ReasoningPart? {
        if case .reasoning(let part) = self { return part }
        return nil
    }

    public var toolPart: ToolPart? {
        if case .tool(let part) = self { return part }
        return nil
    }

    public var filePart: FilePart? {
        if case .file(let part) = self { return part }
        return nil
    }

    public var dataPart: DataPart? {
        if case .data(let part) = self { return part }
        return nil
    }

    public var isStepStart: Bool {
        if case .stepStart = self { return true }
        return false
    }
}

extension UIMessagePart: JSONObjectConvertible {
    public init(jsonObject: [String: JSONValue]) throws(ChatError) {
        var reader = ObjectReader(jsonObject, context: "Message part")
        let type = try reader.string("type")
        switch type {
        case "text":
            let text = try reader.string("text")
            let state = reader.optionalString("state").flatMap(TextPart.State.init(rawValue:))
            let providerMetadata = reader.optionalValue("providerMetadata")
            let citations = TextCitation.list(from: reader.optionalValue("citations"))
            self = .text(TextPart(text: text, state: state, providerMetadata: providerMetadata, citations: citations, extra: reader.remaining))
        case "reasoning":
            let text = try reader.string("text")
            let state = reader.optionalString("state").flatMap(TextPart.State.init(rawValue:))
            let providerMetadata = reader.optionalValue("providerMetadata")
            let id = reader.optionalString("id")
            self = .reasoning(ReasoningPart(text: text, state: state, providerMetadata: providerMetadata, id: id, extra: reader.remaining))
        case "source-url":
            let sourceId = try reader.string("sourceId")
            let url = try reader.string("url")
            let title = reader.optionalString("title")
            let providerMetadata = reader.optionalValue("providerMetadata")
            self = .sourceURL(SourceURLPart(sourceId: sourceId, url: url, title: title, providerMetadata: providerMetadata, extra: reader.remaining))
        case "source-document":
            let sourceId = try reader.string("sourceId")
            let mediaType = try reader.string("mediaType")
            let title = try reader.string("title")
            let filename = reader.optionalString("filename")
            let providerMetadata = reader.optionalValue("providerMetadata")
            self = .sourceDocument(SourceDocumentPart(
                sourceId: sourceId,
                mediaType: mediaType,
                title: title,
                filename: filename,
                providerMetadata: providerMetadata,
                extra: reader.remaining
            ))
        case "file", "reasoning-file":
            let mediaType = try reader.string("mediaType")
            let url = try reader.string("url")
            let filename = reader.optionalString("filename")
            let providerMetadata = reader.optionalValue("providerMetadata")
            let providerReference = reader.optionalValue("providerReference")
            let file = FilePart(
                mediaType: mediaType,
                url: url,
                filename: filename,
                providerMetadata: providerMetadata,
                providerReference: providerReference,
                extra: reader.remaining
            )
            self = type == "file" ? .file(file) : .reasoningFile(file)
        case "step-start":
            self = .stepStart
        case "custom":
            let kind = try reader.string("kind")
            let providerMetadata = reader.optionalValue("providerMetadata")
            self = .custom(CustomPart(kind: kind, providerMetadata: providerMetadata, extra: reader.remaining))
        case "dynamic-tool":
            let toolName = try reader.string("toolName")
            self = .tool(try Self.toolPart(reader: &reader, toolName: toolName, isDynamic: true))
        default:
            if type.hasPrefix("tool-") {
                let toolName = String(type.dropFirst("tool-".count))
                self = .tool(try Self.toolPart(reader: &reader, toolName: toolName, isDynamic: false))
            } else if type.hasPrefix("data-") {
                let name = String(type.dropFirst("data-".count))
                let id = reader.optionalString("id")
                let data = reader.presentValue("data") ?? .null
                self = .data(DataPart(name: name, data: data, id: id, extra: reader.remaining))
            } else {
                self = .unknown(UnknownPart(type: type, object: jsonObject))
            }
        }
    }

    private static func toolPart(reader: inout ObjectReader, toolName: String, isDynamic: Bool) throws(ChatError) -> ToolPart {
        let toolCallId = try reader.string("toolCallId")
        let state = ToolPart.State(rawValue: try reader.string("state"))
        let input = reader.presentValue("input")
        let output = reader.presentValue("output")
        let errorText = reader.optionalString("errorText")
        let rawInput = reader.presentValue("rawInput")
        let inputEncoding = reader.optionalString("inputEncoding")
        let providerExecuted = reader.optionalBool("providerExecuted")
        let preliminary = reader.optionalBool("preliminary")
        let title = reader.optionalString("title")
        let toolMetadata = reader.optionalValue("toolMetadata")
        let callProviderMetadata = reader.optionalValue("callProviderMetadata")
        let resultProviderMetadata = reader.optionalValue("resultProviderMetadata")
        var approval: ToolApproval?
        if let approvalObject = reader.optionalObject("approval") {
            approval = try ToolApproval(jsonObject: approvalObject)
        }
        return ToolPart(
            toolName: toolName,
            toolCallId: toolCallId,
            isDynamic: isDynamic,
            state: state,
            input: input,
            output: output,
            errorText: errorText,
            rawInput: rawInput,
            inputEncoding: inputEncoding,
            providerExecuted: providerExecuted,
            preliminary: preliminary,
            title: title,
            toolMetadata: toolMetadata,
            callProviderMetadata: callProviderMetadata,
            resultProviderMetadata: resultProviderMetadata,
            approval: approval,
            extra: reader.remaining
        )
    }

    public var jsonObject: [String: JSONValue] {
        switch self {
        case .text(let part):
            var writer = ObjectWriter(extra: part.extra)
            writer.set("type", "text")
            writer.set("text", part.text)
            writer.set("state", part.state?.rawValue)
            writer.set("providerMetadata", part.providerMetadata)
            writer.set("citations", part.citations.map { JSONValue.array($0.map(\.jsonValue)) })
            return writer.object
        case .reasoning(let part):
            var writer = ObjectWriter(extra: part.extra)
            writer.set("type", "reasoning")
            writer.set("id", part.id)
            writer.set("text", part.text)
            writer.set("state", part.state?.rawValue)
            writer.set("providerMetadata", part.providerMetadata)
            return writer.object
        case .tool(let part):
            var writer = ObjectWriter(extra: part.extra)
            writer.set("type", part.type)
            if part.isDynamic { writer.set("toolName", part.toolName) }
            writer.set("toolCallId", part.toolCallId)
            writer.set("state", part.state.rawValue)
            writer.set("title", part.title)
            writer.set("toolMetadata", part.toolMetadata)
            writer.set("providerExecuted", part.providerExecuted)
            writer.set("input", part.input)
            writer.set("output", part.output)
            writer.set("errorText", part.errorText)
            writer.set("rawInput", part.rawInput)
            writer.set("inputEncoding", part.inputEncoding)
            writer.set("preliminary", part.preliminary)
            writer.set("callProviderMetadata", part.callProviderMetadata)
            writer.set("resultProviderMetadata", part.resultProviderMetadata)
            writer.set("approval", part.approval?.jsonObject)
            return writer.object
        case .sourceURL(let part):
            var writer = ObjectWriter(extra: part.extra)
            writer.set("type", "source-url")
            writer.set("sourceId", part.sourceId)
            writer.set("url", part.url)
            writer.set("title", part.title)
            writer.set("providerMetadata", part.providerMetadata)
            return writer.object
        case .sourceDocument(let part):
            var writer = ObjectWriter(extra: part.extra)
            writer.set("type", "source-document")
            writer.set("sourceId", part.sourceId)
            writer.set("mediaType", part.mediaType)
            writer.set("title", part.title)
            writer.set("filename", part.filename)
            writer.set("providerMetadata", part.providerMetadata)
            return writer.object
        case .file(let part), .reasoningFile(let part):
            var writer = ObjectWriter(extra: part.extra)
            writer.set("type", type)
            writer.set("mediaType", part.mediaType)
            writer.set("filename", part.filename)
            writer.set("url", part.url)
            writer.set("providerMetadata", part.providerMetadata)
            writer.set("providerReference", part.providerReference)
            return writer.object
        case .data(let part):
            var writer = ObjectWriter(extra: part.extra)
            writer.set("type", part.type)
            writer.set("id", part.id)
            writer.set("data", part.data)
            return writer.object
        case .stepStart:
            return ["type": "step-start"]
        case .custom(let part):
            var writer = ObjectWriter(extra: part.extra)
            writer.set("type", "custom")
            writer.set("kind", part.kind)
            writer.set("providerMetadata", part.providerMetadata)
            return writer.object
        case .unknown(let part):
            return part.object
        }
    }
}
