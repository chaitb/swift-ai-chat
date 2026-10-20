import Foundation

/// Sends a conversation to a backend and streams the assistant's response.
///
/// The package ships transports for AI SDK backends (``AISDKChatTransport``), plain
/// text streams (``TextStreamChatTransport``), Anthropic (`AIChatAnthropic`) and
/// OpenAI (`AIChatOpenAI`). Implement this protocol to talk to anything else.
public protocol ChatTransport: Sendable {
    /// Sends the messages and returns the response as UI message chunks.
    ///
    /// Throw a ``ChatError`` (or any error) when the request fails before streaming.
    /// Cancelling the consuming task cancels the request.
    func sendMessages(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream

    /// Reconnects to a response that is still streaming, for example after the app
    /// was suspended. Returns `nil` when there is nothing to resume.
    func reconnectToStream(_ request: ChatReconnectRequest) async throws -> UIMessageChunkStream?

    /// Whether ``reconnectToStream(_:)`` replays the whole response from its first
    /// chunk, rather than continuing where the dropped connection stopped.
    var resumeStreamIsReplay: Bool { get }
}

extension ChatTransport {
    public func reconnectToStream(_ request: ChatReconnectRequest) async throws -> UIMessageChunkStream? {
        nil
    }

    public var resumeStreamIsReplay: Bool { false }
}

/// Why a request is being sent.
public enum ChatTrigger: String, Sendable, Hashable, Codable {
    /// A new user message, or a continuation after tool results or approvals.
    case submitMessage = "submit-message"
    /// A new response for the last user message.
    case regenerateMessage = "regenerate-message"
}

/// Everything a transport needs to send one turn.
public struct ChatTransportRequest: Sendable {
    public var trigger: ChatTrigger
    public var chatID: String
    /// The message being edited or regenerated, when there is one.
    public var messageID: String?
    /// The whole conversation, oldest first.
    public var messages: [UIMessage]
    /// The model chosen for this conversation, if any. Transports fall back to their default.
    public var modelID: String?
    /// The client-side tools registered on the chat.
    public var tools: [ChatToolDefinition]
    public var headers: [String: String]
    /// Extra JSON body fields, from ``ChatRequestOptions/body``.
    public var body: [String: JSONValue]
    /// Request metadata, from ``ChatRequestOptions/metadata``.
    public var metadata: JSONValue?

    public init(
        trigger: ChatTrigger,
        chatID: String,
        messageID: String? = nil,
        messages: [UIMessage],
        modelID: String? = nil,
        tools: [ChatToolDefinition] = [],
        headers: [String: String] = [:],
        body: [String: JSONValue] = [:],
        metadata: JSONValue? = nil
    ) {
        self.trigger = trigger
        self.chatID = chatID
        self.messageID = messageID
        self.messages = messages
        self.modelID = modelID
        self.tools = tools
        self.headers = headers
        self.body = body
        self.metadata = metadata
    }
}

/// Everything a transport needs to reconnect to a streaming response.
public struct ChatReconnectRequest: Sendable {
    public var chatID: String
    /// The conversation as the client has it, for transports that recover by other means.
    public var messages: [UIMessage]
    public var headers: [String: String]
    public var body: [String: JSONValue]
    public var metadata: JSONValue?

    public init(
        chatID: String,
        messages: [UIMessage] = [],
        headers: [String: String] = [:],
        body: [String: JSONValue] = [:],
        metadata: JSONValue? = nil
    ) {
        self.chatID = chatID
        self.messages = messages
        self.headers = headers
        self.body = body
        self.metadata = metadata
    }
}

/// Per-request options, like the AI SDK's `ChatRequestOptions`.
public struct ChatRequestOptions: Sendable {
    public var headers: [String: String]
    public var body: [String: JSONValue]
    public var metadata: JSONValue?
    /// Overrides the chat's model for this request only.
    public var modelID: String?

    public init(headers: [String: String] = [:], body: [String: JSONValue] = [:], metadata: JSONValue? = nil, modelID: String? = nil) {
        self.headers = headers
        self.body = body
        self.metadata = metadata
        self.modelID = modelID
    }
}
