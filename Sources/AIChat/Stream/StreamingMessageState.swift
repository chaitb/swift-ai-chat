import Foundation

/// A tool call the model made that the client has to answer.
public struct ToolCall: Hashable, Sendable {
    public var toolCallId: String
    public var toolName: String
    public var input: JSONValue
    /// Whether the call is for a dynamic tool, whose types aren't known ahead of time.
    public var dynamic: Bool
    public var providerMetadata: JSONValue?

    public init(toolCallId: String, toolName: String, input: JSONValue, dynamic: Bool = false, providerMetadata: JSONValue? = nil) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.input = input
        self.dynamic = dynamic
        self.providerMetadata = providerMetadata
    }

    /// Decodes the input into your own type.
    public func decodeInput<T: Decodable>(_ type: T.Type = T.self, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try input.decode(T.self, using: decoder)
    }
}

/// Applies UI message stream chunks to an assistant message.
///
/// This mirrors `processUIMessageStream` from the AI SDK (the v7 semantics, which
/// also handle v6 streams): text and reasoning parts are matched by id, tool parts
/// by call id within the current step, partial tool input is parsed as it streams,
/// data parts with an id are replaced in place and metadata is deep-merged.
///
/// In lenient mode (the default) a delta without its start chunk opens the part, and
/// chunks that refer to an unknown part are ignored. In strict mode both throw a
/// ``ChatError/Kind/protocolViolation`` error, like the AI SDK.
public struct StreamingMessageState: Sendable {
    /// What applying one chunk changed.
    public struct Update: Sendable {
        /// Whether ``StreamingMessageState/message`` changed and should be shown.
        public var messageChanged = false
        /// Whether showing the change should move the chat to `streaming`. `start` chunks don't.
        public var updatesStatus = true
        /// A tool call the client should run, from `tool-input-available` without `providerExecuted`.
        public var toolCall: ToolCall?
        /// A data chunk for ``ChatConfiguration/onData``.
        public var data: DataChunk?
        /// The text of an `error` chunk.
        public var streamError: String?

        public init() {}
    }

    /// How a replayed or resumed stream resets the state.
    public struct ResumeBehavior: Sendable, Hashable {
        /// Starts over at the first `start` chunk, for transports that replay the whole response.
        public var resetsOnFirstStart: Bool
        /// Starts over when a `start` chunk names a different message.
        public var resetsOnMessageIDChange: Bool

        public init(resetsOnFirstStart: Bool = false, resetsOnMessageIDChange: Bool = false) {
            self.resetsOnFirstStart = resetsOnFirstStart
            self.resetsOnMessageIDChange = resetsOnMessageIDChange
        }
    }

    private struct PartialToolCall: Sendable {
        var text: String
        var toolName: String
        var dynamic: Bool
        var inputEncoding: String?
        var title: String?
        var toolMetadata: JSONValue?
    }

    public var message: UIMessage
    public private(set) var finishReason: FinishReason?
    public var strict: Bool
    public var resumeBehavior: ResumeBehavior
    private var activeTextParts: [String: Int] = [:]
    private var activeReasoningParts: [String: Int] = [:]
    private var partialToolCalls: [String: PartialToolCall] = [:]
    private var sawStart = false

    /// Starts from an existing assistant message, for continuations after tool results.
    /// Tool calls of its last step that were still streaming their input keep streaming.
    public init(continuing message: UIMessage, strict: Bool = false, resumeBehavior: ResumeBehavior = ResumeBehavior()) {
        self.message = message
        self.strict = strict
        self.resumeBehavior = resumeBehavior
        for part in message.lastStepParts {
            guard let tool = part.toolPart, tool.state == .inputStreaming else { continue }
            partialToolCalls[tool.toolCallId] = PartialToolCall(
                text: tool.rawInput?.stringValue ?? "",
                toolName: tool.toolName,
                dynamic: tool.isDynamic,
                inputEncoding: tool.inputEncoding,
                title: tool.title,
                toolMetadata: tool.toolMetadata
            )
        }
    }

    /// Starts a new, empty assistant message.
    public init(messageID: String, strict: Bool = false, resumeBehavior: ResumeBehavior = ResumeBehavior()) {
        message = UIMessage(id: messageID, role: .assistant, parts: [])
        self.strict = strict
        self.resumeBehavior = resumeBehavior
    }

