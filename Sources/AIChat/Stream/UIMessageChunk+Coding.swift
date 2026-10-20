import Foundation

extension UIMessageChunk: JSONObjectConvertible {
    public init(jsonObject: [String: JSONValue]) throws(ChatError) {
        var reader = ObjectReader(jsonObject, context: "UI message chunk")
        let type = try reader.string("type")
        reader = ObjectReader(jsonObject, context: "\"\(type)\" chunk")
        _ = reader.take("type")
        switch type {
        case "start":
            self = .start(messageId: reader.optionalString("messageId"), messageMetadata: reader.optionalValue("messageMetadata"))
        case "finish":
            self = .finish(
                finishReason: reader.optionalString("finishReason").map(FinishReason.init(rawValue:)),
                messageMetadata: reader.optionalValue("messageMetadata")
            )
        case "abort":
            self = .abort(reason: reader.optionalString("reason"))
        case "error":
            self = .error(errorText: try reader.string("errorText"))
        case "start-step":
            self = .startStep
        case "finish-step":
            self = .finishStep
        case "reset-step":
            self = .resetStep
        case "message-metadata":
            self = .messageMetadata(reader.presentValue("messageMetadata") ?? .null)
        case "text-start":
            self = .textStart(id: try reader.string("id"), providerMetadata: reader.optionalValue("providerMetadata"))
        case "text-delta":
            let id = try reader.string("id")
            self = .textDelta(id: id, delta: try reader.string("delta"), providerMetadata: reader.optionalValue("providerMetadata"))
        case "text-end":
            self = .textEnd(
                id: try reader.string("id"),
                providerMetadata: reader.optionalValue("providerMetadata"),
                citations: TextCitation.list(from: reader.optionalValue("citations"))
            )
        case "reasoning-start":
            self = .reasoningStart(id: try reader.string("id"), providerMetadata: reader.optionalValue("providerMetadata"))
        case "reasoning-delta":
            let id = try reader.string("id")
            self = .reasoningDelta(id: id, delta: try reader.string("delta"), providerMetadata: reader.optionalValue("providerMetadata"))
        case "reasoning-end":
            self = .reasoningEnd(id: try reader.string("id"), providerMetadata: reader.optionalValue("providerMetadata"))
        case "tool-input-start":
            self = .toolInputStart(ToolInputStartChunk(
                toolCallId: try reader.string("toolCallId"),
                toolName: try reader.string("toolName"),
                inputEncoding: reader.optionalString("inputEncoding"),
                providerExecuted: reader.optionalBool("providerExecuted"),
                providerMetadata: reader.optionalValue("providerMetadata"),
                toolMetadata: reader.optionalValue("toolMetadata"),
                dynamic: reader.optionalBool("dynamic"),
                title: reader.optionalString("title")
            ))
        case "tool-input-delta":
            let toolCallId = try reader.string("toolCallId")
            self = .toolInputDelta(toolCallId: toolCallId, inputTextDelta: try reader.string("inputTextDelta"))
        case "tool-input-available":
            self = .toolInputAvailable(ToolInputAvailableChunk(
                toolCallId: try reader.string("toolCallId"),
                toolName: try reader.string("toolName"),
                input: reader.presentValue("input"),
                providerExecuted: reader.optionalBool("providerExecuted"),
                providerMetadata: reader.optionalValue("providerMetadata"),
                toolMetadata: reader.optionalValue("toolMetadata"),
                dynamic: reader.optionalBool("dynamic"),
                title: reader.optionalString("title")
            ))
        case "tool-input-error":
            self = .toolInputError(ToolInputErrorChunk(
                toolCallId: try reader.string("toolCallId"),
                toolName: try reader.string("toolName"),
                input: reader.presentValue("input"),
                errorText: try reader.string("errorText"),
                providerExecuted: reader.optionalBool("providerExecuted"),
                providerMetadata: reader.optionalValue("providerMetadata"),
                toolMetadata: reader.optionalValue("toolMetadata"),
                dynamic: reader.optionalBool("dynamic"),
                title: reader.optionalString("title")
            ))
        case "tool-approval-request":
            self = .toolApprovalRequest(ToolApprovalRequestChunk(
                approvalId: try reader.string("approvalId"),
                toolCallId: try reader.string("toolCallId"),
                signature: reader.optionalString("signature"),
                approvalDescriptor: reader.optionalValue("approvalDescriptor"),
                inputSchemaInput: reader.presentValue("inputSchemaInput"),
                reason: reader.optionalString("reason"),
                isAutomatic: reader.optionalBool("isAutomatic")
            ))
        case "tool-approval-response":
            let approvalId = try reader.string("approvalId")
            guard let approved = reader.optionalBool("approved") else {
                throw ChatError(kind: .decoding, message: "\"tool-approval-response\" chunk is missing the boolean field \"approved\".")
            }
            self = .toolApprovalResponse(ToolApprovalResponseChunk(
                approvalId: approvalId,
                approved: approved,
                reason: reader.optionalString("reason"),
                providerExecuted: reader.optionalBool("providerExecuted"),
                providerMetadata: reader.optionalValue("providerMetadata")
            ))
        case "tool-output-available":
            self = .toolOutputAvailable(ToolOutputAvailableChunk(
                toolCallId: try reader.string("toolCallId"),
                output: reader.presentValue("output"),
                providerExecuted: reader.optionalBool("providerExecuted"),
                providerMetadata: reader.optionalValue("providerMetadata"),
                toolMetadata: reader.optionalValue("toolMetadata"),
                dynamic: reader.optionalBool("dynamic"),
                preliminary: reader.optionalBool("preliminary")
            ))
        case "tool-output-error":
            self = .toolOutputError(ToolOutputErrorChunk(
                toolCallId: try reader.string("toolCallId"),
                errorText: try reader.string("errorText"),
                providerExecuted: reader.optionalBool("providerExecuted"),
                providerMetadata: reader.optionalValue("providerMetadata"),
                toolMetadata: reader.optionalValue("toolMetadata"),
                dynamic: reader.optionalBool("dynamic")
            ))
        case "tool-output-denied":
            self = .toolOutputDenied(toolCallId: try reader.string("toolCallId"))
        case "source-url":
            self = .sourceURL(SourceURLPart(
                sourceId: try reader.string("sourceId"),
                url: try reader.string("url"),
                title: reader.optionalString("title"),
                providerMetadata: reader.optionalValue("providerMetadata")
            ))
        case "source-document":
            self = .sourceDocument(SourceDocumentPart(
                sourceId: try reader.string("sourceId"),
                mediaType: try reader.string("mediaType"),
                title: try reader.string("title"),
                filename: reader.optionalString("filename"),
                providerMetadata: reader.optionalValue("providerMetadata")
            ))
        case "file":
            let url = try reader.string("url")
            self = .file(url: url, mediaType: try reader.string("mediaType"), providerMetadata: reader.optionalValue("providerMetadata"))
        case "reasoning-file":
            let url = try reader.string("url")
            self = .reasoningFile(url: url, mediaType: try reader.string("mediaType"), providerMetadata: reader.optionalValue("providerMetadata"))
        case "custom":
            self = .custom(kind: try reader.string("kind"), providerMetadata: reader.optionalValue("providerMetadata"))
        default:
            if type.hasPrefix("data-") {
                self = .data(DataChunk(
                    name: String(type.dropFirst("data-".count)),
                    data: reader.presentValue("data") ?? .null,
                    id: reader.optionalString("id"),
                    transient: reader.optionalBool("transient")
                ))
            } else {
                self = .unknown(type: type, object: jsonObject)
            }
        }
    }

