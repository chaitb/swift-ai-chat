import AIChat
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var settings: BackendSettings

    init(settings: BackendSettings) {
        _settings = State(initialValue: settings)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Backend", selection: $settings.backend) {
                        ForEach(Backend.allCases) { backend in
                            Label(backend.title, systemImage: backend.symbol).tag(backend)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text(footer)
                }

                switch settings.backend {
                case .demo:
                    EmptyView()
                case .anthropic:
                    Section("Anthropic API key") {
                        SecureField("sk-ant-…", text: $settings.anthropicKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    modelSection
                case .openAI:
                    Section("OpenAI API key") {
                        SecureField("sk-…", text: $settings.openAIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    modelSection
                case .aiSDK:
                    Section {
                        TextField("https://example.com/api/chat", text: $settings.endpoint)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Endpoint")
                    } footer: {
                        Text("Any route that returns toUIMessageStreamResponse().")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.snappy, value: settings.backend)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        let staged = settings
                        dismiss()
                        Task { await model.apply(staged) }
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        if let picker = model.picker, model.backend == settings.backend {
            Section("Model") {
                @Bindable var picker = picker
                if picker.isLoading && picker.models.isEmpty {
                    ProgressView()
                } else if let error = picker.error {
                    Text(error.message).foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $picker.selectedModelID) {
                        ForEach(picker.models) { model in
                            Text(model.displayName).tag(Optional(model.id))
                        }
                    }
                    .onChange(of: picker.selectedModelID) { model.syncModel() }
                }
            }
        } else {
            Section("Model") {
                Text("Save the key to load the model list.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: String {
        switch settings.backend {
        case .demo: "Scripted responses streamed from DemoTransport. No network needed."
        case .anthropic: "AnthropicChatTransport talks to the Messages API directly. The key stays in the Keychain on this device."
        case .openAI: "OpenAIChatTransport uses the Responses API. The key stays in the Keychain on this device."
        case .aiSDK: "AISDKChatTransport speaks the AI SDK UI message stream protocol."
        }
    }
}