    /// Applies one chunk.
    public mutating func apply(_ chunk: UIMessageChunk) throws(ChatError) -> Update {
        var update = Update()
        switch chunk {
        case .textStart(let id, let providerMetadata):
            startText(id: id, providerMetadata: providerMetadata)
            update.messageChanged = true

        case .textDelta(let id, let delta, let providerMetadata):
            guard let index = try textIndex(for: id, chunkType: "text-delta") else { break }
            mutateText(at: index) { part in
                part.text += delta
                if let providerMetadata { part.providerMetadata = providerMetadata }
            }
            update.messageChanged = true

        case .textEnd(let id, let providerMetadata, let citations):
            guard let index = activeTextParts[id] else {
                try violation("Received text-end for missing text part with ID \"\(id)\". Ensure a \"text-start\" chunk is sent before any \"text-end\" chunks.")
                break
            }
            mutateText(at: index) { part in
                part.state = .done
                if let providerMetadata { part.providerMetadata = providerMetadata }
                if let citations { part.citations = citations }
            }
            activeTextParts[id] = nil
            update.messageChanged = true

        case .reasoningStart(let id, let providerMetadata):
            startReasoning(id: id, providerMetadata: providerMetadata)
            update.messageChanged = true

        case .reasoningDelta(let id, let delta, let providerMetadata):
            guard let index = try reasoningIndex(for: id, chunkType: "reasoning-delta") else { break }
            mutateReasoning(at: index) { part in
                part.text += delta
                if let providerMetadata { part.providerMetadata = providerMetadata }
            }
            update.messageChanged = true

        case .reasoningEnd(let id, let providerMetadata):
            guard let index = activeReasoningParts[id] else {
                try violation("Received reasoning-end for missing reasoning part with ID \"\(id)\". Ensure a \"reasoning-start\" chunk is sent before any \"reasoning-end\" chunks.")
                break
            }
            mutateReasoning(at: index) { part in
                if let providerMetadata { part.providerMetadata = providerMetadata }
                part.state = .done
            }
            activeReasoningParts[id] = nil
            update.messageChanged = true

        case .custom(let kind, let providerMetadata):
            message.parts.append(.custom(CustomPart(kind: kind, providerMetadata: providerMetadata)))
            update.messageChanged = true

        case .file(let url, let mediaType, let providerMetadata):
            message.parts.append(.file(FilePart(mediaType: mediaType, url: url, providerMetadata: providerMetadata)))
            update.messageChanged = true

        case .reasoningFile(let url, let mediaType, let providerMetadata):
            message.parts.append(.reasoningFile(FilePart(mediaType: mediaType, url: url, providerMetadata: providerMetadata)))
            update.messageChanged = true

        case .sourceURL(let source):
            message.parts.append(.sourceURL(source))
            update.messageChanged = true

        case .sourceDocument(let source):
            message.parts.append(.sourceDocument(source))
            update.messageChanged = true

        case .toolInputStart(let chunk):
            partialToolCalls[chunk.toolCallId] = PartialToolCall(
                text: "",
                toolName: chunk.toolName,
                dynamic: chunk.dynamic == true,
                inputEncoding: chunk.inputEncoding,
                title: chunk.title,
                toolMetadata: chunk.toolMetadata
            )
            updateTool(ToolUpdate(
                toolName: chunk.toolName,
                toolCallId: chunk.toolCallId,
                dynamic: chunk.dynamic == true,
                state: .inputStreaming,
                inputEncoding: chunk.inputEncoding,
                providerExecuted: chunk.providerExecuted,
                providerMetadata: chunk.providerMetadata,
                title: chunk.title,
                toolMetadata: chunk.toolMetadata
            ))
            update.messageChanged = true

        case .toolInputDelta(let toolCallId, let inputTextDelta):
            guard var partial = partialToolCalls[toolCallId] else {
                try violation("Received tool-input-delta for missing tool call with ID \"\(toolCallId)\". Ensure a \"tool-input-start\" chunk is sent before any \"tool-input-delta\" chunks.")
                break
            }
            partial.text += inputTextDelta
            partialToolCalls[toolCallId] = partial
            updateTool(ToolUpdate(
                toolName: partial.toolName,
                toolCallId: toolCallId,
                dynamic: partial.dynamic,
                state: .inputStreaming,
                input: partial.inputEncoding == "text" ? .string(partial.text) : PartialJSON.parse(partial.text).value,
                rawInput: .string(partial.text),
                inputEncoding: partial.inputEncoding,
                title: partial.title,
                toolMetadata: partial.toolMetadata
            ))
            update.messageChanged = true

        case .toolInputAvailable(let chunk):
            partialToolCalls[chunk.toolCallId] = nil
            updateTool(ToolUpdate(
                toolName: chunk.toolName,
                toolCallId: chunk.toolCallId,
                dynamic: chunk.dynamic == true,
                state: .inputAvailable,
                input: chunk.input,
                providerExecuted: chunk.providerExecuted,
                providerMetadata: chunk.providerMetadata,
                title: chunk.title,
                toolMetadata: chunk.toolMetadata
            ))
            update.messageChanged = true
            if chunk.providerExecuted != true {
                update.toolCall = ToolCall(
                    toolCallId: chunk.toolCallId,
                    toolName: chunk.toolName,
                    input: chunk.input ?? .null,
                    dynamic: chunk.dynamic == true,
                    providerMetadata: chunk.providerMetadata
                )
            }

        case .toolInputError(let chunk):
            partialToolCalls[chunk.toolCallId] = nil
            let existing = currentStepToolIndex(callID: chunk.toolCallId)
            let isDynamic = existing.flatMap { message.parts[$0].toolPart?.isDynamic } ?? (chunk.dynamic == true)
            updateTool(ToolUpdate(
                toolName: chunk.toolName,
                toolCallId: chunk.toolCallId,
                dynamic: isDynamic,
                state: .outputError,
                input: chunk.input,
                errorText: chunk.errorText,
                providerExecuted: chunk.providerExecuted,
                providerMetadata: chunk.providerMetadata,
                toolMetadata: chunk.toolMetadata
            ), existingIndex: existing)
            update.messageChanged = true

        case .toolApprovalRequest(let chunk):
            guard let index = try toolInvocationIndex(callID: chunk.toolCallId) else { break }
            mutateTool(at: index) { part in
                part.state = .approvalRequested
                part.approval = ToolApproval(
                    id: chunk.approvalId,
                    signature: chunk.signature,
                    descriptor: chunk.approvalDescriptor,
                    requestReason: chunk.reason,
                    isAutomatic: chunk.isAutomatic == true ? true : nil,
                    inputSchemaInput: chunk.inputSchemaInput
                )
            }
            update.messageChanged = true

        case .toolApprovalResponse(let chunk):
            guard let index = message.parts.firstIndex(where: { $0.toolPart?.approval?.id == chunk.approvalId }) else {
                try violation("No tool invocation found for approval ID \"\(chunk.approvalId)\".")
                break
            }
            mutateTool(at: index) { part in
                var approval = part.approval ?? ToolApproval(id: chunk.approvalId)
                approval.id = chunk.approvalId
                approval.approved = chunk.approved
                if let reason = chunk.reason { approval.reason = reason }
                part.state = .approvalResponded
                part.approval = approval
                if let providerExecuted = chunk.providerExecuted { part.providerExecuted = providerExecuted }
                if let providerMetadata = chunk.providerMetadata { part.callProviderMetadata = providerMetadata }
            }
            update.messageChanged = true

        case .toolOutputDenied(let toolCallId):
            guard let index = try toolInvocationIndex(callID: toolCallId) else { break }
            mutateTool(at: index) { $0.state = .outputDenied }
            update.messageChanged = true

        case .toolOutputAvailable(let chunk):
            guard let index = try toolInvocationIndex(callID: chunk.toolCallId),
                  let invocation = message.parts[index].toolPart
            else { break }
            updateTool(ToolUpdate(
                toolName: invocation.toolName,
                toolCallId: chunk.toolCallId,
                dynamic: invocation.isDynamic,
                state: .outputAvailable,
                input: invocation.input,
                output: chunk.output,
                providerExecuted: chunk.providerExecuted,
                preliminary: chunk.preliminary,
                providerMetadata: chunk.providerMetadata,
                title: invocation.title,
                toolMetadata: chunk.toolMetadata ?? invocation.toolMetadata
            ), existingIndex: index)
            update.messageChanged = true

        case .toolOutputError(let chunk):
            guard let index = try toolInvocationIndex(callID: chunk.toolCallId),
                  let invocation = message.parts[index].toolPart
            else { break }
            updateTool(ToolUpdate(
                toolName: invocation.toolName,
                toolCallId: chunk.toolCallId,
                dynamic: invocation.isDynamic,
                state: .outputError,
                input: invocation.input,
                errorText: chunk.errorText,
                rawInput: invocation.isDynamic ? nil : invocation.rawInput,
                providerExecuted: chunk.providerExecuted,
                providerMetadata: chunk.providerMetadata,
                title: invocation.title,
                toolMetadata: chunk.toolMetadata ?? invocation.toolMetadata
            ), existingIndex: index)
            update.messageChanged = true

        case .startStep:
            message.parts.append(.stepStart)

        case .finishStep:
            break

        case .resetStep:
            let start = currentStepStartIndex
            activeTextParts = [:]
            activeReasoningParts = [:]
            partialToolCalls = [:]
            if start < message.parts.endIndex {
                message.parts.removeSubrange(start...)
                update.messageChanged = true
            }

        case .start(let messageId, let messageMetadata):
            let resets = (resumeBehavior.resetsOnFirstStart && !sawStart)
                || (resumeBehavior.resetsOnMessageIDChange && messageId != nil && messageId != message.id)
            sawStart = true
            if resets {
                message = UIMessage(id: messageId ?? message.id, role: .assistant, parts: [])
                activeTextParts = [:]
                activeReasoningParts = [:]
                partialToolCalls = [:]
                finishReason = nil
            }
            if let messageId { message.id = messageId }
            let mergedMetadata = mergeMetadata(messageMetadata)
            if resets || messageId != nil || mergedMetadata {
                update.messageChanged = true
                update.updatesStatus = false
            }

        case .finish(let finishReason, let messageMetadata):
            if let finishReason { self.finishReason = finishReason }
            if mergeMetadata(messageMetadata) { update.messageChanged = true }

        case .messageMetadata(let metadata):
            if mergeMetadata(metadata) { update.messageChanged = true }

        case .error(let errorText):
            update.streamError = errorText

        case .abort:
            break

        case .data(let chunk):
            update.data = chunk
            if chunk.transient == true { break }
            let type = "data-\(chunk.name)"
            if let id = chunk.id, let index = message.parts.firstIndex(where: { $0.type == type && $0.dataPart?.id == id }) {
                if case .data(var part) = message.parts[index] {
                    part.data = chunk.data
                    message.parts[index] = .data(part)
                }
            } else {
                message.parts.append(.data(DataPart(name: chunk.name, data: chunk.data, id: chunk.id)))
            }
            update.messageChanged = true

        case .unknown:
            break
        }
        return update
    }

