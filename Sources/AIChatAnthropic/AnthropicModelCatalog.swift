import AIChat
import Foundation

/// The Claude models an API key can use, from `GET /v1/models`.
///
/// Each model carries its context window, output limit and capabilities as the
/// Models API reports them, so a picker can show only models that take images
/// when the user attached a photo.
public struct AnthropicModelCatalog: ChatModelCatalog {
    public var configuration: AnthropicConfiguration

    public init(configuration: AnthropicConfiguration) {
        self.configuration = configuration
    }

    public init(apiKey: String) {
        configuration = .apiKey(apiKey)
    }

    public func models() async throws -> [ChatModel] {
        var models: [ChatModel] = []
        var afterID: String?
        var headers = configuration.requestHeaders(extra: [:])
        headers["content-type"] = nil
        repeat {
            var components = URLComponents(url: configuration.baseURL.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)!
            var query = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
            components.queryItems = query
            let page = try await ModelListRequest.fetchJSON(
                url: components.url!,
                headers: headers,
                httpClient: configuration.httpClient,
                operation: "anthropic.models",
                parseError: AnthropicChatTransport.parseError
            )
            let data = page["data"]?.arrayValue ?? []
            models += data.compactMap(Self.model(from:))
            afterID = page["has_more"]?.boolValue == true ? page["last_id"]?.stringValue : nil
        } while afterID != nil
        return models
    }

    public static func model(from value: JSONValue) -> ChatModel? {
        guard let id = value["id"]?.stringValue else { return nil }
        let capabilities = value["capabilities"]
        var set: Set<ChatModelCapability> = [.toolUse]
        func supported(_ path: [String]) -> Bool {
            var node = capabilities
            for key in path { node = node?[key] }
            return node?["supported"]?.boolValue == true
        }
        if capabilities == nil || supported(["image_input"]) { set.insert(.imageInput) }
        if capabilities == nil || supported(["pdf_input"]) { set.insert(.fileInput) }
        if capabilities == nil || supported(["thinking"]) { set.insert(.reasoning) }
        if supported(["structured_outputs"]) { set.insert(.structuredOutput) }
        let created = value["created_at"]?.stringValue.flatMap { string in
            ISO8601DateFormatter().date(from: string) ?? {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: string)
            }()
        }
        return ChatModel(
            id: id,
            displayName: value["display_name"]?.stringValue,
            provider: "anthropic",
            contextWindow: value["max_input_tokens"]?.intValue,
            maxOutputTokens: value["max_tokens"]?.intValue,
            capabilities: set,
            createdAt: created,
            raw: value
        )
    }
}
