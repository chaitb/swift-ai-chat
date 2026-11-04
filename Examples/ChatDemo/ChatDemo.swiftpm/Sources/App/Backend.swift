import Foundation

enum Backend: String, CaseIterable, Identifiable, Sendable {
    case demo
    case anthropic
    case openAI
    case aiSDK

    var id: String { rawValue }

    var title: String {
        switch self {
        case .demo: "Offline demo"
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .aiSDK: "AI SDK endpoint"
        }
    }

    var symbol: String {
        switch self {
        case .demo: "sparkles"
        case .anthropic: "asterisk"
        case .openAI: "circle.hexagongrid"
        case .aiSDK: "point.3.connected.trianglepath.dotted"
        }
    }

    static let anthropicAccount = "anthropic-api-key"
    static let openAIAccount = "openai-api-key"
}

struct BackendSettings: Equatable, Sendable {
    var backend: Backend
    var anthropicKey: String
    var openAIKey: String
    var endpoint: String

    private static let backendKey = "demo.backend"
    private static let endpointKey = "demo.endpoint"

    static func load() -> BackendSettings {
        let defaults = UserDefaults.standard
        return BackendSettings(
            backend: defaults.string(forKey: backendKey).flatMap(Backend.init(rawValue:)) ?? .demo,
            anthropicKey: Keychain.read(Backend.anthropicAccount) ?? "",
            openAIKey: Keychain.read(Backend.openAIAccount) ?? "",
            endpoint: defaults.string(forKey: endpointKey) ?? ""
        )
    }

    func save(replacing previous: BackendSettings) {
        let defaults = UserDefaults.standard
        defaults.set(backend.rawValue, forKey: Self.backendKey)
        defaults.set(endpoint, forKey: Self.endpointKey)
        if anthropicKey != previous.anthropicKey { Keychain.write(anthropicKey, for: Backend.anthropicAccount) }
        if openAIKey != previous.openAIKey { Keychain.write(openAIKey, for: Backend.openAIAccount) }
    }

    var endpointURL: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true, url.host() != nil else { return nil }
        return url
    }

    var effectiveBackend: Backend {
        switch backend {
        case .demo: .demo
        case .anthropic: anthropicKey.isEmpty ? .demo : .anthropic
        case .openAI: openAIKey.isEmpty ? .demo : .openAI
        case .aiSDK: endpointURL == nil ? .demo : .aiSDK
        }
    }
}
