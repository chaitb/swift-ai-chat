import Foundation

/// The result a model reads for a tool call when a direct provider transport sends the
/// conversation back. Providers need a result for every call they made, so denied and
/// unfinished calls become error results.
public struct ToolModelResult: Hashable, Sendable {
    public static let denied = "The user denied this tool call."
    public static let unfinished = "The tool call did not finish, so it has no result."

    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

extension ToolPart {
    public var modelResult: ToolModelResult {
        switch state {
        case .outputAvailable:
            switch output {
            case .string(let text)?: return ToolModelResult(text: text, isError: false)
            case let output?: return ToolModelResult(text: output.jsonString, isError: false)
            case nil: return ToolModelResult(text: "", isError: false)
            }
        case .outputError:
            return ToolModelResult(text: errorText ?? "The tool failed.", isError: true)
        case .outputDenied:
            return ToolModelResult(text: denialText, isError: true)
        case .approvalResponded where approval?.approved == false:
            return ToolModelResult(text: denialText, isError: true)
        default:
            return ToolModelResult(text: ToolModelResult.unfinished, isError: true)
        }
    }

    private var denialText: String {
        guard let reason = approval?.reason, !reason.isEmpty else { return ToolModelResult.denied }
        return "\(ToolModelResult.denied) Reason: \(reason)"
    }
}
