import AIChat
import SwiftUI

struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.summaries.isEmpty {
                    ContentUnavailableView("No saved chats", systemImage: "bubble.left.and.bubble.right", description: Text("Chats are saved with FileChatStore as you go."))
                        .listRowBackground(Color.clear)
                }
                ForEach(model.summaries) { summary in
                    Button {
                        Task {
                            await model.select(summary.id)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(summary.title ?? "New Chat")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(summary.messageCount) messages · \(summary.updatedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if summary.id == model.chat.id {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await model.delete(summary.id) }
                        }
                    }
                }
            }
            .animation(.snappy, value: model.summaries.map(\.id))
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        Task {
                            await model.newChat()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
            }
            .task { await model.reloadList() }
        }
    }
}
