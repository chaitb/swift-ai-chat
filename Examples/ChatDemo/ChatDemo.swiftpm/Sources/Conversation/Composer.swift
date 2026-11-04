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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .matchedGeometryEffect(id: flight.id, in: namespace, anchor: .bottomTrailing)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 50)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 25, style: .continuous))

                Button(action: primaryAction) {
                    Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                        .font(.system(size: isBusy ? 15 : 18, weight: .bold))
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
                        .foregroundStyle(isBusy || canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                        .frame(width: 50, height: 50)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(isBusy || canSend ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
                .disabled(!isBusy && !canSend)
                .accessibilityLabel(isBusy ? "Stop" : "Send")
                .sensoryFeedback(.impact(weight: .light), trigger: sends)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.25), value: isBusy)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: canSend)
        .animation(.snappy(duration: 0.22), value: draft.count / 24)
    }

    private func primaryAction() {
        sends += 1
        if isBusy { onStop() } else { onSend() }
    }
}
