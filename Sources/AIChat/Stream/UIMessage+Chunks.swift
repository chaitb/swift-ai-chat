import Foundation

extension UIMessage {
    /// The chunks that rebuild this message when applied to an empty assistant message.
    ///
    /// Useful to resume a response from a saved copy (a transport can poll its server
    /// and replay the finished message), to write fixtures, or to serve a stored
    /// message to an AI SDK client.
    ///
    /// Finished tool calls replay without `tool-input-available`, so they don't
    /// trigger ``ChatConfiguration/onToolCall`` again. Calls still waiting for the
    /// client do.
    public func replayChunks(finishReason: FinishReason? = nil) -> [UIMessageChunk] {
        var chunks: [UIMessageChunk] = [.start(messageId: id, messageMetadata: metadata)]
        var stepOpen = false
        for (index, part) in parts.enumerated() {
            switch part {
            case .stepStart:
                if stepOpen { chunks.append(.finishStep) }
                chunks.append(.startStep)
                stepOpen = true
            case .text(let text):
                let id = "text-\(index)"
                chunks.append(.textStart(id: id, providerMetadata: text.providerMetadata))
                if !text.text.isEmpty { chunks.append(.textDelta(id: id, delta: text.text)) }
                if text.state != .streaming { chunks.append(.textEnd(id: id, providerMetadata: text.providerMetadata, citations: text.citations)) }
            case .reasoning(let reasoning):
                let id = reasoning.id ?? "reasoning-\(index)"
                chunks.append(.reasoningStart(id: id, providerMetadata: reasoning.providerMetadata))
                if !reasoning.text.isEmpty { chunks.append(.reasoningDelta(id: id, delta: reasoning.text)) }
                if reasoning.state != .streaming { chunks.append(.reasoningEnd(id: id, providerMetadata: reasoning.providerMetadata)) }
            case .tool(let tool):
                chunks.append(contentsOf: Self.replayChunks(for: tool))
            case .file(let file):
                chunks.append(.file(url: file.url, mediaType: file.mediaType, providerMetadata: file.providerMetadata))
            case .reasoningFile(let file):
                chunks.append(.reasoningFile(url: file.url, mediaType: file.mediaType, providerMetadata: file.providerMetadata))
            case .sourceURL(let source):
                chunks.append(.sourceURL(source))
            case .sourceDocument(let source):
                chunks.append(.sourceDocument(source))
            case .data(let data):
                chunks.append(.data(DataChunk(name: data.name, data: data.data, id: data.id)))
            case .custom(let custom):
                chunks.append(.custom(kind: custom.kind, providerMetadata: custom.providerMetadata))
            case .unknown:
                break
            }
        }
        if stepOpen { chunks.append(.finishStep) }
        chunks.append(.finish(finishReason: finishReason))
        return chunks
    }

    private static func replayChunks(for tool: ToolPart) -> [UIMessageChunk] {
        let dynamic: Bool? = tool.isDynamic ? true : nil
        let start = UIMessageChunk.toolInputStart(ToolInputStartChunk(
            toolCallId: tool.toolCallId,
            toolName: tool.toolName,
            inputEncoding: tool.inputEncoding,
            providerExecuted: tool.providerExecuted,
            providerMetadata: tool.callProviderMetadata,
            toolMetadata: tool.toolMetadata,
            dynamic: dynamic,
            title: tool.title
        ))
        let inputText = tool.inputEncoding == "text" ? tool.input?.stringValue : tool.input?.jsonString
        let streamedInput = inputText.map { UIMessageChunk.toolInputDelta(toolCallId: tool.toolCallId, inputTextDelta: $0) }
        let available = UIMessageChunk.toolInputAvailable(ToolInputAvailableChunk(
            toolCallId: tool.toolCallId,
            toolName: tool.toolName,
            input: tool.input,
            providerExecuted: tool.providerExecuted,
            providerMetadata: tool.callProviderMetadata,
            toolMetadata: tool.toolMetadata,
            dynamic: dynamic,
            title: tool.title
        ))
        let approvalRequest = tool.approval.map {
            UIMessageChunk.toolApprovalRequest(ToolApprovalRequestChunk(
                approvalId: $0.id,
                toolCallId: tool.toolCallId,
                signature: $0.signature,
                approvalDescriptor: $0.descriptor,
                inputSchemaInput: $0.inputSchemaInput,
                reason: $0.requestReason,
                isAutomatic: $0.isAutomatic
            ))
        }
        switch tool.state {
        case .inputStreaming:
            return [start] + (streamedInput.map { [$0] } ?? [])
        case .inputAvailable:
            return [available]
        case .approvalRequested:
            return [start] + (streamedInput.map { [$0] } ?? []) + (approvalRequest.map { [$0] } ?? [])
        case .approvalResponded:
            var chunks = [start] + (streamedInput.map { [$0] } ?? []) + (approvalRequest.map { [$0] } ?? [])
            if let approval = tool.approval, let approved = approval.approved {
                chunks.append(.toolApprovalResponse(ToolApprovalResponseChunk(approvalId: approval.id, approved: approved, reason: approval.reason)))
            }
            return chunks
        case .outputAvailable:
            return [start] + (streamedInput.map { [$0] } ?? []) + (approvalRequest.map { [$0] } ?? []) + [
                .toolOutputAvailable(ToolOutputAvailableChunk(
                    toolCallId: tool.toolCallId,
                    output: tool.output,
                    providerExecuted: tool.providerExecuted,
                    providerMetadata: tool.resultProviderMetadata,
                    dynamic: dynamic,
                    preliminary: tool.preliminary
                )),
            ]
        case .outputError:
            if tool.input == nil, let rawInput = tool.rawInput {
                return [.toolInputError(ToolInputErrorChunk(
                    toolCallId: tool.toolCallId,
                    toolName: tool.toolName,
                    input: rawInput,
                    errorText: tool.errorText ?? "",
                    providerExecuted: tool.providerExecuted,
                    providerMetadata: tool.resultProviderMetadata,
                    toolMetadata: tool.toolMetadata,
                    dynamic: dynamic,
                    title: tool.title
                ))]
            }
            return [start] + (streamedInput.map { [$0] } ?? []) + [
                .toolOutputError(ToolOutputErrorChunk(
                    toolCallId: tool.toolCallId,
                    errorText: tool.errorText ?? "",
                    providerExecuted: tool.providerExecuted,
                    providerMetadata: tool.resultProviderMetadata,
                    dynamic: dynamic
                )),
            ]
        case .outputDenied:
            return [start] + (streamedInput.map { [$0] } ?? []) + (approvalRequest.map { [$0] } ?? []) + [
                .toolOutputDenied(toolCallId: tool.toolCallId),
            ]
        case .other:
            return [start] + (streamedInput.map { [$0] } ?? [])
        }
    }
}
