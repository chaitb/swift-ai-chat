import AIChat
import Foundation

/// How ``OpenAIChatTransport`` calls the OpenAI API, or any server that speaks it.
public struct OpenAIConfiguration: Sendable {
    /// Which OpenAI endpoint the transport streams from.
    public enum API: String, Sendable, Hashable, CaseIterable {
        /// `POST /responses`. Supports reasoning summaries, hosted tools and stateless
        /// reasoning hand-off. Recommended for OpenAI models.
        case responses
        /// `POST /chat/completions`. The widest compatibility with OpenAI-style servers
        /// such as the Vercel AI Gateway, OpenRouter, Groq or a local model server.
        case chatCompletions
    }

    /// The `reasoning` request parameter.
    public struct Reasoning: Sendable, Hashable {
        public enum Effort: String, Sendable, Hashable, CaseIterable {
            case none
            case minimal
            case low
            case medium
            case high
            case xhigh
        }

        public enum Summary: String, Sendable, Hashable {
            case auto
            case concise
            case detailed
        }

        public var effort: Effort?
        /// Streams a summary of the reasoning as reasoning parts. Responses API only.
        public var summary: Summary?

        public init(effort: Effort? = nil, summary: Summary? = .auto) {
            self.effort = effort
            self.summary = summary
        }
    }

    /// The role system prompts are sent with.
    public enum SystemMessageRole: String, Sendable, Hashable {
        case system
        case developer
    }

    /// Sent as `Authorization: Bearer`. `nil` sends no authorization header, for a proxy that adds it.
    public var apiKey: String?
    public var organization: String?
    public var project: String?
    /// The API root, including the version path, such as `https://api.openai.com/v1`.
    public var baseURL: URL
    public var api: API
    /// Used when the chat has no ``Chat/modelID``.
    public var defaultModel: String
    public var maxOutputTokens: Int?
    /// The system prompt. System messages in the conversation are sent after it.
    public var system: String?
    public var systemMessageRole: SystemMessageRole
    /// `nil` leaves reasoning to the model's default.
    public var reasoning: Reasoning?
    /// The `text.verbosity` (Responses) or `verbosity` (Chat Completions) parameter: `low`, `medium` or `high`.
    public var verbosity: String?
    /// Whether OpenAI keeps the response. Off by default: the transport sends the whole
    /// conversation each turn and passes reasoning back as encrypted content.
    /// Responses API only.
    public var store: Bool
    /// OpenAI-hosted tools such as `["type": "web_search"]`. Responses API only.
    public var builtInTools: [JSONValue]
    /// The `tool_choice` parameter, such as `"auto"` or `"required"`.
    public var toolChoice: JSONValue?
    public var parallelToolCalls: Bool?
    public var headers: [String: String]
    /// Extra body fields, such as `prompt_cache_key` or `service_tier`. Request options override these.
    public var extraBody: [String: JSONValue]
    /// Turns attachments into image and file content.
    public var fileResolver: FileResolver
    /// Turns `data-*` parts of user messages into text the model reads. `nil` leaves them out.
    public var dataPartConverter: (@Sendable (DataPart) -> String?)?
    /// Adds `model`, `provider`, `usage` and `responseId` to the assistant message metadata.
    public var includesResponseMetadata: Bool
    public var httpClient: any HTTPStreamingClient
    /// How long the connection may stay silent before it times out.
    public var timeout: TimeInterval

    public init(
        apiKey: String?,
        organization: String? = nil,
        project: String? = nil,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        api: API = .responses,
        defaultModel: String = "gpt-5.5",
        maxOutputTokens: Int? = nil,
        system: String? = nil,
        systemMessageRole: SystemMessageRole = .system,
        reasoning: Reasoning? = nil,
        verbosity: String? = nil,
        store: Bool = false,
        builtInTools: [JSONValue] = [],
        toolChoice: JSONValue? = nil,
        parallelToolCalls: Bool? = nil,
        headers: [String: String] = [:],
        extraBody: [String: JSONValue] = [:],
        fileResolver: @escaping FileResolver = FileResolution.inline,
        dataPartConverter: (@Sendable (DataPart) -> String?)? = nil,
        includesResponseMetadata: Bool = true,
        httpClient: any HTTPStreamingClient = URLSessionStreamingClient(),
        timeout: TimeInterval = 600
    ) {
        self.apiKey = apiKey
        self.organization = organization
        self.project = project
        self.baseURL = baseURL
        self.api = api
        self.defaultModel = defaultModel
        self.maxOutputTokens = maxOutputTokens
        self.system = system
        self.systemMessageRole = systemMessageRole
        self.reasoning = reasoning
        self.verbosity = verbosity
        self.store = store
        self.builtInTools = builtInTools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.headers = headers
        self.extraBody = extraBody
        self.fileResolver = fileResolver
        self.dataPartConverter = dataPartConverter
        self.includesResponseMetadata = includesResponseMetadata
        self.httpClient = httpClient
        self.timeout = timeout
    }

    /// A configuration for the OpenAI API.
    public static func apiKey(_ key: String, api: API = .responses, defaultModel: String = "gpt-5.5") -> OpenAIConfiguration {
        OpenAIConfiguration(apiKey: key, api: api, defaultModel: defaultModel)
    }

    /// A configuration for the Vercel AI Gateway's OpenAI-compatible API. Model ids
    /// carry the provider, such as `openai/gpt-5.5` or `anthropic/claude-opus-5.5`.
    public static func aiGateway(apiKey: String, api: API = .chatCompletions, defaultModel: String = "openai/gpt-5.5") -> OpenAIConfiguration {
        OpenAIConfiguration(apiKey: apiKey, baseURL: URL(string: "https://ai-gateway.vercel.sh/v1")!, api: api, defaultModel: defaultModel)
    }

    func requestHeaders(extra: [String: String]) -> [String: String] {
        var result: [String: String] = ["content-type": "application/json"]
        if let apiKey { result["authorization"] = "Bearer \(apiKey)" }
        if let organization { result["openai-organization"] = organization }
        if let project { result["openai-project"] = project }
        for (name, value) in headers { result[name.lowercased()] = value }
        for (name, value) in extra { result[name.lowercased()] = value }
        return result
    }

    func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }
}
