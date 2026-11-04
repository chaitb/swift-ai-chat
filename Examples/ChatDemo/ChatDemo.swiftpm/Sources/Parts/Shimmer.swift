import SwiftUI

struct Shimmer: ViewModifier {
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            content
                .foregroundStyle(.secondary)
                .overlay {
                    TimelineView(.animation) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        content
                            .foregroundStyle(.primary)
                            .mask {
                                GeometryReader { proxy in
                                    let width = proxy.size.width
                                    LinearGradient(
                                        colors: [.clear, .black, .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: max(width * 0.6, 60))
                                    .offset(x: -width * 0.6 + (width * 1.8) * phase)
                                }
                            }
                    }
                }
        } else if isActive {
            content
                .foregroundStyle(.secondary)
                .phaseAnimator([0.55, 1]) { view, opacity in
                    view.opacity(opacity)
                } animation: { _ in .easeInOut(duration: 1.1) }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(_ isActive: Bool) -> some View {
        modifier(Shimmer(isActive: isActive))
    }
}
