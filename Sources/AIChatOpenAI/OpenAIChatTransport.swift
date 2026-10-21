import AIChat
import Foundation

/// A transport that talks to the OpenAI API directly, streaming over SSE.
///
/// It speaks the Responses API by default and Chat Completions when
/// ``OpenAIConfiguration/api`` is `.chatCompletions`, which also covers
/// OpenAI-compatible servers. Client tools registered on the ``Chat`` are declared as
/// functions and run on device. Reasoning summaries stream as reasoning parts, hosted
/// tools such as web search stream as provider-executed tool parts, and URL
/// citations become sources.
///
/// ```swift
/// let chat = Chat(transport: OpenAIChatTransport(apiKey: key))
/// await chat.sendMessage("Plan a three day trip to Lisbon")
/// ```
public struct OpenAIChatTransport: ChatTransport {
    public var configuration: OpenAIConfiguration

    public init(configuration: OpenAIConfiguration) {
        self.configuration = configuration
    }

    /// A transport that authenticates with an API key.
    public init(apiKey: String, model: String = "gpt-5.5", api: OpenAIConfiguration.API = .responses, system: String? = nil) {
        var configuration = OpenAIConfiguration.apiKey(apiKey, api: api, defaultModel: model)
        configuration.system = system
        self.configuration = configuration
    }

