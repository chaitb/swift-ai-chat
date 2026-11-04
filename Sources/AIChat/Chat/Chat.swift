import Foundation
import Observation

/// A conversation: its messages, its streaming state and the actions that drive it.
///
/// `Chat` is the Swift counterpart of the AI SDK's `Chat` class behind `useChat`. It
/// owns no views. Observe ``messages``, ``status`` and ``error`` from SwiftUI and
/// call ``sendMessage(_:files:metadata:options:)``, ``stop()``, ``regenerate(messageID:options:)``
/// and ``addToolOutput(toolCallId:output:options:)``.
///
/// ```swift
/// let chat = Chat(transport: AISDKChatTransport(api: URL(string: "https://example.com/api/chat")!))
/// await chat.sendMessage("What's the weather in Paris?")
/// print(chat.messages.last?.text ?? "")
/// ```
///
/// Every action is `async` and returns once the response it started, and any
/// automatic follow-up, has finished. From a button, call it inside a `Task`.
@MainActor
@Observable
public final class Chat: Identifiable {
    public nonisolated let id: String
    /// The conversation, oldest first. Assistant messages update in place while streaming.
    public var messages: [UIMessage]
    public private(set) var status: ChatStatus = .ready
    /// The error of the last request, while ``status`` is `.error`.
    public private(set) var error: ChatError?
    /// The model for this conversation. Sent with every request; `nil` uses the transport's default.
    public var modelID: String?
    /// A title for the saved conversation.
    public var title: String?
    /// App-defined data saved with the conversation.
    public var metadata: JSONValue?

    @ObservationIgnored public let transport: any ChatTransport
    @ObservationIgnored public var configuration: ChatConfiguration

    @ObservationIgnored private var activeTask: Task<RequestOutcome, Never>?
    @ObservationIgnored private var activeState: StreamingMessageState?
    @ObservationIgnored private var resumableState: StreamingMessageState? {
        didSet { if resumableState == nil { resumableAnnouncedID = nil } }
    }
    @ObservationIgnored private var resumableAnnouncedID: String?
    @ObservationIgnored private var lastWrittenMessageID: String?
    @ObservationIgnored private var continuedMessageID: String?
    @ObservationIgnored private var announcedMessageID: String?
    @ObservationIgnored private var activeConnection: Task<Void, any Error>?
    @ObservationIgnored private var reconnectRequested = false
    @ObservationIgnored private var answeredSinceLastRequest = false
    @ObservationIgnored private var reportedToolOutputs: Set<String> = []
    @ObservationIgnored private var handledToolCalls: Set<String> = []
    @ObservationIgnored private var clientToolParts: [String: ToolPart] = [:]
    private var toolTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var automaticSends = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var createdAt: Date
    @ObservationIgnored private var lastPublish: ContinuousClock.Instant?
    @ObservationIgnored private var pendingPublish = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    public init(
        id: String? = nil,
        messages: [UIMessage] = [],
        modelID: String? = nil,
        transport: any ChatTransport,
        configuration: ChatConfiguration = ChatConfiguration()
    ) {
        self.id = id ?? configuration.generateID()
        self.messages = messages
        self.modelID = modelID
        self.transport = transport
        self.configuration = configuration
        createdAt = Date()
    }

    /// Restores a saved conversation from a snapshot.
    public convenience init(snapshot: ChatSnapshot, transport: any ChatTransport, configuration: ChatConfiguration = ChatConfiguration()) {
        self.init(id: snapshot.id, messages: snapshot.messages, modelID: snapshot.modelID, transport: transport, configuration: configuration)
        title = snapshot.title
        metadata = snapshot.metadata
        createdAt = snapshot.createdAt
    }

    /// Loads a saved conversation from `configuration.store`, or starts a new one with that id.
    public static func restore(id: String, transport: any ChatTransport, configuration: ChatConfiguration) async throws -> Chat {
        guard let store = configuration.store else {
            throw ChatError(kind: .configuration, message: "Restoring a chat needs a store in the configuration.")
        }
        if let snapshot = try await store.loadChat(id: id) {
            return Chat(snapshot: snapshot, transport: transport, configuration: configuration)
        }
        return Chat(id: id, transport: transport, configuration: configuration)
    }

