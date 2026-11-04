import AIChat
import SwiftUI

struct ApprovalCard: View {
    var part: ToolPart
    var respond: (Bool) -> Void

    @State private var decision: Bool?

    private var details: [(String, String)] {
        guard let object = part.input?.objectValue else { return [] }
        let order = ["restaurant", "date", "time", "partySize"]
        return object.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }.compactMap { key in
            guard let value = object[key] else { return nil }
            let text = value.stringValue ?? value.intValue.map(String.init) ?? value.jsonString
            return (Self.label(for: key), text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ToolStatusIcon(state: part.state, idleSymbol: "fork.knife")
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.toolName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.opacity)
                        .shimmer(part.isRunning)
                }
                Spacer()
            }

            if !details.isEmpty {
                VStack(spacing: 8) {
                    ForEach(details, id: \.0) { label, value in
                        HStack {
                            Text(label).foregroundStyle(.secondary)
                            Spacer()
                            Text(value).fontWeight(.medium)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(12)
                .background(.background.opacity(0.6), in: .rect(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }

            if part.state == .approvalRequested {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            answer(false)
                        } label: {
                            Label("Deny", systemImage: "xmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        Button {
                            answer(true)
                        } label: {
                            Label("Approve", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .controlSize(.large)
                    .font(.subheadline.weight(.semibold))
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity.combined(with: .scale(scale: 0.9))))
            }

            if let confirmation = part.output?["confirmation"]?.stringValue {
                Label {
                    Text("Confirmation \(Text(confirmation).monospaced().bold())")
                } icon: {
                    Image(systemName: "ticket.fill")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.tint.opacity(part.state == .approvalRequested ? 0.45 : 0), lineWidth: 1.5)
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: part.state)
        .sensoryFeedback(trigger: decision) { _, new in
            switch new {
            case true?: .success
            case false?: .impact(weight: .medium)
            case nil: nil
            }
        }
        .sensoryFeedback(.selection, trigger: part.state == .approvalRequested)
    }

    private func answer(_ approved: Bool) {
        decision = approved
        respond(approved)
    }

    private var headline: String {
        switch part.state {
        case .inputStreaming: "Preparing request"
        case .inputAvailable: "Waiting"
        case .approvalRequested: "Needs your approval"
        case .approvalResponded: part.approval?.approved == true ? "Approved, working on it" : "Declined"
        case .outputAvailable: "Done"
        case .outputDenied: "Declined"
        case .outputError: part.errorText ?? "Failed"
        case .other(let state): state
        }
    }

    private static func label(for key: String) -> String {
        switch key {
        case "partySize": "Party"
        default:
            key.prefix(1).uppercased() + key.dropFirst()
        }
    }
}
