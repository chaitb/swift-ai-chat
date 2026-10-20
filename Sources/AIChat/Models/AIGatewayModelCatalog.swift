import Foundation

/// The models of the Vercel AI Gateway, from `GET https://ai-gateway.vercel.sh/v1/models`.
///
/// Ids have the `provider/model` form the gateway and AI SDK backends accept, such
/// as `anthropic/claude-opus-5-5`. Only language models are listed by default.
public struct AIGatewayModelCatalog: ChatModelCatalog {
    public var url: URL
    public var headers: [String: String]
    public var httpClient: any HTTPStreamingClient
    /// Which models to keep. The default keeps language models that aren't deprecated.
    public var filter: @Sendable (ChatModel) -> Bool

    public init(
        url: URL = URL(string: "https://ai-gateway.vercel.sh/v1/models")!,
        headers: [String: String] = [:],
        httpClient: any HTTPStreamingClient = URLSessionStreamingClient(),
        filter: @escaping @Sendable (ChatModel) -> Bool = AIGatewayModelCatalog.isCurrentLanguageModel
    ) {
        self.url = url
        self.headers = headers
        self.httpClient = httpClient
        self.filter = filter
    }

    public func models() async throws -> [ChatModel] {
        let value = try await ModelListRequest.fetchJSON(url: url, headers: headers, httpClient: httpClient, operation: "gateway.models")
        guard let data = value["data"]?.arrayValue else {
            throw ChatError(kind: .decoding, message: "The model list has no data array.", operation: "gateway.models")
        }
        return data.compactMap(Self.model(from:)).filter(filter)
    }

    public static func model(from value: JSONValue) -> ChatModel? {
        guard let id = value["id"]?.stringValue else { return nil }
        let tags = Set((value["tags"]?.arrayValue ?? []).compactMap(\.stringValue))
        var capabilities = Set<ChatModelCapability>()
        if tags.contains("vision") { capabilities.insert(.imageInput) }
        if tags.contains("file-input") { capabilities.insert(.fileInput) }
        if tags.contains("tool-use") { capabilities.insert(.toolUse) }
        if tags.contains("reasoning") { capabilities.insert(.reasoning) }
        if tags.contains("structured-output") { capabilities.insert(.structuredOutput) }
        if tags.contains("web-search") { capabilities.insert(.webSearch) }
        if tags.contains("image-generation") { capabilities.insert(.imageGeneration) }
        let inputs = Set((value["modalities"]?["input"]?.arrayValue ?? []).compactMap(\.stringValue))
        if inputs.contains("image") { capabilities.insert(.imageInput) }
        if inputs.contains("file") { capabilities.insert(.fileInput) }
        let perToken = { (key: String) -> Double? in
            guard let raw = value["pricing"]?[key] else { return nil }
            let price = raw.stringValue.flatMap(Double.init) ?? raw.doubleValue
            return price.map { $0 * 1_000_000 }
        }
        let description = value["description"]?.stringValue
        return ChatModel(
            id: id,
            displayName: value["name"]?.stringValue,
            provider: value["owned_by"]?.stringValue ?? id.split(separator: "/").first.map(String.init),
            summary: description?.isEmpty == false ? description : nil,
            contextWindow: value["context_window"]?.intValue,
            maxOutputTokens: value["max_tokens"]?.intValue,
            capabilities: capabilities,
            createdAt: (value["released"]?.doubleValue ?? value["created"]?.doubleValue).map(Date.init(timeIntervalSince1970:)),
            inputPricePerMillionTokens: perToken("input"),
            outputPricePerMillionTokens: perToken("output"),
            raw: value
        )
    }

    @Sendable public static func isCurrentLanguageModel(_ model: ChatModel) -> Bool {
        guard model.raw?["type"]?.stringValue ?? "language" == "language" else { return false }
        if let deprecatedAt = model.raw?["deprecated_at"], !deprecatedAt.isNull { return false }
        return true
    }
}

/// Fetches a JSON document for model catalogs.
public enum ModelListRequest {
    public static func fetchJSON(
        url: URL,
        headers: [String: String],
        httpClient: any HTTPStreamingClient,
        operation: String,
        parseError: (@Sendable (Data) -> (message: String?, code: String?))? = nil
    ) async throws -> JSONValue {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let response: HTTPStreamResponse
        do {
            response = try await httpClient.send(request)
        } catch {
            throw ChatError.from(error, operation: operation)
        }
        guard response.isSuccess else {
            throw await response.failure(operation: operation, parseError: parseError)
        }
        let data = try await response.collectBody(limit: 32 * 1_024 * 1_024)
        do {
            return try JSONValue(parsing: data)
        } catch {
            throw ChatError(kind: .decoding, message: "The model list isn't valid JSON.", operation: operation, underlying: String(describing: error))
        }
    }
}
