import SwiftUI

struct ThinkingIndicator: View {
    var name: String
    var turnID: String
    var namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 8) {
            AssistantAvatar(isWorking: true)
                .matchedGeometryEffect(id: "\(turnID)-avatar", in: namespace)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .shimmer(true)
                .matchedGeometryEffect(id: "\(turnID)-name", in: namespace)
            ThinkingDots()
                .padding(.leading, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.asymmetric(insertion: .opacity, removal: .identity))
    }
}
