import AIChat
import SwiftUI

struct ToolStatusIcon: View {
    var state: ToolPart.State
    var idleSymbol: String
    var onTint = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(onTint ? .white : tint)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: isWorking && !reduceMotion)
            .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
            .symbolEffect(.bounce.up, value: state == .outputAvailable)
            .frame(width: 22)
    }

    private var isWorking: Bool {
        switch state {
        case .inputStreaming, .inputAvailable, .approvalResponded: true
        default: false
        }
    }

    private var symbol: String {
        switch state {
        case .inputStreaming, .inputAvailable, .approvalResponded: "progress.indicator"
        case .outputAvailable: "checkmark.circle.fill"
        case .outputError: "exclamationmark.triangle.fill"
        case .outputDenied: "xmark.circle.fill"
        case .approvalRequested: "hand.raised.fill"
        case .other: idleSymbol
        }
    }

    private var tint: Color {
        switch state {
        case .outputAvailable: .green
        case .outputError: .orange
        case .outputDenied: .secondary
        case .approvalRequested: .accentColor
        default: .secondary
        }
    }
}
