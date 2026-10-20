import Foundation

/// A model a user can pick for a conversation.
public struct ChatModel: Identifiable, Hashable, Sendable, Codable {
    /// The id sent to the backend, such as `claude-opus-5-5` or `anthropic/claude-opus-5-5`.
    public var id: String
    public var displayName: String
    /// Who serves the model, such as `anthropic` or `openai`.
    public var provider: String?
    public var summary: String?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var capabilities: Set<ChatModelCapability>
    public var createdAt: Date?
    /// Price per million input tokens in US dollars, when the catalog knows it.
    public var inputPricePerMillionTokens: Double?
    /// Price per million output tokens in US dollars, when the catalog knows it.
    public var outputPricePerMillionTokens: Double?
    /// Everything else the catalog returned.
    public var raw: JSONValue?

    public init(
        id: String,
        displayName: String? = nil,
        provider: String? = nil,
        summary: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        capabilities: Set<ChatModelCapability> = [],
        createdAt: Date? = nil,
        inputPricePerMillionTokens: Double? = nil,
        outputPricePerMillionTokens: Double? = nil,
        raw: JSONValue? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? ChatModel.displayName(for: id)
        self.provider = provider
        self.summary = summary
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = capabilities
        self.createdAt = createdAt
        self.inputPricePerMillionTokens = inputPricePerMillionTokens
        self.outputPricePerMillionTokens = outputPricePerMillionTokens
        self.raw = raw
    }

    public func supports(_ capability: ChatModelCapability) -> Bool {
        capabilities.contains(capability)
    }

    /// A readable name derived from a model id: `gpt-5.4-mini` becomes `GPT 5.4 Mini`.
    public static func displayName(for id: String) -> String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        let acronyms: Set<String> = ["gpt", "ai", "llm", "oss", "vl", "tts", "o1", "o3", "o4"]
        return name
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { word -> String in
                let lower = word.lowercased()
                if acronyms.contains(lower) { return lower.uppercased() }
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}

/// What a model can take in or do.
public enum ChatModelCapability: String, Hashable, Sendable, Codable, CaseIterable {
    case imageInput = "image-input"
    case fileInput = "file-input"
    case toolUse = "tool-use"
    case reasoning
    case structuredOutput = "structured-output"
    case webSearch = "web-search"
    case imageGeneration = "image-generation"
}

/// Lists the models a backend offers.
public protocol ChatModelCatalog: Sendable {
    func models() async throws -> [ChatModel]
}

/// A fixed list of models.
public struct StaticModelCatalog: ChatModelCatalog {
    public var list: [ChatModel]

    public init(_ models: [ChatModel]) {
        list = models
    }

    public func models() async throws -> [ChatModel] { list }
}

/// Merges several catalogs. With `qualifyIDs`, each model id is prefixed with
/// its catalog's provider name (`anthropic/claude-opus-5-5`), the form
/// ``RoutingChatTransport`` routes on.
public struct CompositeModelCatalog: ChatModelCatalog {
    public var catalogs: [(provider: String, catalog: any ChatModelCatalog)]
    public var qualifyIDs: Bool
    /// When true, a failing catalog is skipped instead of failing the whole list.
    public var skipsFailures: Bool

    public init(_ catalogs: [(provider: String, catalog: any ChatModelCatalog)], qualifyIDs: Bool = true, skipsFailures: Bool = true) {
        self.catalogs = catalogs
        self.qualifyIDs = qualifyIDs
        self.skipsFailures = skipsFailures
    }

    public func models() async throws -> [ChatModel] {
        var all: [ChatModel] = []
        var firstError: (any Error)?
        for (provider, catalog) in catalogs {
            do {
                for var model in try await catalog.models() {
                    if qualifyIDs, !model.id.hasPrefix("\(provider)/") { model.id = "\(provider)/\(model.id)" }
                    if model.provider == nil { model.provider = provider }
                    all.append(model)
                }
            } catch {
                if !skipsFailures { throw error }
                firstError = firstError ?? error
            }
        }
        if all.isEmpty, let firstError { throw firstError }
        return all
    }
}

/// Caches another catalog's list for `lifetime`.
public actor CachedModelCatalog: ChatModelCatalog {
    private let base: any ChatModelCatalog
    private let lifetime: Duration
    private var cached: (models: [ChatModel], at: ContinuousClock.Instant)?
    private var inFlight: Task<[ChatModel], any Error>?

    public init(_ base: any ChatModelCatalog, lifetime: Duration = .seconds(3_600)) {
        self.base = base
        self.lifetime = lifetime
    }

    public func models() async throws -> [ChatModel] {
        if let cached, cached.at.duration(to: .now) < lifetime { return cached.models }
        if let inFlight { return try await inFlight.value }
        let base = base
        let task = Task { try await base.models() }
        inFlight = task
        defer { inFlight = nil }
        let models = try await task.value
        cached = (models, .now)
        return models
    }

    /// Forgets the cached list so the next call fetches it again.
    public func invalidate() {
        cached = nil
    }
}
