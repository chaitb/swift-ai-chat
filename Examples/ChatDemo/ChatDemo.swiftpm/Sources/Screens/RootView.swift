import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showsChats = false
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            ConversationView(chat: model.chat, assistantName: model.assistantName, emptySubtitle: subtitle)
                .id(model.chat.id)
                .transition(.opacity)
                .navigationTitle(model.title)
                .navigationSubtitle(model.backend == .demo ? "Offline demo" : model.assistantName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Chats", systemImage: "list.bullet") { showsChats = true }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showsSettings = true }
                        Button("New Chat", systemImage: "square.and.pencil") {
                            Task { await model.newChat() }
                        }
                        .disabled(model.chat.messages.isEmpty)
                    }
                }
        }
        .animation(.easeInOut(duration: 0.25), value: model.chat.id)
        .sheet(isPresented: $showsChats) {
            ChatListView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(settings: model.settings)
        }
    }

    private var subtitle: String {
        switch model.backend {
        case .demo: "Scripted replies, streamed offline with real chunks."
        case .anthropic, .openAI: "Talking to \(model.assistantName)."
        case .aiSDK: "Talking to your AI SDK endpoint."
        }
    }
}
