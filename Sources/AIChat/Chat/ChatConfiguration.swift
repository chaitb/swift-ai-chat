import Foundation

/// Where a ``Chat`` is in a request.
public enum ChatStatus: String, Sendable, Hashable, Codable {
    /// Nothing is running. A new message can be sent.
    case ready
    /// The request was sent and the response hasn't started.
    case submitted
    /// The response is streaming in.
    case streaming
    /// The last request failed. See ``Chat/error``.
    case error

    /// Whether a request is running.
    public var isBusy: Bool { self == .submitted || self == .streaming }
}

/// What happened when a response ended, passed to ``ChatConfiguration/onFinish``.
public struct ChatFinishEvent: Sendable {
    /// The assistant message that was streamed.
    public var message: UIMessage
    /// The whole conversation, including the message.
    public var messages: [UIMessage]
    /// Whether ``Chat/stop()`` ended the response.
    public var isAbort: Bool
    /// Whether the connection dropped.
    public var isDisconnect: Bool
    /// Whether the response ended with an error.
    public var isError: Bool
    public var finishReason: FinishReason?
}

/// Decides whether ``Chat`` sends the conversation again on its own, after tool
/// results or approval responses complete the last assistant message.
public struct AutoSendPolicy: Sendable {
    public let shouldSend: @MainActor @Sendable ([UIMessage]) -> Bool

    public init(_ shouldSend: @escaping @MainActor @Sendable ([UIMessage]) -> Bool) {
        self.shouldSend = shouldSend
    }

    public static let never = AutoSendPolicy { _ in false }

    /// Sends when every client-side tool call of the last step has an output, an error or a denial.
    public static let lastAssistantMessageIsCompleteWithToolCalls = AutoSendPolicy { messages in
        ChatHelpers.lastAssistantMessageIsCompleteWithToolCalls(messages)
    }

    /// Sends when the last step has an approval response and nothing else is waiting.
    public static let lastAssistantMessageIsCompleteWithApprovalResponses = AutoSendPolicy { messages in
        ChatHelpers.lastAssistantMessageIsCompleteWithApprovalResponses(messages)
    }

    /// Sends when any of the policies would.
    public static func any(_ policies: AutoSendPolicy...) -> AutoSendPolicy {
        AutoSendPolicy { messages in policies.contains { $0.shouldSend(messages) } }
    }
}

/// How ``Chat`` recovers a response whose connection dropped.
public struct ResumePolicy: Sendable {
    /// How many times to call ``ChatTransport/reconnectToStream(_:)`` after a disconnect.
    public var attempts: Int
    /// The wait before the first attempt, doubled after each failed one.
    public var initialDelay: Duration

    public init(attempts: Int = 3, initialDelay: Duration = .seconds(1)) {
        self.attempts = attempts
        self.initialDelay = initialDelay
    }

    /// Never reconnects on its own. ``Chat/resumeStream(options:)`` still works.
    public static let never = ResumePolicy(attempts: 0)
}

/// How a ``Chat`` behaves. Every field has a default.
public struct ChatConfiguration: Sendable {
    /// Client-side tools: declared to direct provider transports and run on device.
    public var tools: [ChatTool]
    /// When to send again on its own. `nil` sends after tool results only when tools are registered.
    public var sendAutomaticallyWhen: AutoSendPolicy?
    /// The most automatic follow-up requests in a row, to stop runaway tool loops.
    public var maxAutomaticSends: Int
    /// Called for every tool call the client should answer, after the part is shown.
    public var onToolCall: (@MainActor @Sendable (ToolCall) async -> Void)?
    public var onFinish: (@MainActor @Sendable (ChatFinishEvent) -> Void)?
    public var onError: (@MainActor @Sendable (ChatError) -> Void)?
    /// Called for every `data-*` chunk, including transient ones that never join a message.
    public var onData: (@MainActor @Sendable (DataChunk) -> Void)?
    /// The least time between two updates of ``Chat/messages`` while streaming.
    /// `nil` updates on every chunk. Around 50 ms keeps long markdown cheap to render.
    public var updateInterval: Duration?
    /// Fails the response on chunks that break the protocol instead of tolerating them.
    public var strictProtocol: Bool
    public var resumePolicy: ResumePolicy
    /// Saves the conversation after every user message and finished response.
    public var store: (any ChatStore)?
    /// Headers, body fields and metadata sent with every request.
    public var requestOptions: ChatRequestOptions
    public var generateID: @Sendable () -> String

    public init(
        tools: [ChatTool] = [],
        sendAutomaticallyWhen: AutoSendPolicy? = nil,
        maxAutomaticSends: Int = 20,
        onToolCall: (@MainActor @Sendable (ToolCall) async -> Void)? = nil,
        onFinish: (@MainActor @Sendable (ChatFinishEvent) -> Void)? = nil,
        onError: (@MainActor @Sendable (ChatError) -> Void)? = nil,
        onData: (@MainActor @Sendable (DataChunk) -> Void)? = nil,
        updateInterval: Duration? = nil,
        strictProtocol: Bool = false,
        resumePolicy: ResumePolicy = .never,
        store: (any ChatStore)? = nil,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        generateID: @escaping @Sendable () -> String = ChatID.generate
    ) {
        self.tools = tools
        self.sendAutomaticallyWhen = sendAutomaticallyWhen
        self.maxAutomaticSends = maxAutomaticSends
        self.onToolCall = onToolCall
        self.onFinish = onFinish
        self.onError = onError
        self.onData = onData
        self.updateInterval = updateInterval
        self.strictProtocol = strictProtocol
        self.resumePolicy = resumePolicy
        self.store = store
        self.requestOptions = requestOptions
        self.generateID = generateID
    }

    var effectiveAutoSendPolicy: AutoSendPolicy {
        if let sendAutomaticallyWhen { return sendAutomaticallyWhen }
        return tools.isEmpty ? .never : .lastAssistantMessageIsCompleteWithToolCalls
    }

    func tool(named name: String) -> ChatTool? {
        tools.first { $0.name == name }
    }
}

/// Conversation checks shared by ``AutoSendPolicy`` and transports.
public enum ChatHelpers {
    /// Whether the last message is an assistant message whose last step has at least one
    /// client-side tool call, and every such call has an output, an error or a denial.
    public static func lastAssistantMessageIsCompleteWithToolCalls(_ messages: [UIMessage]) -> Bool {
        guard let message = messages.last, message.role == .assistant else { return false }
        let calls = message.lastStepParts.compactMap(\.toolPart).filter { $0.providerExecuted != true }
        return !calls.isEmpty && calls.allSatisfy { $0.state.isFinal }
    }

    /// Whether the last message is an assistant message whose last step has at least one
    /// approval response, and every tool call has a response, an output or an error.
    public static func lastAssistantMessageIsCompleteWithApprovalResponses(_ messages: [UIMessage]) -> Bool {
        guard let message = messages.last, message.role == .assistant else { return false }
        let calls = message.lastStepParts.compactMap(\.toolPart)
        return calls.contains { $0.state == .approvalResponded }
            && calls.allSatisfy { $0.state == .outputAvailable || $0.state == .outputError || $0.state == .approvalResponded }
    }
}
