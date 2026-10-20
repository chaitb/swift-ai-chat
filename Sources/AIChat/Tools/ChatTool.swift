import Foundation

/// The declaration of a tool: what model providers see.
public struct ChatToolDefinition: Hashable, Sendable {
    public var name: String
    public var description: String?
    /// A JSON Schema object describing the input.
    public var inputSchema: JSONValue
    /// Asks the provider to guarantee schema-valid input, where supported.
    public var strict: Bool?

    public init(name: String, description: String? = nil, inputSchema: JSONValue = ["type": "object", "properties": [:]], strict: Bool? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
    }
}

/// A tool that runs on the client.
///
/// With the Anthropic and OpenAI transports, registered tools are declared to the
/// model and run on device, and ``Chat`` keeps the conversation going until the
/// model answers. With an AI SDK backend, register tools the server declares
/// without `execute`, so their calls arrive at the client.
///
/// A tool without `execute` is a human-in-the-loop tool: the app answers it with
/// ``Chat/addToolOutput(toolCallId:output:)``, for example after asking the user.
public struct ChatTool: Sendable {
    public var definition: ChatToolDefinition
    /// Whether the user must approve each call before it runs.
    public var needsApproval: Bool
    public var execute: (@Sendable (ToolCall) async throws -> JSONValue)?

    public var name: String { definition.name }

    public init(
        name: String,
        description: String? = nil,
        inputSchema: JSONValue = ["type": "object", "properties": [:]],
        strict: Bool? = nil,
        needsApproval: Bool = false,
        execute: (@Sendable (ToolCall) async throws -> JSONValue)? = nil
    ) {
        definition = ChatToolDefinition(name: name, description: description, inputSchema: inputSchema, strict: strict)
        self.needsApproval = needsApproval
        self.execute = execute
    }

    /// A tool whose input and output are your own `Codable` types.
    public static func typed<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        name: String,
        description: String? = nil,
        inputSchema: JSONValue,
        strict: Bool? = nil,
        needsApproval: Bool = false,
        execute: @escaping @Sendable (Input) async throws -> Output
    ) -> ChatTool {
        ChatTool(name: name, description: description, inputSchema: inputSchema, strict: strict, needsApproval: needsApproval) { call in
            let input: Input
            do {
                input = try call.decodeInput(Input.self)
            } catch {
                throw ChatError(kind: .tool, message: "The input for \(name) doesn't match its schema: \(error)", code: "invalid_tool_input")
            }
            return try JSONValue(encoding: try await execute(input))
        }
    }
}
