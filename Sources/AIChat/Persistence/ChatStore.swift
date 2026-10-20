import Foundation

/// A saved conversation.
public struct ChatSnapshot: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var messages: [UIMessage]
    /// The model chosen for this conversation.
    public var modelID: String?
    public var title: String?
    /// App-defined data saved with the conversation.
    public var metadata: JSONValue?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        messages: [UIMessage],
        modelID: String? = nil,
        title: String? = nil,
        metadata: JSONValue? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.messages = messages
        self.modelID = modelID
        self.title = title
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A title from the first user message, at most `limit` characters.
    public static func defaultTitle(for messages: [UIMessage], limit: Int = 80) -> String? {
        guard let text = messages.first(where: { $0.role == .user })?.text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}

/// The list entry for a saved conversation.
public struct ChatSummary: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String?
    public var modelID: String?
    public var messageCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(snapshot: ChatSnapshot) {
        id = snapshot.id
        title = snapshot.title
        modelID = snapshot.modelID
        messageCount = snapshot.messages.count
        createdAt = snapshot.createdAt
        updatedAt = snapshot.updatedAt
    }
}

/// Saves and loads conversations.
///
/// ``Chat`` saves through its store after every user message and every finished
/// response when ``ChatConfiguration/store`` is set.
public protocol ChatStore: Sendable {
    func loadChat(id: String) async throws -> ChatSnapshot?
    func saveChat(_ snapshot: ChatSnapshot) async throws
    func deleteChat(id: String) async throws
    /// The saved conversations, most recently updated first.
    func listChats() async throws -> [ChatSummary]
}

/// Keeps conversations in memory, for previews and tests.
public actor InMemoryChatStore: ChatStore {
    private var snapshots: [String: ChatSnapshot]

    public init(_ snapshots: [ChatSnapshot] = []) {
        self.snapshots = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func loadChat(id: String) async throws -> ChatSnapshot? { snapshots[id] }

    public func saveChat(_ snapshot: ChatSnapshot) async throws { snapshots[snapshot.id] = snapshot }

    public func deleteChat(id: String) async throws { snapshots[id] = nil }

    public func listChats() async throws -> [ChatSummary] {
        snapshots.values.sorted { $0.updatedAt > $1.updatedAt }.map(ChatSummary.init(snapshot:))
    }
}

/// Keeps each conversation in a JSON file in a directory.
public actor FileChatStore: ChatStore {
    public let directory: URL
    private let fileManager = FileManager()

    /// - Parameter directory: Created when missing. Defaults to `Application Support/Chats`.
    public init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("Chats", isDirectory: true)
    }

    public func loadChat(id: String) async throws -> ChatSnapshot? {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try Self.decoder.decode(ChatSnapshot.self, from: data)
        } catch {
            throw ChatError(kind: .persistence, message: "Chat \(id) couldn't be read.", operation: "store.load", underlying: String(describing: error))
        }
    }

    public func saveChat(_ snapshot: ChatSnapshot) async throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(snapshot)
            try data.write(to: fileURL(for: snapshot.id), options: .atomic)
        } catch {
            throw ChatError(kind: .persistence, message: "Chat \(snapshot.id) couldn't be saved.", operation: "store.save", underlying: String(describing: error))
        }
    }

    public func deleteChat(id: String) async throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ChatError(kind: .persistence, message: "Chat \(id) couldn't be deleted.", operation: "store.delete", underlying: String(describing: error))
        }
    }

    public func listChats() async throws -> [ChatSummary] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw ChatError(kind: .persistence, message: "The chat list couldn't be read.", operation: "store.list", underlying: String(describing: error))
        }
        var summaries: [ChatSummary] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? Self.decoder.decode(ChatSnapshot.self, from: data)
            else { continue }
            summaries.append(ChatSummary(snapshot: snapshot))
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func fileURL(for id: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = id.unicodeScalars.map { allowed.contains($0) ? String($0) : String(format: "%%%02X", $0.value) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder { JSONDecoder() }
}