    public var jsonObject: [String: JSONValue] {
        var writer = ObjectWriter()
        writer.set("type", type)
        switch self {
        case .start(let messageId, let messageMetadata):
            writer.set("messageId", messageId)
            writer.set("messageMetadata", messageMetadata)
        case .finish(let finishReason, let messageMetadata):
            writer.set("finishReason", finishReason?.rawValue)
            writer.set("messageMetadata", messageMetadata)
        case .abort(let reason):
            writer.set("reason", reason)
        case .error(let errorText):
            writer.set("errorText", errorText)
        case .startStep, .finishStep, .resetStep:
            break
        case .messageMetadata(let metadata):
            writer.set("messageMetadata", metadata)
        case .textStart(let id, let providerMetadata),
             .reasoningStart(let id, let providerMetadata), .reasoningEnd(let id, let providerMetadata):
            writer.set("id", id)
            writer.set("providerMetadata", providerMetadata)
        case .textEnd(let id, let providerMetadata, let citations):
            writer.set("id", id)
            writer.set("providerMetadata", providerMetadata)
            writer.set("citations", citations.map { JSONValue.array($0.map(\.jsonValue)) })
        case .textDelta(let id, let delta, let providerMetadata), .reasoningDelta(let id, let delta, let providerMetadata):
            writer.set("id", id)
            writer.set("delta", delta)
            writer.set("providerMetadata", providerMetadata)
        case .toolInputStart(let chunk):
            writer.set("toolCallId", chunk.toolCallId)
            writer.set("toolName", chunk.toolName)
            writer.set("inputEncoding", chunk.inputEncoding)
            writer.set("providerExecuted", chunk.providerExecuted)
            writer.set("providerMetadata", chunk.providerMetadata)
            writer.set("toolMetadata", chunk.toolMetadata)
            writer.set("dynamic", chunk.dynamic)
            writer.set("title", chunk.title)
        case .toolInputDelta(let toolCallId, let inputTextDelta):
            writer.set("toolCallId", toolCallId)
            writer.set("inputTextDelta", inputTextDelta)
        case .toolInputAvailable(let chunk):
            writer.set("toolCallId", chunk.toolCallId)
            writer.set("toolName", chunk.toolName)
            writer.set("input", chunk.input)
            writer.set("providerExecuted", chunk.providerExecuted)
            writer.set("providerMetadata", chunk.providerMetadata)
            writer.set("toolMetadata", chunk.toolMetadata)
            writer.set("dynamic", chunk.dynamic)
            writer.set("title", chunk.title)
        case .toolInputError(let chunk):
            writer.set("toolCallId", chunk.toolCallId)
            writer.set("toolName", chunk.toolName)
            writer.set("input", chunk.input)
            writer.set("errorText", chunk.errorText)
            writer.set("providerExecuted", chunk.providerExecuted)
            writer.set("providerMetadata", chunk.providerMetadata)
            writer.set("toolMetadata", chunk.toolMetadata)
            writer.set("dynamic", chunk.dynamic)
            writer.set("title", chunk.title)
        case .toolApprovalRequest(let chunk):
            writer.set("approvalId", chunk.approvalId)
            writer.set("toolCallId", chunk.toolCallId)
            writer.set("signature", chunk.signature)
            writer.set("approvalDescriptor", chunk.approvalDescriptor)
            writer.set("inputSchemaInput", chunk.inputSchemaInput)
            writer.set("reason", chunk.reason)
            writer.set("isAutomatic", chunk.isAutomatic)
        case .toolApprovalResponse(let chunk):
            writer.set("approvalId", chunk.approvalId)
            writer.set("approved", chunk.approved)
            writer.set("reason", chunk.reason)
            writer.set("providerExecuted", chunk.providerExecuted)
            writer.set("providerMetadata", chunk.providerMetadata)
        case .toolOutputAvailable(let chunk):
            writer.set("toolCallId", chunk.toolCallId)
            writer.set("output", chunk.output)
            writer.set("providerExecuted", chunk.providerExecuted)
            writer.set("providerMetadata", chunk.providerMetadata)
            writer.set("toolMetadata", chunk.toolMetadata)
            writer.set("dynamic", chunk.dynamic)
            writer.set("preliminary", chunk.preliminary)
        case .toolOutputError(let chunk):
            writer.set("toolCallId", chunk.toolCallId)
            writer.set("errorText", chunk.errorText)
            writer.set("providerExecuted", chunk.providerExecuted)
            writer.set("providerMetadata", chunk.providerMetadata)
            writer.set("toolMetadata", chunk.toolMetadata)
            writer.set("dynamic", chunk.dynamic)
        case .toolOutputDenied(let toolCallId):
            writer.set("toolCallId", toolCallId)
        case .sourceURL(let source):
            writer.set("sourceId", source.sourceId)
            writer.set("url", source.url)
            writer.set("title", source.title)
            writer.set("providerMetadata", source.providerMetadata)
        case .sourceDocument(let source):
            writer.set("sourceId", source.sourceId)
            writer.set("mediaType", source.mediaType)
            writer.set("title", source.title)
            writer.set("filename", source.filename)
            writer.set("providerMetadata", source.providerMetadata)
        case .file(let url, let mediaType, let providerMetadata), .reasoningFile(let url, let mediaType, let providerMetadata):
            writer.set("url", url)
            writer.set("mediaType", mediaType)
            writer.set("providerMetadata", providerMetadata)
        case .data(let chunk):
            writer.set("id", chunk.id)
            writer.set("data", chunk.data)
            writer.set("transient", chunk.transient)
        case .custom(let kind, let providerMetadata):
            writer.set("kind", kind)
            writer.set("providerMetadata", providerMetadata)
        case .unknown(_, let object):
            return object
        }
        return writer.object
    }
}
