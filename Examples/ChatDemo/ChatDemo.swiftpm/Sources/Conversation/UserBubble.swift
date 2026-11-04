import AIChat
import SwiftUI

struct UserBubble: View {
    var message: UIMessage
    var namespace: Namespace.ID

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            Text(message.text)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.tint, in: .rect(cornerRadius: 20, style: .continuous))
                .matchedGeometryEffect(id: message.id, in: namespace, anchor: .bottomTrailing)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = message.text
                    }
                }
        }
    }
}
