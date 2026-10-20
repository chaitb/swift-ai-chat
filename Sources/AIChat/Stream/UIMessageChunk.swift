import Foundation

/// Why the model stopped generating.
public enum FinishReason: Hashable, Sendable {
    case stop
    case length
    case contentFilter
    case toolCalls
    case error
    case other
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "stop": self = .stop
        case "length": self = .length
        case "content-filter": self = .contentFilter
        case "tool-calls": self = .toolCalls
        case "error": self = .error
        case "other": self = .other
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .stop: "stop"
        case .length: "length"
        case .contentFilter: "content-filter"
        case .toolCalls: "tool-calls"
        case .error: "error"
        case .other: "other"
        case .unknown(let value): value
        }
    }
}

/// One chunk of the AI SDK UI message stream protocol (v1), as sent by
/// `toUIMessageStreamResponse()` and `createUIMessageStream()`.
///
/// Every chunk type of AI SDK v6 and v7 is modeled. Chunks of other types decode
/// as ``unknown(type:object:)`` and are ignored by ``StreamingMessageState``.
public enum UIMessageChunk: Hashable, Sendable {
    case start(messageId: String? = nil, messageMetadata: JSONValue? = nil)
    case finish(finishReason: FinishReason? = nil, messageMetadata: JSONValue? = nil)
    case abort(reason: String? = nil)
    case error(errorText: String)
    case startStep
    case finishStep
    /// Removes the parts added during the current step (AI SDK v7).
    case resetStep
    case messageMetadata(JSONValue)
    case textStart(id: String, providerMetadata: JSONValue? = nil)
    case textDelta(id: String, delta: String, providerMetadata: JSONValue? = nil)
    case textEnd(id: String, providerMetadata: JSONValue? = nil, citations: [TextCitation]? = nil)
    case reasoningStart(id: String, providerMetadata: JSONValue? = nil)
    case reasoningDelta(id: String, delta: String, providerMetadata: JSONValue? = nil)
    case reasoningEnd(id: String, providerMetadata: JSONValue? = nil)
    case toolInputStart(ToolInputStartChunk)
    case toolInputDelta(toolCallId: String, inputTextDelta: String)
    case toolInputAvailable(ToolInputAvailableChunk)
    case toolInputError(ToolInputErrorChunk)
    case toolApprovalRequest(ToolApprovalRequestChunk)
    /// A decision the server made on an approval request (AI SDK v7).
    case toolApprovalResponse(ToolApprovalResponseChunk)
    case toolOutputAvailable(ToolOutputAvailableChunk)
    case toolOutputError(ToolOutputErrorChunk)
    case toolOutputDenied(toolCallId: String)
    case sourceURL(SourceURLPart)
    case sourceDocument(SourceDocumentPart)
    case file(url: String, mediaType: String, providerMetadata: JSONValue? = nil)
    case reasoningFile(url: String, mediaType: String, providerMetadata: JSONValue? = nil)
    case data(DataChunk)
    case custom(kind: String, providerMetadata: JSONValue? = nil)
    case unknown(type: String, object: [String: JSONValue])

    /// The wire `type` of the chunk.
    public var type: String {
        switch self {
        case .start: "start"
        case .finish: "finish"
        case .abort: "abort"
        case .error: "error"
        case .startStep: "start-step"
        case .finishStep: "finish-step"
        case .resetStep: "reset-step"
        case .messageMetadata: "message-metadata"
        case .textStart: "text-start"
        case .textDelta: "text-delta"
        case .textEnd: "text-end"
        case .reasoningStart: "reasoning-start"
        case .reasoningDelta: "reasoning-delta"
        case .reasoningEnd: "reasoning-end"
        case .toolInputStart: "tool-input-start"
        case .toolInputDelta: "tool-input-delta"
        case .toolInputAvailable: "tool-input-available"
        case .toolInputError: "tool-input-error"
        case .toolApprovalRequest: "tool-approval-request"
        case .toolApprovalResponse: "tool-approval-response"
        case .toolOutputAvailable: "tool-output-available"
        case .toolOutputError: "tool-output-error"
        case .toolOutputDenied: "tool-output-denied"
        case .sourceURL: "source-url"
        case .sourceDocument: "source-document"
        case .file: "file"
        case .reasoningFile: "reasoning-file"
        case .data(let chunk): "data-\(chunk.name)"
        case .custom: "custom"
        case .unknown(let type, _): type
        }
    }
}

public struct ToolInputStartChunk: Hashable, Sendable {
    public var toolCallId: String
    public var toolName: String
    /// `json` (the default) or `text` for free-form tool input.
    public var inputEncoding: String?
    public var providerExecuted: Bool?
    public var providerMetadata: JSONValue?
    public var toolMetadata: JSONValue?
    public var dynamic: Bool?
    public var title: String?

    public init(
        toolCallId: String,
        toolName: String,
        inputEncoding: String? = nil,
        providerExecuted: Bool? = nil,
        providerMetadata: JSONValue? = nil,
        toolMetadata: JSONValue? = nil,
        dynamic: Bool? = nil,
        title: String? = nil
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.inputEncoding = inputEncoding
        self.providerExecuted = providerExecuted
        self.providerMetadata = providerMetadata
        self.toolMetadata = toolMetadata
        self.dynamic = dynamic
        self.title = title
    }
}

