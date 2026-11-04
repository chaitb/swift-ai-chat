import SwiftUI

struct AssistantAvatar: View {
    var isWorking: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .symbolEffect(.breathe.pulse.byLayer, options: .repeating, isActive: isWorking && !reduceMotion)
            .frame(width: 24, height: 24)
            .background(.tint, in: .circle)
            .accessibilityHidden(true)
    }
}

struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = reduceMotion ? 0.5 : (sin(time * 6 - Double(index) * 0.8) + 1) / 2
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.7 + 0.3 * phase)
                        .opacity(0.35 + 0.65 * phase)
                        .offset(y: reduceMotion ? 0 : -2 * phase)
                }
            }
        }
        .accessibilityLabel("Thinking")
    }
}
