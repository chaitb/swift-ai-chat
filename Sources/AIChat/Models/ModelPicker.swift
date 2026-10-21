import Foundation
import Observation

/// Loads the models of a ``ChatModelCatalog`` and keeps the user's choice.
///
/// It holds no views. Bind ``selectedModelID`` to a SwiftUI `Picker` and to
/// ``Chat/modelID``.
///
/// ```swift
/// @State var picker = ModelPicker(catalog: AnthropicModelCatalog(apiKey: key), defaultModelID: "claude-opus-5-5")
///
/// Picker("Model", selection: $picker.selectedModelID) {
///     ForEach(picker.models) { Text($0.displayName).tag(Optional($0.id)) }
/// }
/// .task { await picker.load() }
/// ```
@MainActor
@Observable
public final class ModelPicker {
    public private(set) var models: [ChatModel] = []
    public private(set) var isLoading = false
    public private(set) var error: ChatError?
    /// The chosen model. Saved under `storageKey` when one is given.
    public var selectedModelID: String? {
        didSet {
            guard selectedModelID != oldValue, let storageKey else { return }
            defaults.set(selectedModelID, forKey: storageKey)
        }
    }

    @ObservationIgnored private let catalog: any ChatModelCatalog
    @ObservationIgnored private let defaultModelID: String?
    @ObservationIgnored private let storageKey: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let filter: @Sendable (ChatModel) -> Bool
    @ObservationIgnored private let sort: @Sendable (ChatModel, ChatModel) -> Bool

    /// - Parameters:
    ///   - defaultModelID: Selected when nothing was chosen yet, or when the saved choice disappears.
    ///   - storageKey: A `UserDefaults` key to remember the choice across launches.
    ///   - filter: Which models to offer.
    ///   - sort: The order of ``models``. The catalog's order is kept by default.
    public init(
        catalog: any ChatModelCatalog,
        defaultModelID: String? = nil,
        storageKey: String? = nil,
        defaults: UserDefaults = .standard,
        filter: @escaping @Sendable (ChatModel) -> Bool = { _ in true },
        sort: @escaping @Sendable (ChatModel, ChatModel) -> Bool = { _, _ in false }
    ) {
        self.catalog = catalog
        self.defaultModelID = defaultModelID
        self.storageKey = storageKey
        self.defaults = defaults
        self.filter = filter
        self.sort = sort
        selectedModelID = storageKey.flatMap { defaults.string(forKey: $0) } ?? defaultModelID
    }

    public var selectedModel: ChatModel? {
        guard let selectedModelID else { return nil }
        return models.first { $0.id == selectedModelID }
    }

    /// The models grouped by provider, in the order providers first appear.
    public var modelsByProvider: [(provider: String, models: [ChatModel])] {
        var order: [String] = []
        var groups: [String: [ChatModel]] = [:]
        for model in models {
            let provider = model.provider ?? "other"
            if groups[provider] == nil { order.append(provider) }
            groups[provider, default: []].append(model)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// The models that support every one of `capabilities`, for example image input
    /// when the user attached a photo.
    public func models(supporting capabilities: Set<ChatModelCapability>) -> [ChatModel] {
        models.filter { capabilities.isSubset(of: $0.capabilities) }
    }

    /// Loads the list once. Later calls do nothing until ``reload()``.
    public func load() async {
        guard models.isEmpty, !isLoading else { return }
        await reload()
    }

    /// Fetches the list again.
    public func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await catalog.models().filter(filter)
            models = fetched.enumerated().sorted { lhs, rhs in
                if sort(lhs.element, rhs.element) { return true }
                if sort(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }.map(\.element)
            error = nil
            if let selectedModelID, !models.contains(where: { $0.id == selectedModelID }) {
                self.selectedModelID = defaultModelID.flatMap { id in models.contains { $0.id == id } ? id : nil } ?? models.first?.id
            } else if selectedModelID == nil {
                selectedModelID = defaultModelID ?? models.first?.id
            }
        } catch {
            self.error = ChatError.from(error, operation: "models.load")
        }
    }
}