    // MARK: - Text and reasoning

    private mutating func startText(id: String, providerMetadata: JSONValue?) {
        message.parts.append(.text(TextPart(text: "", state: .streaming, providerMetadata: providerMetadata)))
        activeTextParts[id] = message.parts.count - 1
    }

    private mutating func startReasoning(id: String, providerMetadata: JSONValue?) {
        message.parts.append(.reasoning(ReasoningPart(text: "", state: .streaming, providerMetadata: providerMetadata, id: id)))
        activeReasoningParts[id] = message.parts.count - 1
    }

    private mutating func textIndex(for id: String, chunkType: String) throws(ChatError) -> Int? {
        if let index = activeTextParts[id] { return index }
        try violation("Received \(chunkType) for missing text part with ID \"\(id)\". Ensure a \"text-start\" chunk is sent before any \"\(chunkType)\" chunks.")
        startText(id: id, providerMetadata: nil)
        return activeTextParts[id]
    }

    private mutating func reasoningIndex(for id: String, chunkType: String) throws(ChatError) -> Int? {
        if let index = activeReasoningParts[id] { return index }
        try violation("Received \(chunkType) for missing reasoning part with ID \"\(id)\". Ensure a \"reasoning-start\" chunk is sent before any \"\(chunkType)\" chunks.")
        startReasoning(id: id, providerMetadata: nil)
        return activeReasoningParts[id]
    }

