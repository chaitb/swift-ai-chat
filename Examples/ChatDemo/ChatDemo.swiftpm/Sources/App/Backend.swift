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

    var keychainAccount: String? {
        switch self {
        case .anthropic: "anthropic-api-key"
        case .openAI: "openai-api-key"
        case .demo, .aiSDK: nil
        }
    }
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
            anthropicKey: Keychain.read(Backend.anthropic.keychainAccount ?? "") ?? "",
            openAIKey: Keychain.read(Backend.openAI.keychainAccount ?? "") ?? "",
            endpoint: defaults.string(forKey: endpointKey) ?? ""
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(backend.rawValue, forKey: Self.backendKey)
        defaults.set(endpoint, forKey: Self.endpointKey)
        Keychain.write(anthropicKey, for: Backend.anthropic.keychainAccount ?? "")
        Keychain.write(openAIKey, for: Backend.openAI.keychainAccount ?? "")
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
