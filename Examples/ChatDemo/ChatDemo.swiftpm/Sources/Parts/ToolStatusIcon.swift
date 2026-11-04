import AIChat
import SwiftUI

struct ToolStatusIcon: View {
    var part: ToolPart
    var idleSymbol: String
    var onTint = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(onTint ? .monochrome : .hierarchical)
            .foregroundStyle(onTint ? .white : tint)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: isWorking && !reduceMotion)
            .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
            .symbolEffect(.bounce.up, options: reduceMotion ? .nonRepeating.speed(100) : .nonRepeating, value: state == .outputAvailable)
            .frame(width: 22)
    }

    private var state: ToolPart.State { part.state }

    private var isWorking: Bool { part.isRunning }

    private var symbol: String {
        if isWorking { return "progress.indicator" }
        switch state {
        case .inputStreaming, .inputAvailable: return "progress.indicator"
        case .approvalResponded: return "xmark.circle.fill"
        case .outputAvailable: return "checkmark.circle.fill"
        case .outputError: return "exclamationmark.triangle.fill"
        case .outputDenied: return "xmark.circle.fill"
        case .approvalRequested: return "hand.raised.fill"
        case .other: return idleSymbol
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