    public var lastMessage: UIMessage? { messages.last }

    /// Whether a request or a client-side tool is running.
    public var isBusy: Bool { status.isBusy || !toolTasks.isEmpty }

    /// The conversation as it would be saved.
    public var snapshot: ChatSnapshot {
        ChatSnapshot(
            id: id,
            messages: messages,
            modelID: modelID,
            title: title ?? ChatSnapshot.defaultTitle(for: messages),
            metadata: metadata,
            createdAt: createdAt,
            updatedAt: Date()
        )
    }

    // MARK: - Sending

    /// Sends a user message with text and optional attachments, then streams the response.
    public func sendMessage(_ text: String, files: [FilePart] = [], metadata: JSONValue? = nil, options: ChatRequestOptions = ChatRequestOptions()) async {
        await sendMessage(parts: Self.parts(text: text, files: files), metadata: metadata, options: options)
    }

    /// Sends a user message made of `parts`, then streams the response.
    public func sendMessage(parts: [UIMessagePart], metadata: JSONValue? = nil, options: ChatRequestOptions = ChatRequestOptions()) async {
        await sendMessage(UIMessage(id: configuration.generateID(), role: .user, parts: parts, metadata: metadata), options: options)
    }

    /// Appends `message` and streams the response.
    public func sendMessage(_ message: UIMessage, options: ChatRequestOptions = ChatRequestOptions()) async {
        await cancelActiveRequest()
        forgetToolCalls()
        messages.append(message)
        save()
        await run(trigger: .submit, messageID: nil, options: options, automatic: false)
    }

    /// Sends the conversation as it is, without a new message: to continue after editing
    /// ``messages`` yourself, or to start a flow on a backend that opens the conversation.
    ///
    /// The response continues the last message when that's an assistant message. Pass
    /// `messageID` to continue an earlier assistant message instead, for example when the
    /// user answers a tool call in it after the conversation moved on. The request's
    /// ``ChatTransportRequest/messageID`` names the message being continued. A
    /// `messageID` that names no assistant message fails with a configuration error.
    public func submit(continuing messageID: String? = nil, options: ChatRequestOptions = ChatRequestOptions()) async {
        await cancelActiveRequest()
        if let messageID {
            guard let message = messages.last(where: { $0.id == messageID }) else {
                fail(ChatError(kind: .configuration, message: "Message \(messageID) was not found.", operation: "chat.submit"))
                return
            }
            guard message.role == .assistant else {
                fail(ChatError(kind: .configuration, message: "Message \(messageID) is not an assistant message.", operation: "chat.submit"))
                return
            }
        }
        await run(trigger: .submit, messageID: messageID ?? messages.last?.id, options: options, automatic: false)
    }

