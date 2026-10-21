import AIChat
import Foundation

/// The models an OpenAI API key can use, from `GET /models`.
///
/// The endpoint lists ids only, so capabilities aren't filled in. By default only chat
/// models are kept: embeddings, audio, image, moderation and realtime models are left out.
public struct OpenAIModelCatalog: ChatModelCatalog {
    public var configuration: OpenAIConfiguration
    public var filter: @Sendable (ChatModel) -> Bool

    public init(configuration: OpenAIConfiguration, filter: @escaping @Sendable (ChatModel) -> Bool = OpenAIModelCatalog.isChatModel) {
        self.configuration = configuration
        self.filter = filter
    }

    public init(apiKey: String) {
        self.init(configuration: .apiKey(apiKey))
    }

    public func models() async throws -> [ChatModel] {
        var headers = configuration.requestHeaders(extra: [:])
        headers["content-type"] = nil
        let value = try await ModelListRequest.fetchJSON(
            url: configuration.endpoint("models"),
            headers: headers,
            httpClient: configuration.httpClient,
            operation: "openai.models",
            parseError: OpenAIChatTransport.parseError
        )
        guard let data = value["data"]?.arrayValue else {
            throw ChatError(kind: .decoding, message: "The model list has no data array.", operation: "openai.models")
        }
        return data.compactMap(Self.model(from:)).filter(filter).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    public static func model(from value: JSONValue) -> ChatModel? {
        guard let id = value["id"]?.stringValue else { return nil }
        return ChatModel(
            id: id,
            provider: "openai",
            createdAt: value["created"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            raw: value
        )
    }

    @Sendable public static func isChatModel(_ model: ChatModel) -> Bool {
        let id = model.id.lowercased()
        let excluded = ["embedding", "tts", "whisper", "transcribe", "dall-e", "image", "moderation", "realtime", "audio", "davinci", "babbage", "sora", "computer-use"]
        guard !excluded.contains(where: id.contains) else { return false }
        return id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.hasPrefix("chatgpt-") || id.hasPrefix("ft:gpt-")
    }
}
