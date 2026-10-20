import AIChat
import Foundation

/// A transport that talks to the Anthropic Messages API directly, streaming over SSE.
///
/// Client tools registered on the ``Chat`` are declared to Claude and run on device;
/// the chat sends their results back until Claude answers. Thinking streams as
/// reasoning parts and keeps its signature for the next turn, hosted tools such as
/// web search stream as provider-executed tool parts, citations become sources,
/// and `pause_turn` stops are continued automatically.
///
/// ```swift
/// let chat = Chat(transport: AnthropicChatTransport(apiKey: key))
/// await chat.sendMessage("Plan a three day trip to Lisbon")
/// ```
public struct AnthropicChatTransport: ChatTransport {
    public var configuration: AnthropicConfiguration

    public init(configuration: AnthropicConfiguration) {
        self.configuration = configuration
    }

    /// A transport that authenticates with an API key.
    public init(apiKey: String, model: String = "claude-opus-5-5", system: String? = nil) {
        var configuration = AnthropicConfiguration.apiKey(apiKey, defaultModel: model)
        configuration.system = system
        self.configuration = configuration
    }

    public func sendMessages(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream {
        let converted = try await AnthropicMessageConverter.convert(request.messages, configuration: configuration)
        guard !converted.messages.isEmpty else {
            throw ChatError(kind: .configuration, message: "There is no message to send to Claude.", operation: "anthropic.messages")
        }
        let initialBody = makeBody(model: request.modelID ?? configuration.defaultModel, converted: converted, request: request)
        let headers = configuration.requestHeaders(extra: request.headers)
        let first = try await post(initialBody, headers: headers)
        let configuration = configuration

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.start())
                    var body = initialBody
                    var response = first
                    var messages = converted.messages
                    var usage = AnthropicUsage()
                    var continuations = 0
                    while true {
                        var mapper = AnthropicStreamMapper(partPrefix: ChatID.generate())
                        var parser = ServerSentEventParser()
                        for try await data in response.body {
                            for event in parser.consume(data) {
                                for chunk in try mapper.map(event) { continuation.yield(chunk) }
                            }
                        }
                        if let event = parser.finish() {
                            for chunk in try mapper.map(event) { continuation.yield(chunk) }
                        }
                        try Task.checkCancellation()
                        guard mapper.finished else {
                            throw ChatError(kind: .network, message: "The connection closed before Claude finished.", operation: "anthropic.stream")
                        }
                        usage = usage + mapper.usage
                        if mapper.stopReason == "pause_turn", continuations < configuration.maxPauseContinuations {
                            continuations += 1
                            messages.append(["role": "assistant", "content": .array(mapper.contentBlocks)])
                            body["messages"] = .array(messages)
                            response = try await post(body, headers: headers)
                            continue
                        }
                        continuation.yield(.finish(
                            finishReason: Self.finishReason(mapper.stopReason),
                            messageMetadata: configuration.includesResponseMetadata ? Self.metadata(mapper: mapper, usage: usage) : nil
                        ))
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeBody(model: String, converted: AnthropicMessageConverter.Converted, request: ChatTransportRequest) -> [String: JSONValue] {
        var body = configuration.extraBody
        body["model"] = .string(model)
        body["max_tokens"] = .number(Double(configuration.maxTokens))
        body["stream"] = true
        if !converted.system.isEmpty { body["system"] = .array(converted.system) }
        body["messages"] = .array(converted.messages)
        let tools = request.tools.map(toolDefinition) + configuration.serverTools
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            if let toolChoice = configuration.toolChoice { body["tool_choice"] = toolChoice }
        }
        if let thinking = configuration.thinking { body["thinking"] = thinking.jsonValue }
        if let effort = configuration.effort {
            var outputConfig = body["output_config"]?.objectValue ?? [:]
            outputConfig["effort"] = .string(effort.rawValue)
            body["output_config"] = .object(outputConfig)
        }
        if configuration.promptCaching, body["cache_control"] == nil { body["cache_control"] = ["type": "ephemeral"] }
        for (key, value) in request.body { body[key] = value }
        return body
    }

    private func toolDefinition(_ tool: ChatToolDefinition) -> JSONValue {
        var definition: [String: JSONValue] = ["name": .string(tool.name), "input_schema": tool.inputSchema]
        if let description = tool.description { definition["description"] = .string(description) }
        if let strict = tool.strict { definition["strict"] = .bool(strict) }
        if configuration.eagerInputStreaming { definition["eager_input_streaming"] = true }
        return .object(definition)
    }

    private func post(_ body: [String: JSONValue], headers: [String: String]) async throws -> HTTPStreamResponse {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/messages"), timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONValue.object(body).jsonData()
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let response: HTTPStreamResponse
        do {
            response = try await configuration.httpClient.send(request)
        } catch {
            throw ChatError.from(error, operation: "anthropic.messages")
        }
        guard response.isSuccess else {
            throw await response.failure(operation: "anthropic.messages", parseError: Self.parseError)
        }
        return response
    }

    @Sendable static func parseError(_ data: Data) -> (message: String?, code: String?) {
        guard let value = try? JSONValue(parsing: data) else { return (nil, nil) }
        return (value["error"]?["message"]?.stringValue, value["error"]?["type"]?.stringValue)
    }

    static func finishReason(_ stopReason: String?) -> FinishReason {
        switch stopReason {
        case "end_turn", "stop_sequence": .stop
        case "max_tokens", "model_context_window_exceeded": .length
        case "tool_use": .toolCalls
        case "refusal": .contentFilter
        case nil, "pause_turn": .other
        case let reason?: .unknown(reason)
        }
    }

    static func metadata(mapper: AnthropicStreamMapper, usage: AnthropicUsage) -> JSONValue {
        var metadata: [String: JSONValue] = ["provider": "anthropic", "usage": usage.jsonValue]
        if let model = mapper.model { metadata["model"] = .string(model) }
        if let stopReason = mapper.stopReason { metadata["stopReason"] = .string(stopReason) }
        if let stopDetails = mapper.stopDetails { metadata["stopDetails"] = stopDetails }
        return .object(metadata)
    }
}