    private mutating func mutateText(at index: Int, _ body: (inout TextPart) -> Void) {
        guard message.parts.indices.contains(index), case .text(var part) = message.parts[index] else { return }
        body(&part)
        message.parts[index] = .text(part)
    }

    private mutating func mutateReasoning(at index: Int, _ body: (inout ReasoningPart) -> Void) {
        guard message.parts.indices.contains(index), case .reasoning(var part) = message.parts[index] else { return }
        body(&part)
        message.parts[index] = .reasoning(part)
    }

    // MARK: - Tools

    private struct ToolUpdate {
        var toolName: String
        var toolCallId: String
        var dynamic: Bool
        var state: ToolPart.State
        var input: JSONValue?
        var output: JSONValue?
        var errorText: String?
        var rawInput: JSONValue?
        var inputEncoding: String?
        var providerExecuted: Bool?
        var preliminary: Bool?
        var providerMetadata: JSONValue?
        var title: String?
        var toolMetadata: JSONValue?
    }

    private var currentStepStartIndex: Int {
        message.parts.lastIndex(where: \.isStepStart).map { $0 + 1 } ?? 0
    }

    private func currentStepToolIndex(callID: String, dynamic: Bool? = nil) -> Int? {
        let start = currentStepStartIndex
        guard start < message.parts.endIndex else { return nil }
        return message.parts[start...].firstIndex { part in
            guard let tool = part.toolPart, tool.toolCallId == callID else { return false }
            return dynamic.map { tool.isDynamic == $0 } ?? true
        }
    }

