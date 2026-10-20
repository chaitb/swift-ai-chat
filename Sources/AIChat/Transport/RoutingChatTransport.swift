import Foundation

/// Picks a transport per request from the provider prefix of the model id.
///
/// With routes for `anthropic` and `openai`, a chat whose ``Chat/modelID`` is
/// `anthropic/claude-opus-5-5` is sent through the Anthropic transport with the
/// model id `claude-opus-5-5`. Pair it with ``CompositeModelCatalog`` to offer
/// models from several providers in one picker.
public struct RoutingChatTransport: ChatTransport {
    public var routes: [String: any ChatTransport]
    /// Used when the model id has no known provider prefix, and for reconnecting.
    public var defaultTransport: (any ChatTransport)?

    public init(routes: [String: any ChatTransport], defaultTransport: (any ChatTransport)? = nil) {
        self.routes = routes
        self.defaultTransport = defaultTransport
    }

    public func sendMessages(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream {
        let (transport, modelID) = try route(for: request.modelID)
        var routed = request
        routed.modelID = modelID
        return try await transport.sendMessages(routed)
    }

    public func reconnectToStream(_ request: ChatReconnectRequest) async throws -> UIMessageChunkStream? {
        try await defaultTransport?.reconnectToStream(request)
    }

    public var resumeStreamIsReplay: Bool { defaultTransport?.resumeStreamIsReplay ?? false }

    /// The transport and the provider's own model id for a qualified model id.
    public func route(for modelID: String?) throws(ChatError) -> (any ChatTransport, String?) {
        if let modelID, let slash = modelID.firstIndex(of: "/") {
            let provider = String(modelID[..<slash])
            if let transport = routes[provider] {
                return (transport, String(modelID[modelID.index(after: slash)...]))
            }
        }
        guard let defaultTransport else {
            throw ChatError(
                kind: .configuration,
                message: "No transport handles the model \(modelID ?? "(none)"). Use an id like provider/model with one of: \(routes.keys.sorted().joined(separator: ", ")).",
                operation: "routing.sendMessages"
            )
        }
        return (defaultTransport, modelID)
    }
}
