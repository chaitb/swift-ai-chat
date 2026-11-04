import AIChat
import SwiftUI

struct ReasoningRow: View {
    var part: ReasoningPart
    var isStreaming: Bool

    @State private var expanded: Bool?
    @State private var startedAt: Date?
    @State private var duration: TimeInterval?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { expanded ?? isStreaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.32)) { expanded = !isOpen }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .symbolEffect(.pulse, options: .repeating, isActive: isStreaming && !reduceMotion)
                    Text(label)
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .shimmer(isStreaming)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides the reasoning" : "Shows the reasoning")

            if isOpen, !part.text.isEmpty {
                StreamingText(content: AttributedString(part.text), isStreaming: isStreaming, showsCaret: false)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(width: 2)
                    }
                    .transition(Motion.insertion(.opacity.combined(with: .offset(y: -6)), reduced: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isStreaming, initial: true) { _, streaming in
            if streaming, startedAt == nil { startedAt = .now }
            if !streaming, let startedAt, duration == nil { duration = Date.now.timeIntervalSince(startedAt) }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.35), value: isStreaming)
    }

    private var label: String {
        if isStreaming { return "Thinking" }
        if let duration { return "Thought for \(max(1, Int(duration.rounded()))) seconds" }
        return "Reasoning"
    }
}
