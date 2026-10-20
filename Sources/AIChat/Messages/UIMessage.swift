import Foundation

/// A chat message in the AI SDK `UIMessage` shape.
///
/// Encodes to exactly the JSON an AI SDK backend expects in `messages` and decodes
/// the JSON it persists. Keys this version of the package doesn't model are kept.
public struct UIMessage: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable, Hashable, Codable, CaseIterable {
        case system
        case user
        case assistant
    }

    public var id: String
    public var role: Role
    /// App-defined metadata. Servers fill it through `start`, `finish` and `message-metadata` chunks.
    public var metadata: JSONValue?
    public var parts: [UIMessagePart]
    /// Keys this version of the package doesn't model, kept for round trips.
    public var extra: [String: JSONValue]

    public init(
        id: String = ChatID.generate(),
        role: Role,
        parts: [UIMessagePart],
        metadata: JSONValue? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.role = role
        self.parts = parts
        self.metadata = metadata
        self.extra = extra
    }

    /// A user message with text and optional attachments. Files come first, like the AI SDK.
    public static func user(_ text: String?, files: [FilePart] = [], id: String = ChatID.generate(), metadata: JSONValue? = nil) -> UIMessage {
        var parts = files.map(UIMessagePart.file)
        if let text { parts.append(.text(text)) }
        return UIMessage(id: id, role: .user, parts: parts, metadata: metadata)
    }

    /// An assistant message with a single text part.
    public static func assistant(_ text: String, id: String = ChatID.generate(), metadata: JSONValue? = nil) -> UIMessage {
        UIMessage(id: id, role: .assistant, parts: [.text(TextPart(text: text, state: .done))], metadata: metadata)
    }

    /// A system message with a single text part.
    public static func system(_ text: String, id: String = ChatID.generate()) -> UIMessage {
        UIMessage(id: id, role: .system, parts: [.text(text)])
    }
}

extension UIMessage: JSONObjectConvertible {
    public init(jsonObject: [String: JSONValue]) throws(ChatError) {
        var reader = ObjectReader(jsonObject, context: "Message")
        id = try reader.string("id")
        let roleName = try reader.string("role")
        guard let role = Role(rawValue: roleName) else {
            throw ChatError(kind: .decoding, message: "Message \(id) has an unknown role \"\(roleName)\".")
        }
        self.role = role
        metadata = reader.optionalValue("metadata")
        guard let rawParts = reader.take("parts")?.arrayValue else {
            throw ChatError(kind: .decoding, message: "Message \(id) is missing its parts array.")
        }
        var parts: [UIMessagePart] = []
        parts.reserveCapacity(rawParts.count)
        for value in rawParts {
            guard let object = value.objectValue else {
                throw ChatError(kind: .decoding, message: "Message \(id) has a part that is not an object.")
            }
            parts.append(try UIMessagePart(jsonObject: object))
        }
        self.parts = parts
        extra = reader.remaining
    }

    public var jsonObject: [String: JSONValue] {
        var writer = ObjectWriter(extra: extra)
        writer.set("id", id)
        writer.set("role", role.rawValue)
        writer.set("metadata", metadata)
        writer.set("parts", JSONValue.array(parts.map { .object($0.jsonObject) }))
        return writer.object
    }
}

extension UIMessage {
    /// All text parts joined in order.
    public var text: String {
        parts.compactMap { $0.textPart?.text }.joined()
    }

    /// All reasoning parts joined in order.
    public var reasoningText: String {
        parts.compactMap { $0.reasoningPart?.text }.joined()
    }

    /// Static and dynamic tool invocations in order.
    public var toolParts: [ToolPart] {
        parts.compactMap(\.toolPart)
    }

    public var fileParts: [FilePart] {
        parts.compactMap(\.filePart)
    }

    public var sourceURLParts: [SourceURLPart] {
        parts.compactMap { part in
            if case .sourceURL(let source) = part { return source }
            return nil
        }
    }

    public var dataParts: [DataPart] {
        parts.compactMap(\.dataPart)
    }

    public func dataParts(named name: String) -> [DataPart] {
        dataParts.filter { $0.name == name }
    }

    /// The tool part with this call id.
    public func toolPart(callID: String) -> ToolPart? {
        parts.lazy.compactMap(\.toolPart).last { $0.toolCallId == callID }
    }

    /// The index in ``parts`` of the tool part with this call id.
    public func indexOfTool(callID: String) -> Int? {
        parts.lastIndex { $0.toolPart?.toolCallId == callID }
    }

    /// The parts grouped into steps, split at `step-start` boundaries.
    public var steps: [[UIMessagePart]] {
        var steps: [[UIMessagePart]] = []
        var current: [UIMessagePart] = []
        for part in parts {
            if part.isStepStart {
                if !current.isEmpty { steps.append(current) }
                current = []
            } else {
                current.append(part)
            }
        }
        if !current.isEmpty { steps.append(current) }
        return steps
    }

    /// The parts after the last `step-start`.
    public var lastStepParts: ArraySlice<UIMessagePart> {
        let start = parts.lastIndex(where: \.isStepStart).map { $0 + 1 } ?? parts.startIndex
        return parts[start...]
    }

    /// Whether the message has nothing a user would see: no text, reasoning, tools, files or sources.
    public var isEmpty: Bool {
        !parts.contains { part in
            switch part {
            case .text(let text): !text.text.isEmpty
            case .reasoning(let reasoning): !reasoning.text.isEmpty
            case .tool, .file, .reasoningFile, .sourceURL, .sourceDocument, .custom: true
            case .data, .stepStart, .unknown: false
            }
        }
    }

    /// Decodes ``metadata`` into your own type.
    public func decodeMetadata<T: Decodable>(_ type: T.Type = T.self, using decoder: JSONDecoder = JSONDecoder()) throws -> T? {
        guard let metadata else { return nil }
        return try metadata.decode(T.self, using: decoder)
    }
}

/// Generates ids for chats and messages.
public enum ChatID {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// A random 16 character alphanumeric id, like the AI SDK's `generateId`.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet[Int(generator.next(upperBound: UInt(alphabet.count)))] })
    }
}
