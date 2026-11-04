import AIChat
import SwiftUI

struct GenericToolCard: View {
    var part: ToolPart

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.3)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ToolStatusIcon(state: part.state, idleSymbol: "wrench.and.screwdriver")
                    Text(part.title ?? part.toolName)
                        .font(.subheadline.weight(.semibold).monospaced())
                        .shimmer(part.isRunning)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = part.input {
                        payload("Input", input.prettyJSONString)
                    }
                    if let output = part.output {
                        payload("Output", output.prettyJSONString)
                    }
                    if let error = part.errorText {
                        payload("Error", error)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 18, style: .continuous))
        .animation(.spring(duration: 0.4, bounce: 0.15), value: part.state)
    }

    private func payload(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(text)
                .font(.caption.monospaced())
                .lineLimit(12)
                .textSelection(.enabled)
        }
    }
}