    private func toolInvocationIndex(callID: String) throws(ChatError) -> Int? {
        if let index = currentStepToolIndex(callID: callID) ?? message.parts.lastIndex(where: { $0.toolPart?.toolCallId == callID }) {
            return index
        }
        try violation("No tool invocation found for tool call ID \"\(callID)\".")
        return nil
    }

    private mutating func mutateTool(at index: Int, _ body: (inout ToolPart) -> Void) {
        guard message.parts.indices.contains(index), case .tool(var part) = message.parts[index] else { return }
        body(&part)
        message.parts[index] = .tool(part)
    }

    private mutating func updateTool(_ update: ToolUpdate, existingIndex: Int? = nil) {
        let isResult = update.state == .outputAvailable || update.state == .outputError
        let index = existingIndex ?? currentStepToolIndex(callID: update.toolCallId, dynamic: update.dynamic)
        if let index, case .tool(var part) = message.parts[index] {
            part.state = update.state
            part.toolName = update.toolName
            part.rawInput = update.rawInput
            part.inputEncoding = update.inputEncoding
            part.input = update.input
            part.output = update.output
            part.errorText = update.errorText
            part.preliminary = update.preliminary
            if let title = update.title { part.title = title }
            if let toolMetadata = update.toolMetadata { part.toolMetadata = toolMetadata }
            part.providerExecuted = update.providerExecuted ?? part.providerExecuted
            if let providerMetadata = update.providerMetadata {
                if isResult {
                    part.resultProviderMetadata = providerMetadata
                } else {
                    part.callProviderMetadata = providerMetadata
                }
            }
            message.parts[index] = .tool(part)
        } else {
            message.parts.append(.tool(ToolPart(
                toolName: update.toolName,
                toolCallId: update.toolCallId,
                isDynamic: update.dynamic,
                state: update.state,
                input: update.input,
                output: update.output,
                errorText: update.errorText,
                rawInput: update.rawInput,
                inputEncoding: update.inputEncoding,
                providerExecuted: update.providerExecuted,
                preliminary: update.preliminary,
                title: update.title,
                toolMetadata: update.toolMetadata,
                callProviderMetadata: isResult ? nil : update.providerMetadata,
                resultProviderMetadata: isResult ? update.providerMetadata : nil
            )))
        }
    }

    // MARK: - Metadata

    @discardableResult
    private mutating func mergeMetadata(_ metadata: JSONValue?) -> Bool {
        guard let metadata, metadata != .null else { return false }
        let merged = message.metadata.map { $0.merging(metadata) } ?? metadata
        guard merged != message.metadata else { return false }
        message.metadata = merged
        return true
    }

    private func violation(_ message: String) throws(ChatError) {
        guard strict else { return }
        throw ChatError(kind: .protocolViolation, message: message)
    }
}
