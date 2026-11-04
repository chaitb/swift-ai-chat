import AIChat
import SwiftUI

struct ApprovalCard: View {
    var part: ToolPart
    var respond: (Bool) -> Void

    @State private var decision: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                ToolStatusIcon(part: part, idleSymbol: "fork.knife")
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.toolName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.opacity)
                        .shimmer(part.isRunning)
                }
                Spacer()
            }

            if !details.isEmpty {
                VStack(spacing: 8) {
                    ForEach(details, id: \.0) { label, value in
                        LabeledContent {
                            Text(value).fontWeight(.medium).foregroundStyle(.primary)
                        } label: {
                            Text(label).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(12)
                .background(.fill.tertiary, in: .rect(cornerRadius: 14, style: .continuous))
                .transition(Motion.insertion(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)), reduced: reduceMotion))
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
                .transition(.asymmetric(insertion: Motion.insertion(.opacity.combined(with: .offset(y: 8)), reduced: reduceMotion), removal: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9))))
            }

            if let confirmation = part.output?["confirmation"]?.stringValue {
                Label {
                    Text("Confirmation \(Text(confirmation).monospaced().bold())")
                } icon: {
                    Image(systemName: "ticket.fill")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .transition(Motion.insertion(.opacity.combined(with: .offset(y: 6)), reduced: reduceMotion))
            }
        }
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.tint.opacity(part.state == .approvalRequested ? 0.45 : 0), lineWidth: 1.5)
        }
        .animation(Motion.spring(0.45, reduced: reduceMotion), value: part.state)
        .sensoryFeedback(trigger: decision) { _, new in
            switch new {
            case true?: .success
            case false?: .impact(weight: .medium)
            case nil: nil
            }
        }
        .sensoryFeedback(.selection, trigger: part.state == .approvalRequested) { _, requested in requested }
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
