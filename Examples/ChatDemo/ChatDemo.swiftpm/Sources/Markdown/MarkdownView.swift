import SwiftUI

struct MarkdownView: View {
    var text: String
    var isStreaming: Bool

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index], isLast: index == blocks.count - 1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ block: MarkdownBlock, isLast: Bool) -> some View {
        let streaming = isStreaming && isLast
        switch block {
        case .heading(let level, let text):
            StreamingText(content: MarkdownBlock.inline(text), isStreaming: streaming, showsCaret: streaming)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            StreamingText(content: MarkdownBlock.inline(text), isStreaming: streaming, showsCaret: streaming)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(.tint)
                            .frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        StreamingText(content: MarkdownBlock.inline(items[index]), isStreaming: streaming && index == items.count - 1, showsCaret: streaming && index == items.count - 1)
                    }
                    .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
            .padding(.leading, 4)
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(items[index].0).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        StreamingText(content: MarkdownBlock.inline(items[index].1), isStreaming: streaming && index == items.count - 1, showsCaret: streaming && index == items.count - 1)
                    }
                    .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
        case .quote(let text):
            StreamingText(content: MarkdownBlock.inline(text), isStreaming: streaming, showsCaret: streaming)
                .foregroundStyle(.secondary)
                .italic()
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Capsule().fill(.tint.opacity(0.5)).frame(width: 3)
                }
        case .code(let language, let code, _):
            CodeBlockView(language: language, code: code, isStreaming: streaming)
        case .rule:
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }
}

struct CodeBlockView: View {
    var language: String?
    var code: String
    var isStreaming: Bool

    @State private var copied = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied += 1
                } label: {
                    Image(systemName: copied > 0 ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                StreamingText(content: AttributedString(code), isStreaming: isStreaming, showsCaret: false)
                    .font(.system(.callout, design: .monospaced))
                    .padding(14)
            }
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
        .sensoryFeedback(.success, trigger: copied)
    }
}
