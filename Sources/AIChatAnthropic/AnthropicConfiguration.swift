import AIChat
import Foundation

/// How ``AnthropicChatTransport`` calls the Anthropic Messages API.
public struct AnthropicConfiguration: Sendable {
    public enum Authentication: Sendable, Hashable {
        /// An API key, sent as `x-api-key`.
        case apiKey(String)
        /// An OAuth access token, sent as `Authorization: Bearer` with the OAuth beta header.
        case bearerToken(String)
    }

    /// The `thinking` request parameter.
    public enum Thinking: Sendable, Hashable {
        public enum Display: String, Sendable, Hashable {
            /// A readable summary of the reasoning.
            case summarized
            /// Thinking blocks stream with empty text (the default on current models).
            case omitted
            /// Short progress notes between tool calls (beta).
            case updates
        }

        /// Claude decides when and how much to think. Recommended on current models.
        case adaptive(display: Display? = nil)
        /// A fixed thinking budget, for older models such as Claude Haiku 4.5.
        case enabled(budgetTokens: Int, display: Display? = nil)
        /// No thinking, on models that allow it.
        case disabled
        /// Thinking only between tool calls (Claude Sonnet 5.5).
        case betweenTools

        var jsonValue: JSONValue {
            switch self {
            case .adaptive(let display):
                var object: [String: JSONValue] = ["type": "adaptive"]
                if let display { object["display"] = .string(display.rawValue) }
                return .object(object)
            case .enabled(let budgetTokens, let display):
                var object: [String: JSONValue] = ["type": "enabled", "budget_tokens": .number(Double(budgetTokens))]
                if let display { object["display"] = .string(display.rawValue) }
                return .object(object)
            case .disabled:
                return ["type": "disabled"]
            case .betweenTools:
                return ["type": "between_tools"]
            }
        }
    }

    /// The `output_config.effort` request parameter.
    public enum Effort: String, Sendable, Hashable, CaseIterable {
        case low
        case medium
        case high
        case xhigh
        case max
    }

    public var authentication: Authentication?
    public var baseURL: URL
    /// The `anthropic-version` header.
    public var apiVersion: String
    /// Used when the chat has no ``Chat/modelID``.
    public var defaultModel: String
    public var maxTokens: Int
    /// The system prompt. System messages in the conversation are added after it.
    public var system: String?
    /// `nil` leaves thinking to the model's default.
    public var thinking: Thinking?
    public var effort: Effort?
    /// Adds top-level `cache_control` so the conversation prefix is cached between turns.
    public var promptCaching: Bool
    /// Streams client tool input as it is generated instead of per parameter.
    /// Turn it off when a proxy in front of the API rejects the field.
    public var eagerInputStreaming: Bool
    /// Anthropic-hosted tools such as `["type": "web_search_20260209", "name": "web_search"]`.
    public var serverTools: [JSONValue]
    /// The `tool_choice` parameter, such as `["type": "auto"]`.
    public var toolChoice: JSONValue?
    /// Values for the `anthropic-beta` header.
    public var betas: [String]
    public var headers: [String: String]
    /// Extra body fields, such as `fallbacks`. Request options override these.
    public var extraBody: [String: JSONValue]
    /// How many times a `pause_turn` stop is continued automatically.
    public var maxPauseContinuations: Int
    /// Turns attachments into image and document blocks.
    public var fileResolver: FileResolver
    /// Turns `data-*` parts of user messages into text the model reads. `nil` leaves them out.
    public var dataPartConverter: (@Sendable (DataPart) -> String?)?
    /// Adds `model`, `provider`, `usage` and `stopReason` to the assistant message metadata.
    public var includesResponseMetadata: Bool
    public var httpClient: any HTTPStreamingClient
    /// How long the connection may stay silent before it times out.
    public var timeout: TimeInterval

    public init(
        authentication: Authentication?,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        apiVersion: String = "2023-06-01",
        defaultModel: String = "claude-opus-5-5",
        maxTokens: Int = 64_000,
        system: String? = nil,
        thinking: Thinking? = nil,
        effort: Effort? = nil,
        promptCaching: Bool = true,
        eagerInputStreaming: Bool = true,
        serverTools: [JSONValue] = [],
        toolChoice: JSONValue? = nil,
        betas: [String] = [],
        headers: [String: String] = [:],
        extraBody: [String: JSONValue] = [:],
        maxPauseContinuations: Int = 5,
        fileResolver: @escaping FileResolver = FileResolution.inline,
        dataPartConverter: (@Sendable (DataPart) -> String?)? = nil,
        includesResponseMetadata: Bool = true,
        httpClient: any HTTPStreamingClient = URLSessionStreamingClient(),
        timeout: TimeInterval = 600
    ) {
        self.authentication = authentication
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.defaultModel = defaultModel
        self.maxTokens = maxTokens
        self.system = system
        self.thinking = thinking
        self.effort = effort
        self.promptCaching = promptCaching
        self.eagerInputStreaming = eagerInputStreaming
        self.serverTools = serverTools
        self.toolChoice = toolChoice
        self.betas = betas
        self.headers = headers
        self.extraBody = extraBody
        self.maxPauseContinuations = maxPauseContinuations
        self.fileResolver = fileResolver
        self.dataPartConverter = dataPartConverter
        self.includesResponseMetadata = includesResponseMetadata
        self.httpClient = httpClient
        self.timeout = timeout
    }

    /// A configuration that authenticates with an API key.
    public static func apiKey(_ key: String, defaultModel: String = "claude-opus-5-5") -> AnthropicConfiguration {
        AnthropicConfiguration(authentication: .apiKey(key), defaultModel: defaultModel)
    }

    func requestHeaders(extra: [String: String]) -> [String: String] {
        var result: [String: String] = ["anthropic-version": apiVersion, "content-type": "application/json"]
        var allBetas = betas
        switch authentication {
        case .apiKey(let key):
            result["x-api-key"] = key
        case .bearerToken(let token):
            result["authorization"] = "Bearer \(token)"
            if !allBetas.contains("oauth-2025-04-20") { allBetas.append("oauth-2025-04-20") }
        case nil:
            break
        }
        if !allBetas.isEmpty { result["anthropic-beta"] = allBetas.joined(separator: ",") }
        for (name, value) in headers { result[name.lowercased()] = value }
        for (name, value) in extra { result[name.lowercased()] = value }
        return result
    }
}