    public func sendMessages(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream {
        switch configuration.api {
        case .responses: try await sendResponses(request)
        case .chatCompletions: try await sendChatCompletions(request)
        }
    }

    // MARK: - Responses

    private func sendResponses(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream {
        let input = try await OpenAIResponsesConverter.convert(request.messages, configuration: configuration)
        guard !input.isEmpty else { throw Self.emptyConversation }
        let body = responsesBody(model: request.modelID ?? configuration.defaultModel, input: input, request: request)
        let response = try await post(body, path: "responses", headers: configuration.requestHeaders(extra: request.headers), operation: "openai.responses")
        let configuration = configuration

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.start())
                    var mapper = OpenAIResponsesStreamMapper()
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
                        throw ChatError(kind: .network, message: "The connection closed before OpenAI finished.", operation: "openai.responses.stream")
                    }
                    continuation.yield(.finish(
                        finishReason: mapper.finishReason,
                        messageMetadata: configuration.includesResponseMetadata
                            ? Self.metadata(model: mapper.model, responseID: mapper.responseID, usage: mapper.usage)
                            : nil
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func responsesBody(model: String, input: [JSONValue], request: ChatTransportRequest) -> [String: JSONValue] {
        var body = configuration.extraBody
        body["model"] = .string(model)
        body["stream"] = true
        body["input"] = .array(input)
        body["store"] = .bool(configuration.store)
        if let maxOutputTokens = configuration.maxOutputTokens { body["max_output_tokens"] = .number(Double(maxOutputTokens)) }
        let tools = request.tools.map(responsesTool) + configuration.builtInTools
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            if let toolChoice = configuration.toolChoice { body["tool_choice"] = toolChoice }
            if let parallelToolCalls = configuration.parallelToolCalls { body["parallel_tool_calls"] = .bool(parallelToolCalls) }
        }
        if let reasoning = configuration.reasoning {
            var object: [String: JSONValue] = [:]
            if let effort = reasoning.effort { object["effort"] = .string(effort.rawValue) }
            if let summary = reasoning.summary { object["summary"] = .string(summary.rawValue) }
            body["reasoning"] = .object(object)
        }
        if !configuration.store, configuration.includesEncryptedReasoning ?? (configuration.reasoning != nil) {
            var include = body["include"]?.arrayValue ?? []
            if !include.contains("reasoning.encrypted_content") { include.append("reasoning.encrypted_content") }
            body["include"] = .array(include)
        }
        if let verbosity = configuration.verbosity {
            var text = body["text"]?.objectValue ?? [:]
            text["verbosity"] = .string(verbosity)
            body["text"] = .object(text)
        }
        for (key, value) in request.body { body[key] = value }
        return body
    }

    private func responsesTool(_ tool: ChatToolDefinition) -> JSONValue {
        var definition: [String: JSONValue] = ["type": "function", "name": .string(tool.name), "parameters": tool.inputSchema]
        if let description = tool.description { definition["description"] = .string(description) }
        definition["strict"] = .bool(tool.strict ?? false)
        return .object(definition)
    }

    // MARK: - Chat Completions

    private func sendChatCompletions(_ request: ChatTransportRequest) async throws -> UIMessageChunkStream {
        let messages = try await OpenAIChatCompletionsConverter.convert(request.messages, configuration: configuration)
        guard !messages.isEmpty else { throw Self.emptyConversation }
        let body = chatCompletionsBody(model: request.modelID ?? configuration.defaultModel, messages: messages, request: request)
        let response = try await post(body, path: "chat/completions", headers: configuration.requestHeaders(extra: request.headers), operation: "openai.chat")
        let configuration = configuration

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.start())
                    var mapper = OpenAIChatCompletionsStreamMapper(partPrefix: ChatID.generate())
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
                    guard mapper.finished || mapper.hasFinishReason else {
                        throw ChatError(kind: .network, message: "The connection closed before the model finished.", operation: "openai.chat.stream")
                    }
                    for chunk in mapper.close() { continuation.yield(chunk) }
                    continuation.yield(.finish(
                        finishReason: mapper.finishReason,
                        messageMetadata: configuration.includesResponseMetadata
                            ? Self.metadata(model: mapper.model, responseID: mapper.responseID, usage: mapper.usage)
                            : nil
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func chatCompletionsBody(model: String, messages: [JSONValue], request: ChatTransportRequest) -> [String: JSONValue] {
        var body = configuration.extraBody
        body["model"] = .string(model)
        body["stream"] = true
        if configuration.includesStreamUsage { body["stream_options"] = ["include_usage": true] }
        body["messages"] = .array(messages)
        if let maxOutputTokens = configuration.maxOutputTokens {
            body[configuration.usesLegacyMaxTokens ? "max_tokens" : "max_completion_tokens"] = .number(Double(maxOutputTokens))
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map(chatCompletionsTool))
            if let toolChoice = configuration.toolChoice { body["tool_choice"] = toolChoice }
            if let parallelToolCalls = configuration.parallelToolCalls { body["parallel_tool_calls"] = .bool(parallelToolCalls) }
        }
        if let effort = configuration.reasoning?.effort { body["reasoning_effort"] = .string(effort.rawValue) }
        if let verbosity = configuration.verbosity { body["verbosity"] = .string(verbosity) }
        for (key, value) in request.body { body[key] = value }
        return body
    }

    private func chatCompletionsTool(_ tool: ChatToolDefinition) -> JSONValue {
        var function: [String: JSONValue] = ["name": .string(tool.name), "parameters": tool.inputSchema]
        if let description = tool.description { function["description"] = .string(description) }
        if let strict = tool.strict { function["strict"] = .bool(strict) }
        return ["type": "function", "function": .object(function)]
    }

    // MARK: - Shared

    private static let emptyConversation = ChatError(kind: .configuration, message: "There is no message to send to the model.", operation: "openai.request")

    private func post(_ body: [String: JSONValue], path: String, headers: [String: String], operation: String) async throws -> HTTPStreamResponse {
        var request = URLRequest(url: configuration.endpoint(path), timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONValue.object(body).jsonData()
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let response: HTTPStreamResponse
        do {
            response = try await configuration.httpClient.send(request)
        } catch {
            throw ChatError.from(error, operation: operation)
        }
        guard response.isSuccess else {
            throw await response.failure(operation: operation, parseError: Self.parseError)
        }
        return response
    }

    @Sendable static func parseError(_ data: Data) -> (message: String?, code: String?) {
        guard let value = try? JSONValue(parsing: data) else { return (nil, nil) }
        let error = value["error"]
        return (error?["message"]?.stringValue, error?["code"]?.stringValue ?? error?["type"]?.stringValue)
    }

    static func metadata(model: String?, responseID: String?, usage: OpenAIUsage) -> JSONValue {
        var metadata: [String: JSONValue] = ["provider": "openai", "usage": usage.jsonValue]
        if let model { metadata["model"] = .string(model) }
        if let responseID { metadata["responseId"] = .string(responseID) }
        return .object(metadata)
    }
}
