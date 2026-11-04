import AIChat
import AIChatAnthropic
import AIChatOpenAI
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var chat: Chat
    private(set) var summaries: [ChatSummary] = []
    private(set) var settings: BackendSettings
    private(set) var picker: ModelPicker?

    @ObservationIgnored private let store: FileChatStore
    @ObservationIgnored private var isSwitching = false

    init() {
        let settings = BackendSettings.load()
        let store = FileChatStore()
        let picker = Self.makePicker(for: settings)
        self.settings = settings
        self.store = store
        self.picker = picker
        chat = Chat(modelID: picker?.selectedModelID, transport: Self.makeTransport(for: settings), configuration: Self.baseConfiguration(store: store))
        chat.configuration = configuration
    }

    var backend: Backend { settings.effectiveBackend }

    var assistantName: String {
        switch backend {
        case .demo: "Demo"
        case .aiSDK: settings.endpointURL?.host() ?? "AI SDK"
        case .anthropic, .openAI: picker?.selectedModel?.displayName ?? picker?.selectedModelID.map(ChatModel.displayName(for:)) ?? backend.title
        }
    }

    var title: String {
        chat.title ?? ChatSnapshot.defaultTitle(for: chat.messages, limit: 32) ?? "New Chat"
    }

    func start() async {
        await reloadList()
        if let latest = summaries.first, chat.messages.isEmpty {
            await select(latest.id)
        }
        await picker?.load()
        syncModel()
    }

    func reloadList() async {
        summaries = (try? await store.listChats()) ?? []
    }

    func newChat() async {
        guard !chat.messages.isEmpty, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        await settle(chat)
        chat = Chat(modelID: picker?.selectedModelID, transport: Self.makeTransport(for: settings), configuration: configuration)
        await reloadList()
    }

    func select(_ id: String) async {
        guard id != chat.id, !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        await settle(chat)
        guard let restored = try? await Chat.restore(id: id, transport: Self.makeTransport(for: settings), configuration: configuration) else {
            await reloadList()
            return
        }
        chat = restored
        syncModel()
        await reloadList()
    }

    func delete(_ id: String) async {
        guard !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        if id == chat.id {
            await settle(chat)
            chat = Chat(modelID: picker?.selectedModelID, transport: Self.makeTransport(for: settings), configuration: configuration)
        }
        try? await store.deleteChat(id: id)
        await reloadList()
    }

    func apply(_ newSettings: BackendSettings) async {
        guard !isSwitching else { return }
        newSettings.save(replacing: settings)
        let changed = newSettings != settings
        settings = newSettings
        guard changed else { return }
        isSwitching = true
        defer { isSwitching = false }
        picker = Self.makePicker(for: newSettings)
        await settle(chat)
        chat = Chat(snapshot: chat.snapshot, transport: Self.makeTransport(for: newSettings), configuration: configuration)
        syncModel()
        Task {
            await picker?.load()
            syncModel()
        }
    }

    private func settle(_ chat: Chat) async {
        chat.stop()
        for _ in 0..<100 where chat.status.isBusy {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await chat.waitForPendingSaves()
    }

    func syncModel() {
        guard let picker else { return }
        chat.modelID = picker.selectedModelID
    }

    private var configuration: ChatConfiguration {
        var configuration = Self.baseConfiguration(store: store)
        configuration.onFinish = { [weak self] _ in
            guard let self else { return }
            let finished = chat
            Task {
                await finished.waitForPendingSaves()
                await self.reloadList()
            }
        }
        return configuration
    }

    private static func baseConfiguration(store: FileChatStore) -> ChatConfiguration {
        ChatConfiguration(
            tools: [DemoTools.weather],
            sendAutomaticallyWhen: .any(.lastAssistantMessageIsCompleteWithToolCalls, .lastAssistantMessageIsCompleteWithApprovalResponses),
            updateInterval: .milliseconds(24),
            store: store
        )
    }

    private static let system = "You are the assistant in the swift-ai-chat demo app. Keep answers short and use markdown. Use get_weather for weather questions."

    private static func makeTransport(for settings: BackendSettings) -> any ChatTransport {
        switch settings.effectiveBackend {
        case .demo:
            return DemoTransport()
        case .anthropic:
            var configuration = AnthropicConfiguration.apiKey(settings.anthropicKey)
            configuration.system = system
            configuration.thinking = .adaptive(display: .summarized)
            return AnthropicChatTransport(configuration: configuration)
        case .openAI:
            var configuration = OpenAIConfiguration.apiKey(settings.openAIKey)
            configuration.system = system
            configuration.reasoning = .init(effort: .low, summary: .auto)
            return OpenAIChatTransport(configuration: configuration)
        case .aiSDK:
            guard let url = settings.endpointURL else { return DemoTransport() }
            return AISDKChatTransport(api: url)
        }
    }

    private static func makePicker(for settings: BackendSettings) -> ModelPicker? {
        switch settings.effectiveBackend {
        case .anthropic:
            ModelPicker(
                catalog: AnthropicModelCatalog(apiKey: settings.anthropicKey),
                defaultModelID: "claude-opus-5-5",
                storageKey: "demo.model.anthropic",
                filter: { !$0.id.hasPrefix("claude-3") }
            )
        case .openAI:
            ModelPicker(
                catalog: OpenAIModelCatalog(apiKey: settings.openAIKey),
                defaultModelID: "gpt-5.5",
                storageKey: "demo.model.openai",
                filter: { model in ["gpt-5", "o3", "o4"].contains { model.id.hasPrefix($0) } }
            )
        case .demo, .aiSDK:
            nil
        }
    }
}
