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
    @ObservationIgnored private var resumableState: StreamingMessageState?
    @ObservationIgnored private var lastWrittenMessageID: String?
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
        messages.append(message)
        save()
        await run(trigger: .submit, messageID: nil, options: options, automatic: false)
    }

    /// Sends the conversation as it is, without a new message: to continue after editing
    /// ``messages`` yourself, or to start a flow on a backend that opens the conversation.
    public func submit(options: ChatRequestOptions = ChatRequestOptions()) async {
        await cancelActiveRequest()
        await run(trigger: .submit, messageID: messages.last?.id, options: options, automatic: false)
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

    /// Stops the running response and any client tools it started. Streamed parts are kept.
    public func stop() {
        activeTask?.cancel()
        for task in toolTasks.values { task.cancel() }
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
        status = .ready
        save()
    }

    // MARK: - Tools

    /// Adds the output of a client-side tool call. When that completes the step, the
    /// conversation is sent again according to ``ChatConfiguration/sendAutomaticallyWhen``.
    public func addToolOutput(toolCallId: String, output: JSONValue, options: ChatRequestOptions = ChatRequestOptions()) async {
        toolTasks[toolCallId] = nil
        let messageID = updateToolPart(callID: toolCallId) { part in
            part.state = .outputAvailable
            part.output = output
            part.errorText = nil
        }
        await sendAutomaticallyIfNeeded(continuing: messageID, options: options)
    }

    /// Records that a client-side tool call failed.
    public func addToolOutput(toolCallId: String, errorText: String, options: ChatRequestOptions = ChatRequestOptions()) async {
        toolTasks[toolCallId] = nil
        let messageID = updateToolPart(callID: toolCallId) { part in
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
        let messageID = updateToolPart(callID: part.toolCallId) { part in
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
                guard let stream = try await transport.reconnectToStream(reconnectRequest(merged)) else {
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
        activeState = makeState(trigger: trigger, messageID: messageID)
        if trigger != .resume { resumableState = nil }

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

        if let disconnect = failure, disconnect.isDisconnect, !Task.isCancelled, configuration.resumePolicy.attempts > 0 {
            failure = await recover(from: disconnect, options: merged)
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
                return state
            }
            if let last = messages.last, last.role == .assistant, last.toolParts.contains(where: { Self.awaitsServer($0) }) {
                return StreamingMessageState(continuing: last, strict: strict, resumeBehavior: behavior)
            }
            return StreamingMessageState(messageID: configuration.generateID(), strict: strict, resumeBehavior: behavior)
        case .regenerate:
            return StreamingMessageState(messageID: configuration.generateID(), strict: strict)
        case .submit:
            let response = messageID.flatMap { id in messages.last { $0.id == id } } ?? messages.last
            if let response, response.role == .assistant {
                lastWrittenMessageID = response.id
                return StreamingMessageState(continuing: response, strict: strict)
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

    private func recover(from disconnect: ChatError, options: ChatRequestOptions) async -> ChatError? {
        var lastFailure = disconnect
        var delay = configuration.resumePolicy.initialDelay
        for _ in 0..<configuration.resumePolicy.attempts {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return .cancelled
            }
            delay *= 2
            do {
                guard let resumed = try await transport.reconnectToStream(reconnectRequest(options)) else { return lastFailure }
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
            }
        }
        return lastFailure
    }

    private func consume(_ stream: UIMessageChunkStream) async throws {
        for try await chunk in stream {
            if Task.isCancelled { break }
            guard var state = activeState else { break }
            let update = try state.apply(chunk)
            activeState = state
            if update.messageChanged {
                publish(updatesStatus: update.updatesStatus)
            }
            if let data = update.data {
                configuration.onData?(data)
            }
            if let streamError = update.streamError {
                throw ChatError(kind: .stream, message: streamError, operation: "chat.stream")
            }
            if let toolCall = update.toolCall {
                flushPublish()
                await handleToolCall(toolCall)
            }
        }
        try Task.checkCancellation()
    }

    private func reconnectRequest(_ options: ChatRequestOptions) -> ChatReconnectRequest {
        ChatReconnectRequest(chatID: id, messages: messages, headers: options.headers, body: options.body, metadata: options.metadata)
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
                updateToolPart(callID: call.toolCallId) { part in
                    part.state = .approvalRequested
                    part.approval = ToolApproval(id: approvalID)
                }
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
        configuration.effectiveAutoSendPolicy.shouldSend(messages)
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
