import SwiftUI

struct Flight: Equatable {
    var id: String
    var text: String
    var landed = false
}

struct Composer: View {
    @Binding var draft: String
    var isBusy: Bool
    var flight: Flight?
    var namespace: Namespace.ID
    var focus: FocusState<Bool>.Binding
    var onSend: () -> Void
    var onStop: () -> Void

    @State private var sends = 0
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 50
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .leading) {
                    TextField("Message", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused(focus)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 18)
                    if let flight, !flight.landed {
                        Text(flight.text)
                            .lineLimit(6)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .matchedGeometryEffect(id: flight.id, in: namespace, anchor: .bottomTrailing)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: fieldHeight)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 25, style: .continuous))

                Button(action: primaryAction) {
                    Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
                        .foregroundStyle(isBusy || canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                        .frame(width: fieldHeight, height: fieldHeight)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(isBusy || canSend ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
                .disabled(!isBusy && !canSend)
                .accessibilityLabel(isBusy ? "Stop" : "Send")
                .sensoryFeedback(.impact(weight: .light), trigger: sends)
            }
        }
        .animation(Motion.spring(0.35, bounce: 0.25, reduced: reduceMotion), value: isBusy)
        .animation(Motion.spring(0.3, reduced: reduceMotion), value: canSend)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: draft)
    }

    private func primaryAction() {
        sends += 1
        if isBusy { onStop() } else { onSend() }
    }
}