    /// Replaces the user message `messageID`, drops everything after it and streams a new response.
    public func editMessage(
        _ messageID: String,
        text: String,
        files: [FilePart] = [],
        metadata: JSONValue? = nil,
        options: ChatRequestOptions = ChatRequestOptions()
    ) async {
        await cancelActiveRequest()
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            fail(ChatError(kind: .configuration, message: "Message \(messageID) was not found.", operation: "chat.editMessage"))
            return
        }
        guard messages[index].role == .user else {
            fail(ChatError(kind: .configuration, message: "Message \(messageID) is not a user message.", operation: "chat.editMessage"))
            return
        }
        forgetToolCalls()
        messages = Array(messages[...index])
        messages[index] = UIMessage(id: messageID, role: .user, parts: Self.parts(text: text, files: files), metadata: metadata)
        save()
        await run(trigger: .submit, messageID: messageID, options: options, automatic: false)
    }

    /// Streams a new response for the assistant message `messageID`, or the last one.
    public func regenerate(messageID: String? = nil, options: ChatRequestOptions = ChatRequestOptions()) async {
        await cancelActiveRequest()
        let index = messageID.map { id in messages.firstIndex { $0.id == id } } ?? (messages.isEmpty ? nil : messages.count - 1)
        guard let index else {
            fail(ChatError(kind: .configuration, message: "Message \(messageID ?? "") was not found.", operation: "chat.regenerate"))
            return
        }
        forgetToolCalls()
        messages = Array(messages[..<(messages[index].role == .assistant ? index : index + 1)])
        await run(trigger: .regenerate, messageID: messageID, options: options, automatic: false)
    }

    /// Reconnects to a response that is still streaming on the server, for example
    /// when the app opens a conversation or returns to the foreground. Does nothing
    /// when the transport has nothing to resume.
    public func resumeStream(options: ChatRequestOptions = ChatRequestOptions()) async {
        guard activeTask == nil else { return }
        await run(trigger: .resume, messageID: nil, options: options, automatic: false)
    }

    /// Drops the connection of the running response and recovers the response with
    /// ``ChatTransport/reconnectToStream(_:)``, keeping the status and what already streamed.
    ///
    /// Call it when the app returns to the foreground after its connection may have
    /// gone stale in the background. It makes at least one attempt, without waiting,
    /// then follows ``ChatConfiguration/resumePolicy``. Calling it again while that
    /// attempt reads adds another one. With a transport that can't reconnect, the
    /// response ends with a disconnect error. Does nothing when no response is streaming.
    public func reconnect() {
        guard let activeConnection else { return }
        reconnectRequested = true
        activeConnection.cancel()
    }

    /// Stops the running response and any client tools it started. Streamed parts are kept.
    public func stop() {
        activeTask?.cancel()
        for (callID, task) in toolTasks {
            task.cancel()
            updateToolPart(callID: callID) { part in
                part.state = .outputError
                part.errorText = "The tool was stopped."
            }
        }
        toolTasks = [:]
    }

    /// Clears the error and returns to `.ready`.
    public func clearError() {
        guard status == .error else { return }
        error = nil
        status = .ready
    }

    /// Stops any response and empties the conversation.
    public func reset() async {
        stop()
        await cancelActiveRequest()
        messages = []
        error = nil
        resumableState = nil
        answeredSinceLastRequest = false
        forgetToolCalls()
        status = .ready
        save()
    }

    // MARK: - Tools

    /// Adds the output of a client-side tool call. When that completes the step, the
    /// conversation is sent again according to ``ChatConfiguration/sendAutomaticallyWhen``.
    public func addToolOutput(toolCallId: String, output: JSONValue, options: ChatRequestOptions = ChatRequestOptions()) async {
        toolTasks[toolCallId] = nil
        let messageID = answerToolPart(callID: toolCallId) { part in
            part.state = .outputAvailable
            part.output = output
            part.errorText = nil
        }
        await sendAutomaticallyIfNeeded(continuing: messageID, options: options)
    }

    /// Records that a client-side tool call failed.
    public func addToolOutput(toolCallId: String, errorText: String, options: ChatRequestOptions = ChatRequestOptions()) async {
        toolTasks[toolCallId] = nil
        let messageID = answerToolPart(callID: toolCallId) { part in
            part.state = .outputError
            part.output = nil
            part.errorText = errorText
        }
        await sendAutomaticallyIfNeeded(continuing: messageID, options: options)
    }

    /// Answers an approval request.
    ///
    /// For a registered tool with ``ChatTool/needsApproval``, an approval runs the tool
    /// on device and a denial tells the model the user declined. For approvals the
    /// server asked for, the response is recorded and sent back to the server.
    public func addToolApprovalResponse(approvalID: String, approved: Bool, reason: String? = nil, options: ChatRequestOptions = ChatRequestOptions()) async {
        guard let part = messages.reversed().lazy.flatMap(\.toolParts).first(where: { $0.approval?.id == approvalID }) else { return }
        let localTool = configuration.tool(named: part.toolName).flatMap { $0.needsApproval ? $0 : nil }
        let messageID = answerToolPart(callID: part.toolCallId) { part in
            var approval = part.approval ?? ToolApproval(id: approvalID)
            approval.approved = approved
            approval.reason = reason
            part.approval = approval
            part.state = localTool != nil && !approved ? .outputDenied : .approvalResponded
        }
        if let localTool, approved, let execute = localTool.execute {
            let call = ToolCall(toolCallId: part.toolCallId, toolName: part.toolName, input: part.input ?? .null, dynamic: part.isDynamic)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await runTool(call, execute: execute, options: options)
            }
            toolTasks[call.toolCallId] = task
            await task.value
            return
        }
        await sendAutomaticallyIfNeeded(continuing: messageID, options: options)
    }

    // MARK: - Requests

    private enum Trigger {
        case submit
        case regenerate
        case resume
    }

    private struct RequestOutcome {
        var ran = false
        var isAbort = false
        var isError = false
    }

    private static func parts(text: String, files: [FilePart]) -> [UIMessagePart] {
        files.map(UIMessagePart.file) + (text.isEmpty && !files.isEmpty ? [] : [UIMessagePart.text(text)])
    }

    private func cancelActiveRequest() async {
        guard let activeTask else { return }
        activeTask.cancel()
        _ = await activeTask.value
    }

    private func run(trigger: Trigger, messageID: String?, options: ChatRequestOptions, automatic: Bool) async {
        if automatic {
            automaticSends += 1
            guard automaticSends <= configuration.maxAutomaticSends else { return }
        } else {
            automaticSends = 0
        }
        let task = Task { @MainActor [self] in
            await perform(trigger: trigger, messageID: messageID, options: options)
        }
        activeTask = task
        let outcome = await task.value
        if activeTask == task { activeTask = nil }
        guard outcome.ran, !outcome.isAbort, !outcome.isError, toolTasks.isEmpty else { return }
        if shouldSendAutomatically() {
            await run(trigger: .submit, messageID: messages.last?.id, options: options, automatic: true)
        }
    }

    private func perform(trigger: Trigger, messageID: String?, options: ChatRequestOptions) async -> RequestOutcome {
        var outcome = RequestOutcome()
        let merged = mergedOptions(options)
        var resumed: UIMessageChunkStream?

        if trigger == .resume {
            do {
                guard let stream = try await transport.reconnectToStream(reconnectRequest(merged, messageID: resumeMessageID())) else {
                    resumableState = nil
                    return outcome
                }
                resumed = stream
            } catch {
                let failure = ChatError.from(error, operation: "chat.resumeStream")
                guard !failure.isCancelled else { return outcome }
                fail(failure)
                outcome.isError = true
                return outcome
            }
        }

        outcome.ran = true
        setStatus(.submitted)
        error = nil
        lastWrittenMessageID = nil
        continuedMessageID = nil
        announcedMessageID = nil
        activeState = makeState(trigger: trigger, messageID: messageID)
        if trigger != .resume {
            resumableState = nil
            answeredSinceLastRequest = false
        }

        var failure: ChatError?
        do {
            let stream: UIMessageChunkStream
            if let resumed {
                stream = resumed
            } else {
                stream = try await transport.sendMessages(ChatTransportRequest(
                    trigger: trigger == .regenerate ? .regenerateMessage : .submitMessage,
                    chatID: id,
                    messageID: messageID,
                    messages: messages,
                    modelID: merged.modelID ?? modelID,
                    tools: configuration.tools.map(\.definition),
                    headers: merged.headers,
                    body: merged.body,
                    metadata: merged.metadata
                ))
            }
            try await consume(stream)
        } catch {
            failure = ChatError.from(error, operation: "chat.stream")
        }

        if let disconnect = failure, disconnect.isDisconnect, !Task.isCancelled {
            let requested = disconnect.code == Self.reconnectRequestedCode
            if requested || configuration.resumePolicy.attempts > 0 {
                failure = await recover(from: disconnect, options: merged, immediately: requested)
            }
        }

        flushPublish()
        if let state = activeState, state.message != messages.last(where: { $0.id == state.message.id }), !state.message.isEmpty || lastWrittenMessageID != nil {
            writeActiveMessage()
        }
        let isAbort = Task.isCancelled || failure?.isCancelled == true
        outcome.isAbort = isAbort
        if isAbort {
            resumableState = nil
            setStatus(.ready)
        } else if let failure {
            outcome.isError = true
            resumableState = failure.isDisconnect ? activeState : nil
            resumableAnnouncedID = failure.isDisconnect ? announcedMessageID : nil
            fail(failure)
        } else {
            resumableState = nil
            setStatus(.ready)
        }
        if let state = activeState {
            configuration.onFinish?(ChatFinishEvent(
                message: state.message,
                messages: messages,
                isAbort: isAbort,
                isDisconnect: failure?.isDisconnect == true,
                isError: outcome.isError,
                finishReason: state.finishReason
            ))
        }
        activeState = nil
        lastWrittenMessageID = nil
        continuedMessageID = nil
        announcedMessageID = nil
        save()
        return outcome
    }

    private func makeState(trigger: Trigger, messageID: String?) -> StreamingMessageState {
        let strict = configuration.strictProtocol
        switch trigger {
        case .resume:
            let behavior = StreamingMessageState.ResumeBehavior(
                resetsOnFirstStart: transport.resumeStreamIsReplay,
                resetsOnMessageIDChange: true
            )
            if !transport.resumeStreamIsReplay, var state = resumableState {
                state.resumeBehavior = behavior
                lastWrittenMessageID = state.message.id
                announcedMessageID = resumableAnnouncedID
                return state
            }
            if let last = messages.last, last.role == .assistant, last.toolParts.contains(where: { Self.awaitsServer($0) }) {
                announcedMessageID = last.id
                return StreamingMessageState(continuing: last, strict: strict, resumeBehavior: behavior)
            }
            return StreamingMessageState(messageID: configuration.generateID(), strict: strict, resumeBehavior: behavior)
        case .regenerate:
            return StreamingMessageState(messageID: configuration.generateID(), strict: strict)
        case .submit:
            let response = messageID.flatMap { id in messages.last { $0.id == id } } ?? messages.last
            if let response, response.role == .assistant {
                lastWrittenMessageID = response.id
                continuedMessageID = response.id
                announcedMessageID = response.id
                return StreamingMessageState(continuing: response, strict: strict, resumeBehavior: .init(resetsOnMessageIDChange: true))
            }
            return StreamingMessageState(messageID: configuration.generateID(), strict: strict)
        }
    }

    nonisolated private static func awaitsServer(_ part: ToolPart) -> Bool {
        switch part.state {
        case .inputStreaming, .approvalResponded: true
        case .inputAvailable: part.providerExecuted == true
        default: false
        }
    }

    private func recover(from disconnect: ChatError, options: ChatRequestOptions, immediately: Bool) async -> ChatError? {
        flushPublish()
        var lastFailure = disconnect
        var delay = configuration.resumePolicy.initialDelay
        var attemptsLeft = immediately ? max(1, configuration.resumePolicy.attempts) : configuration.resumePolicy.attempts
        var waits = !immediately
        while attemptsLeft > 0 {
            attemptsLeft -= 1
            if waits {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return .cancelled
                }
                delay *= 2
            }
            waits = true
            do {
                guard let resumed = try await transport.reconnectToStream(reconnectRequest(options, messageID: announcedMessageID)) else { return lastFailure }
                if var state = activeState {
                    if transport.resumeStreamIsReplay {
                        state = StreamingMessageState(
                            messageID: state.message.id,
                            strict: configuration.strictProtocol,
                            resumeBehavior: .init(resetsOnFirstStart: true, resetsOnMessageIDChange: true)
                        )
                    } else {
                        state.resumeBehavior = .init(resetsOnMessageIDChange: true)
                    }
                    activeState = state
                }
                try await consume(resumed)
                return nil
            } catch {
                let failure = ChatError.from(error, operation: "chat.resume")
                guard failure.isDisconnect else { return failure }
                lastFailure = failure
                if failure.code == Self.reconnectRequestedCode {
                    attemptsLeft = max(attemptsLeft, 1)
                    waits = false
                }
            }
        }
        return lastFailure
    }

    private static let reconnectRequestedCode = "reconnect_requested"

    /// Reads `stream` into the active message on a task of its own, so ``reconnect()``
    /// can drop the connection without ending the response.
    private func consume(_ stream: UIMessageChunkStream) async throws {
        reconnectRequested = false
        let connection = Task { @MainActor [self] in
            for try await chunk in stream {
                if Task.isCancelled { break }
                try await apply(chunk)
            }
            try Task.checkCancellation()
        }
        activeConnection = connection
        defer { activeConnection = nil }
        do {
            try await withTaskCancellationHandler {
                try await connection.value
            } onCancel: {
                connection.cancel()
            }
        } catch {
            guard reconnectRequested, !Task.isCancelled else { throw error }
            reconnectRequested = false
            throw ChatError(
                kind: .network,
                message: "The connection was closed to reconnect.",
                code: Self.reconnectRequestedCode,
                operation: "chat.reconnect"
            )
        }
    }

    private func apply(_ chunk: UIMessageChunk) async throws {
        guard var state = activeState else { return }
        let update = try state.apply(chunk)
        activeState = state
        if case .start(let messageID?, _) = chunk {
            announcedMessageID = messageID
        }
        if let continued = continuedMessageID, case .start = chunk {
            continuedMessageID = nil
            if state.message.id != continued { lastWrittenMessageID = nil }
        }
        if update.messageChanged {
            publish(updatesStatus: update.updatesStatus)
        }
        if let data = update.data {
            configuration.onData?(data)
        }
        if let part = update.toolOutput, reportedToolOutputs.insert(part.toolCallId).inserted {
            configuration.onToolOutput?(part)
        }
        if let streamError = update.streamError {
            throw ChatError(kind: .stream, message: streamError, operation: "chat.stream")
        }
        if let toolCall = update.toolCall {
            flushPublish()
            if handledToolCalls.insert(toolCall.toolCallId).inserted {
                await handleToolCall(toolCall)
            } else {
                restoreClientToolPart(callID: toolCall.toolCallId)
            }
        }
    }

    private func reconnectRequest(_ options: ChatRequestOptions, messageID: String?) -> ChatReconnectRequest {
        ChatReconnectRequest(chatID: id, messageID: messageID, messages: messages, headers: options.headers, body: options.body, metadata: options.metadata)
    }

    /// The response ``resumeStream(options:)`` picks up: the one a disconnect cut off,
    /// or the last assistant message while it still waits for the server.
    private func resumeMessageID() -> String? {
        if resumableState != nil { return resumableAnnouncedID }
        guard let last = messages.last, last.role == .assistant, last.toolParts.contains(where: { Self.awaitsServer($0) }) else { return nil }
        return last.id
    }

    private func mergedOptions(_ options: ChatRequestOptions) -> ChatRequestOptions {
        let defaults = configuration.requestOptions
        return ChatRequestOptions(
            headers: defaults.headers.merging(options.headers) { _, new in new },
            body: defaults.body.merging(options.body) { _, new in new },
            metadata: options.metadata ?? defaults.metadata,
            modelID: options.modelID ?? defaults.modelID
        )
    }

    // MARK: - Publishing

    private func publish(updatesStatus: Bool) {
        if updatesStatus, status == .submitted { setStatus(.streaming) }
        guard let interval = configuration.updateInterval else {
            writeActiveMessage()
            return
        }
        let now = ContinuousClock.now
        if let lastPublish, lastPublish.duration(to: now) < interval {
            pendingPublish = true
            if flushTask == nil {
                let wait = interval - lastPublish.duration(to: now)
                flushTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled else { return }
                    self?.flushTask = nil
                    self?.flushPublish()
                }
            }
            return
        }
        writeActiveMessage()
    }

    private func flushPublish() {
        flushTask?.cancel()
        flushTask = nil
        guard pendingPublish else { return }
        writeActiveMessage()
    }

    private func writeActiveMessage() {
        pendingPublish = false
        lastPublish = .now
        guard let message = activeState?.message else { return }
        if let index = messages.lastIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else if let lastWrittenMessageID, let index = messages.lastIndex(where: { $0.id == lastWrittenMessageID }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        lastWrittenMessageID = message.id
    }

    private func setStatus(_ newStatus: ChatStatus) {
        if status != newStatus { status = newStatus }
    }

    private func fail(_ failure: ChatError) {
        error = failure
        status = .error
        configuration.onError?(failure)
    }

    // MARK: - Tool handling

    private func handleToolCall(_ call: ToolCall) async {
        if let tool = configuration.tool(named: call.toolName) {
            if tool.needsApproval {
                let approvalID = configuration.generateID()
                var requested: ToolPart?
                updateToolPart(callID: call.toolCallId) { part in
                    part.state = .approvalRequested
                    part.approval = ToolApproval(id: approvalID)
                    requested = part
                }
                clientToolParts[call.toolCallId] = requested
            } else if let execute = tool.execute {
                toolTasks[call.toolCallId] = Task { @MainActor [weak self] in
                    await self?.runTool(call, execute: execute, options: ChatRequestOptions())
                }
            }
        }
        await configuration.onToolCall?(call)
    }

    private func runTool(_ call: ToolCall, execute: @escaping @Sendable (ToolCall) async throws -> JSONValue, options: ChatRequestOptions) async {
        let result: Result<JSONValue, any Error>
        do {
            result = .success(try await execute(call))
        } catch {
            result = .failure(error)
        }
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let output):
            await addToolOutput(toolCallId: call.toolCallId, output: output, options: options)
        case .failure(let error):
            let message = (error as? ChatError)?.message ?? error.localizedDescription
            await addToolOutput(toolCallId: call.toolCallId, errorText: message, options: options)
        }
    }

    /// Updates the tool part with `callID` wherever it is, and returns its message's id.
    @discardableResult
    private func updateToolPart(callID: String, _ body: (inout ToolPart) -> Void) -> String? {
        if var state = activeState, let index = state.message.indexOfTool(callID: callID), case .tool(var part) = state.message.parts[index] {
            body(&part)
            state.message.parts[index] = .tool(part)
            activeState = state
            writeActiveMessage()
            return state.message.id
        }
        for messageIndex in messages.indices.reversed() {
            guard let partIndex = messages[messageIndex].indexOfTool(callID: callID),
                  case .tool(var part) = messages[messageIndex].parts[partIndex]
            else { continue }
            body(&part)
            messages[messageIndex].parts[partIndex] = .tool(part)
            return messages[messageIndex].id
        }
        return nil
    }

    private func shouldSendAutomatically() -> Bool {
        answeredSinceLastRequest && configuration.effectiveAutoSendPolicy.shouldSend(messages)
    }

    /// Updates a tool call with the app's answer (an output, an error or an approval
    /// response) and returns its message's id.
    ///
    /// The answer lets the auto-send policy send the message, and the answered part is
    /// kept so a replay that rebuilds the message from the server's copy gets it back.
    /// An output, an error or a denial the app gave itself is never reported to
    /// ``ChatConfiguration/onToolOutput``. An approval isn't an output: the server, or
    /// the local tool it lets run, answers that call later.
    private func answerToolPart(callID: String, _ body: (inout ToolPart) -> Void) -> String? {
        var answered: ToolPart?
        let messageID = updateToolPart(callID: callID) { part in
            body(&part)
            answered = part
        }
        guard let answered else { return nil }
        answeredSinceLastRequest = true
        clientToolParts[callID] = answered
        switch answered.state {
        case .outputAvailable, .outputError, .outputDenied:
            reportedToolOutputs.insert(callID)
        default:
            break
        }
        return messageID
    }

    /// Puts the app's side of a tool call back on a replayed message that announced the
    /// call again: the approval it asked for or gave, or the output it added.
    private func restoreClientToolPart(callID: String) {
        guard let saved = clientToolParts[callID] else { return }
        updateToolPart(callID: callID) { part in
            part.state = saved.state
            part.approval = saved.approval
            part.output = saved.output
            part.errorText = saved.errorText
        }
    }

    /// Forgets the tool calls of earlier turns, which no replay can bring back.
    private func forgetToolCalls() {
        reportedToolOutputs = []
        handledToolCalls = []
        clientToolParts = [:]
    }

    private func sendAutomaticallyIfNeeded(continuing messageID: String?, options: ChatRequestOptions) async {
        guard !status.isBusy, activeTask == nil else { return }
        guard toolTasks.isEmpty, shouldSendAutomatically() else {
            save()
            return
        }
        await run(trigger: .submit, messageID: messageID ?? messages.last?.id, options: options, automatic: true)
    }

    // MARK: - Persistence

    private func save() {
        guard let store = configuration.store else { return }
        let snapshot = snapshot
        let previous = saveTask
        let onError = configuration.onError
        saveTask = Task { @MainActor in
            await previous?.value
            do {
                try await store.saveChat(snapshot)
            } catch {
                onError?(ChatError.from(error, operation: "chat.save"))
            }
        }
    }

    /// Waits until every pending save has finished.
    public func waitForPendingSaves() async {
        await saveTask?.value
    }
}
