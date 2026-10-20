import AIChat
import AIChatTesting
import Foundation
import Testing

@MainActor
@Suite("Models and persistence")
struct ModelAndStoreTests {
    @Test func gatewayCatalogReadsCapabilitiesAndPrices() async throws {
        let http = StubHTTPClient([.json(try Fixtures.json("gateway/models.json"))])
        let models = try await AIGatewayModelCatalog(httpClient: http).models()
        #expect(models.map(\.id) == ["anthropic/claude-opus-5.5", "anthropic/claude-sonnet-5.5", "openai/gpt-6-sol", "openai/gpt-5.4-mini"])
        let opus = try #require(models.first)
        #expect(opus.provider == "anthropic")
        #expect(opus.supports(.imageInput))
        #expect(opus.supports(.reasoning))
        #expect(opus.supports(.toolUse))
        #expect(opus.inputPricePerMillionTokens == 4)
        #expect((opus.contextWindow ?? 0) > 0)
    }

    @Test func pickerLoadsAndKeepsTheChoice() async throws {
        let defaults = UserDefaults(suiteName: "picker-\(UUID().uuidString)")!
        let catalog = StaticModelCatalog([
            ChatModel(id: "a/one", provider: "a", capabilities: [.imageInput]),
            ChatModel(id: "b/two", provider: "b"),
            ChatModel(id: "a/three", provider: "a", capabilities: [.imageInput, .reasoning]),
        ])
        let picker = ModelPicker(catalog: catalog, defaultModelID: "b/two", storageKey: "model", defaults: defaults)
        #expect(picker.selectedModelID == "b/two")
        await picker.load()
        #expect(picker.models.count == 3)
        #expect(picker.selectedModel?.displayName == "Two")
        #expect(picker.modelsByProvider.map(\.provider) == ["a", "b"])
        #expect(picker.models(supporting: [.imageInput, .reasoning]).map(\.id) == ["a/three"])

        picker.selectedModelID = "a/three"
        let reopened = ModelPicker(catalog: catalog, defaultModelID: "b/two", storageKey: "model", defaults: defaults)
        #expect(reopened.selectedModelID == "a/three")
    }

    @Test func pickerFallsBackWhenTheSavedModelIsGone() async throws {
        let defaults = UserDefaults(suiteName: "picker-\(UUID().uuidString)")!
        defaults.set("retired", forKey: "model")
        let picker = ModelPicker(catalog: StaticModelCatalog([ChatModel(id: "current")]), defaultModelID: "current", storageKey: "model", defaults: defaults)
        await picker.load()
        #expect(picker.selectedModelID == "current")
    }

    @Test func pickerReportsCatalogErrors() async throws {
        struct Failing: ChatModelCatalog {
            func models() async throws -> [ChatModel] { throw ChatError(kind: .http, message: "Unauthorized", statusCode: 401) }
        }
        let picker = ModelPicker(catalog: Failing())
        await picker.load()
        #expect(picker.error?.statusCode == 401)
        #expect(picker.models.isEmpty)
    }

    @Test func compositeCatalogQualifiesIDs() async throws {
        let catalog = CompositeModelCatalog([
            ("anthropic", StaticModelCatalog([ChatModel(id: "claude-opus-5-5")])),
            ("openai", StaticModelCatalog([ChatModel(id: "gpt-6-sol")])),
        ])
        let models = try await catalog.models()
        #expect(models.map(\.id) == ["anthropic/claude-opus-5-5", "openai/gpt-6-sol"])
        #expect(models.map(\.provider) == ["anthropic", "openai"])
    }

    @Test func cachedCatalogFetchesOnce() async throws {
        let counter = Counter()
        struct Counting: ChatModelCatalog {
            let counter: Counter
            func models() async throws -> [ChatModel] {
                _ = counter.next()
                return [ChatModel(id: "x")]
            }
        }
        let cached = CachedModelCatalog(Counting(counter: counter))
        _ = try await cached.models()
        _ = try await cached.models()
        #expect(counter.value == 1)
        await cached.invalidate()
        _ = try await cached.models()
        #expect(counter.value == 2)
    }

    @Test func displayNamesComeFromIDs() {
        #expect(ChatModel.displayName(for: "gpt-5.4-mini") == "GPT 5.4 Mini")
        #expect(ChatModel.displayName(for: "anthropic/claude-opus-5-5") == "Claude Opus 5 5")
        #expect(ChatModel.displayName(for: "o4-mini") == "O4 Mini")
    }

    @Test func fileStoreSavesListsAndDeletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileChatStore(directory: directory)
        let older = ChatSnapshot(id: "a/b", messages: [.user("First")], updatedAt: Date(timeIntervalSince1970: 1))
        let newer = ChatSnapshot(id: "c", messages: [.user("Second"), .assistant("Reply")], modelID: "m", title: "Second", updatedAt: Date(timeIntervalSince1970: 2))
        try await store.saveChat(older)
        try await store.saveChat(newer)
        #expect(try await store.loadChat(id: "a/b") == older)
        #expect(try await store.listChats().map(\.id) == ["c", "a/b"])
        #expect(try await store.listChats().first?.messageCount == 2)
        try await store.deleteChat(id: "c")
        #expect(try await store.loadChat(id: "c") == nil)
        #expect(try await store.listChats().map(\.id) == ["a/b"])
    }

    @Test func defaultTitlesCollapseWhitespace() {
        #expect(ChatSnapshot.defaultTitle(for: [.user("  Plan   my\nweek  ")]) == "Plan my week")
        #expect(ChatSnapshot.defaultTitle(for: [.user(String(repeating: "a", count: 100))], limit: 10) == "aaaaaaaaaa…")
    }
}
