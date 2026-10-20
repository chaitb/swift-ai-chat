import Foundation

/// A tool invocation inside an assistant message.
///
/// Static tools are encoded as `tool-<name>` parts and dynamic tools as
/// `dynamic-tool` parts, exactly like the AI SDK.
public struct ToolPart: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case inputStreaming
        case inputAvailable
        case approvalRequested
        case approvalResponded
        case outputAvailable
        case outputError
        case outputDenied
        case other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "input-streaming": self = .inputStreaming
            case "input-available": self = .inputAvailable
            case "approval-requested": self = .approvalRequested
            case "approval-responded": self = .approvalResponded
            case "output-available": self = .outputAvailable
            case "output-error": self = .outputError
            case "output-denied": self = .outputDenied
            default: self = .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .inputStreaming: "input-streaming"
            case .inputAvailable: "input-available"
            case .approvalRequested: "approval-requested"
            case .approvalResponded: "approval-responded"
            case .outputAvailable: "output-available"
            case .outputError: "output-error"
            case .outputDenied: "output-denied"
            case .other(let value): value
            }
        }

        /// Whether the call has a final result: an output, an error or a denial.
        public var isFinal: Bool {
            switch self {
            case .outputAvailable, .outputError, .outputDenied: true
            default: false
            }
        }
    }

    public var toolName: String
    public var toolCallId: String
    /// Whether the part is a `dynamic-tool` part rather than a `tool-<name>` part.
    public var isDynamic: Bool
    public var state: State
    /// The tool input. `nil` means the field is absent; an explicit JSON `null` is `.null`.
    public var input: JSONValue?
    public var output: JSONValue?
    public var errorText: String?
    /// The raw input text received so far while the input streams. Older servers
    /// also put the unparsed input of a failed call here.
    public var rawInput: JSONValue?
    /// How the input streams: `json` (the default) or `text` for free-form tool input.
    public var inputEncoding: String?
    /// Whether the provider ran the tool, such as a hosted web search.
    public var providerExecuted: Bool?
    /// Whether `output` is a preliminary result that a later chunk will replace.
    public var preliminary: Bool?
    public var title: String?
    public var toolMetadata: JSONValue?
    public var callProviderMetadata: JSONValue?
    public var resultProviderMetadata: JSONValue?
    public var approval: ToolApproval?
    public var extra: [String: JSONValue]

    public init(
        toolName: String,
        toolCallId: String,
        isDynamic: Bool = false,
        state: State,
        input: JSONValue? = nil,
        output: JSONValue? = nil,
        errorText: String? = nil,
        rawInput: JSONValue? = nil,
        inputEncoding: String? = nil,
        providerExecuted: Bool? = nil,
        preliminary: Bool? = nil,
        title: String? = nil,
        toolMetadata: JSONValue? = nil,
        callProviderMetadata: JSONValue? = nil,
        resultProviderMetadata: JSONValue? = nil,
        approval: ToolApproval? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.isDynamic = isDynamic
        self.state = state
        self.input = input
        self.output = output
        self.errorText = errorText
        self.rawInput = rawInput
        self.inputEncoding = inputEncoding
        self.providerExecuted = providerExecuted
        self.preliminary = preliminary
        self.title = title
        self.toolMetadata = toolMetadata
        self.callProviderMetadata = callProviderMetadata
        self.resultProviderMetadata = resultProviderMetadata
        self.approval = approval
        self.extra = extra
    }

    /// The wire type: `tool-<name>` or `dynamic-tool`.
    public var type: String { isDynamic ? "dynamic-tool" : "tool-\(toolName)" }

    /// Decodes the input into your own type.
    public func decodeInput<T: Decodable>(_ type: T.Type = T.self, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try (input ?? .null).decode(T.self, using: decoder)
    }

    /// Decodes the output into your own type.
    public func decodeOutput<T: Decodable>(_ type: T.Type = T.self, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try (output ?? .null).decode(T.self, using: decoder)
    }

    /// Whether the model is still writing the input or the tool is still running.
    public var isRunning: Bool {
        switch state {
        case .inputStreaming, .inputAvailable: true
        case .approvalResponded: approval?.approved == true
        default: false
        }
    }
}

/// The approval state of a tool call that needs the user's consent.
public struct ToolApproval: Hashable, Sendable {
    public var id: String
    public var approved: Bool?
    public var reason: String?
    public var signature: String?
    /// What the server asked approval for (AI SDK v7).
    public var descriptor: JSONValue?
    /// Why the server asked for approval (AI SDK v7).
    public var requestReason: String?
    /// Whether the decision was made automatically (AI SDK v7).
    public var isAutomatic: Bool?
    /// The input as the tool's schema sees it, when it differs from the model's input (AI SDK v7).
    public var inputSchemaInput: JSONValue?
    public var extra: [String: JSONValue]

    public init(
        id: String,
        approved: Bool? = nil,
        reason: String? = nil,
        signature: String? = nil,
        descriptor: JSONValue? = nil,
        requestReason: String? = nil,
        isAutomatic: Bool? = nil,
        inputSchemaInput: JSONValue? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.approved = approved
        self.reason = reason
        self.signature = signature
        self.descriptor = descriptor
        self.requestReason = requestReason
        self.isAutomatic = isAutomatic
        self.inputSchemaInput = inputSchemaInput
        self.extra = extra
    }

    init(jsonObject: [String: JSONValue]) throws(ChatError) {
        var reader = ObjectReader(jsonObject, context: "Tool approval")
        id = try reader.string("id")
        approved = reader.optionalBool("approved")
        reason = reader.optionalString("reason")
        signature = reader.optionalString("signature")
        descriptor = reader.optionalValue("descriptor")
        requestReason = reader.optionalString("requestReason")
        isAutomatic = reader.optionalBool("isAutomatic")
        inputSchemaInput = reader.presentValue("inputSchemaInput")
        extra = reader.remaining
    }

    var jsonObject: [String: JSONValue] {
        var writer = ObjectWriter(extra: extra)
        writer.set("id", id)
        writer.set("approved", approved)
        writer.set("reason", reason)
        writer.set("signature", signature)
        writer.set("descriptor", descriptor)
        writer.set("requestReason", requestReason)
        writer.set("isAutomatic", isAutomatic)
        writer.set("inputSchemaInput", inputSchemaInput)
        return writer.object
    }
}
