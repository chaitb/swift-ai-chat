import Foundation

enum Showcase: String, CaseIterable, Identifiable, Sendable {
    case weather
    case reasoning
    case approval
    case sources
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather: "Weather in Lisbon"
        case .reasoning: "Plan a weekend in Kyoto"
        case .approval: "Book a table for two"
        case .sources: "What's new in Swift concurrency?"
        case .markdown: "Show off some markdown"
        }
    }

    var caption: String {
        switch self {
        case .weather: "Client tool"
        case .reasoning: "Reasoning"
        case .approval: "Approval"
        case .sources: "Sources"
        case .markdown: "Markdown"
        }
    }

    var symbol: String {
        switch self {
        case .weather: "cloud.sun.fill"
        case .reasoning: "brain.head.profile"
        case .approval: "fork.knife"
        case .sources: "books.vertical.fill"
        case .markdown: "text.badge.star"
        }
    }

    var prompt: String {
        switch self {
        case .weather: "What's the weather in Lisbon?"
        case .reasoning: "Think through a relaxed weekend plan for Kyoto."
        case .approval: "Book a table for two at Nopa on Friday."
        case .sources: "What's new in Swift concurrency? Cite sources."
        case .markdown: "Show off some markdown formatting."
        }
    }

    static func match(_ prompt: String) -> Showcase? {
        let text = prompt.lowercased()
        let keywords: [(Showcase, [String])] = [
            (.weather, ["weather", "forecast", "temperature", "rain", "sunny"]),
            (.approval, ["book", "table", "reserve", "reservation", "approve", "dinner"]),
            (.sources, ["source", "cite", "news", "swift", "research", "latest"]),
            (.markdown, ["markdown", "format", "code", "table", "list"]),
            (.reasoning, ["think", "plan", "reason", "trip", "weekend"]),
        ]
        return keywords.first { _, words in words.contains { text.contains($0) } }?.0
    }
}
