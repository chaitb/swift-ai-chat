import SwiftUI

enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([(Int, String)])
    case quote(String)
    case code(language: String?, code: String, closed: Bool)
    case rule

    static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        lhs.signature == rhs.signature
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(signature)
    }

    private var signature: String {
        switch self {
        case .heading(let level, let text): "h\(level):\(text)"
        case .paragraph(let text): "p:\(text)"
        case .bullets(let items): "ul:" + items.joined(separator: "\u{1}")
        case .numbered(let items): "ol:" + items.map { "\($0.0).\($0.1)" }.joined(separator: "\u{1}")
        case .quote(let text): "q:\(text)"
        case .code(let language, let code, let closed): "c:\(language ?? ""):\(closed):\(code)"
        case .rule: "hr"
        }
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [(Int, String)] = []
        var quote: [String] = []
        var code: (language: String?, lines: [String])?

        func flush() {
            if !paragraph.isEmpty {
                var text = ""
                for (index, line) in paragraph.enumerated() {
                    text += line.trimmingCharacters(in: .whitespaces)
                    guard index < paragraph.count - 1 else { continue }
                    text += line.hasSuffix("  ") ? "\n" : " "
                }
                blocks.append(.paragraph(text))
                paragraph = []
            }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n"), closed: true))
                    code = nil
                } else {
                    open.lines.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = (language.isEmpty ? nil : language, [])
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed == "---" || trimmed == "***" {
                flush()
                blocks.append(.rule)
                continue
            }
            if let heading = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush()
                blocks.append(.heading(level: heading.1.count, text: String(heading.2)))
                continue
            }
            if let bullet = trimmed.firstMatch(of: /^[-*•]\s+(.*)$/) {
                if bullets.isEmpty { flush() }
                bullets.append(String(bullet.1))
                continue
            }
            if let item = trimmed.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                if numbered.isEmpty { flush() }
                numbered.append((Int(item.1) ?? numbered.count + 1, String(item.2)))
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if !bullets.isEmpty || !numbered.isEmpty || !quote.isEmpty { flush() }
            paragraph.append(String(line.drop { $0 == " " || $0 == "\t" }))
        }
        if var open = code {
            flush()
            if open.lines.last?.isEmpty == true { open.lines.removeLast() }
            blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n"), closed: false))
        }
        flush()
        return blocks
    }

    static func inline(_ text: String, citationOffset: CGFloat = 6) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                attributed[run.range].font = .system(.body, design: .monospaced).weight(.medium)
                attributed[run.range].foregroundColor = Color.accentColor
                attributed[run.range].backgroundColor = Color.accentColor.opacity(0.1)
            }
        }
        let plain = String(attributed.characters)
        for match in plain.matches(of: /\[(\d{1,2})\]/).reversed() {
            let start = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let length = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let lower = attributed.characters.index(attributed.startIndex, offsetBy: start)
            let upper = attributed.characters.index(lower, offsetBy: length)
            var marker = AttributedString(String(match.1))
            marker.font = .caption2.weight(.bold)
            marker.foregroundColor = Color.accentColor
            marker.baselineOffset = citationOffset
            attributed.replaceSubrange(lower..<upper, with: marker)
        }
        return attributed
    }
}