public struct ToolInputAvailableChunk: Hashable, Sendable {
    public var toolCallId: String
    public var toolName: String
    public var input: JSONValue?
    public var providerExecuted: Bool?
    public var providerMetadata: JSONValue?
    public var toolMetadata: JSONValue?
    public var dynamic: Bool?
    public var title: String?

    public init(
        toolCallId: String,
        toolName: String,
        input: JSONValue?,
        providerExecuted: Bool? = nil,
        providerMetadata: JSONValue? = nil,
        toolMetadata: JSONValue? = nil,
        dynamic: Bool? = nil,
        title: String? = nil
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.input = input
        self.providerExecuted = providerExecuted
        self.providerMetadata = providerMetadata
        self.toolMetadata = toolMetadata
        self.dynamic = dynamic
        self.title = title
    }
}

public struct ToolInputErrorChunk: Hashable, Sendable {
    public var toolCallId: String
    public var toolName: String
    public var input: JSONValue?
    public var errorText: String
    public var providerExecuted: Bool?
    public var providerMetadata: JSONValue?
    public var toolMetadata: JSONValue?
    public var dynamic: Bool?
    public var title: String?

    public init(
        toolCallId: String,
        toolName: String,
        input: JSONValue?,
        errorText: String,
        providerExecuted: Bool? = nil,
        providerMetadata: JSONValue? = nil,
        toolMetadata: JSONValue? = nil,
        dynamic: Bool? = nil,
        title: String? = nil
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.input = input
        self.errorText = errorText
        self.providerExecuted = providerExecuted
        self.providerMetadata = providerMetadata
        self.toolMetadata = toolMetadata
        self.dynamic = dynamic
        self.title = title
    }
}

public struct ToolApprovalRequestChunk: Hashable, Sendable {
    public var approvalId: String
    public var toolCallId: String
    public var signature: String?
    public var approvalDescriptor: JSONValue?
    public var inputSchemaInput: JSONValue?
    public var reason: String?
    public var isAutomatic: Bool?

    public init(
        approvalId: String,
        toolCallId: String,
        signature: String? = nil,
        approvalDescriptor: JSONValue? = nil,
        inputSchemaInput: JSONValue? = nil,
        reason: String? = nil,
        isAutomatic: Bool? = nil
    ) {
        self.approvalId = approvalId
        self.toolCallId = toolCallId
        self.signature = signature
        self.approvalDescriptor = approvalDescriptor
        self.inputSchemaInput = inputSchemaInput
        self.reason = reason
        self.isAutomatic = isAutomatic
    }
}

public struct ToolApprovalResponseChunk: Hashable, Sendable {
    public var approvalId: String
    public var approved: Bool
    public var reason: String?
    public var providerExecuted: Bool?
    public var providerMetadata: JSONValue?

    public init(approvalId: String, approved: Bool, reason: String? = nil, providerExecuted: Bool? = nil, providerMetadata: JSONValue? = nil) {
        self.approvalId = approvalId
        self.approved = approved
        self.reason = reason
        self.providerExecuted = providerExecuted
        self.providerMetadata = providerMetadata
    }
}

public struct ToolOutputAvailableChunk: Hashable, Sendable {
    public var toolCallId: String
    public var output: JSONValue?
    public var providerExecuted: Bool?
    public var providerMetadata: JSONValue?
    public var toolMetadata: JSONValue?
    public var dynamic: Bool?
    public var preliminary: Bool?

    public init(
        toolCallId: String,
        output: JSONValue?,
        providerExecuted: Bool? = nil,
        providerMetadata: JSONValue? = nil,
        toolMetadata: JSONValue? = nil,
        dynamic: Bool? = nil,
        preliminary: Bool? = nil
    ) {
        self.toolCallId = toolCallId
        self.output = output
        self.providerExecuted = providerExecuted
        self.providerMetadata = providerMetadata
        self.toolMetadata = toolMetadata
        self.dynamic = dynamic
        self.preliminary = preliminary
    }
}

public struct ToolOutputErrorChunk: Hashable, Sendable {
    public var toolCallId: String
    public var errorText: String
    public var providerExecuted: Bool?
    public var providerMetadata: JSONValue?
    public var toolMetadata: JSONValue?
    public var dynamic: Bool?

    public init(
        toolCallId: String,
        errorText: String,
        providerExecuted: Bool? = nil,
        providerMetadata: JSONValue? = nil,
        toolMetadata: JSONValue? = nil,
        dynamic: Bool? = nil
    ) {
        self.toolCallId = toolCallId
        self.errorText = errorText
        self.providerExecuted = providerExecuted
        self.providerMetadata = providerMetadata
        self.toolMetadata = toolMetadata
        self.dynamic = dynamic
    }
}

/// A `data-<name>` chunk.
public struct DataChunk: Hashable, Sendable {
    /// The name after the `data-` prefix.
    public var name: String
    public var id: String?
    public var data: JSONValue
    /// Transient data is delivered to ``ChatConfiguration/onData`` but never added to the message.
    public var transient: Bool?

    public init(name: String, data: JSONValue, id: String? = nil, transient: Bool? = nil) {
        self.name = name
        self.data = data
        self.id = id
        self.transient = transient
    }
}
