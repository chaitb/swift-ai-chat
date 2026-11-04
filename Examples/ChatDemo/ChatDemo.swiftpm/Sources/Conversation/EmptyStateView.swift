import SwiftUI

struct EmptyStateView: View {
    var subtitle: String
    var onPick: (Showcase) -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce.up.byLayer, value: appeared)
                Text("What should we try?")
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)

            VStack(spacing: 10) {
                ForEach(Array(Showcase.allCases.enumerated()), id: \.element) { index, showcase in
                    Button {
                        onPick(showcase)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: showcase.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(showcase.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(showcase.caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18, style: .continuous))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 18)
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0.3).delay(0.12 + Double(index) * 0.05), value: appeared)
                }
            }
            .frame(maxWidth: 420)
        }
        .padding(.horizontal, 24)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.6, bounce: 0.25)) { appeared = true }
        }
    }
}
