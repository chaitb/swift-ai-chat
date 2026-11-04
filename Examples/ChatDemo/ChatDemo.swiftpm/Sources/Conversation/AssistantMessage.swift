import AIChat
import SwiftUI

struct AssistantMessage: View {
    var message: UIMessage
    var name: String
    var turnID: String
    var isLast: Bool
    var status: ChatStatus
    var isBusy: Bool
    var namespace: Namespace.ID
    var respond: (String, Bool) -> Void

    private var isActive: Bool { isLast && isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ForEach(items) { item in
                view(for: item)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)).combined(with: .offset(y: 6)),
                        removal: .opacity
                    ))
            }
            if isLast && status == .submitted && !items.isEmpty {
                ThinkingDots()
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: items.map(\.id))
        .animation(.easeOut(duration: 0.2), value: status)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AssistantAvatar(isWorking: isActive)
                .matchedGeometryEffect(id: "\(turnID)-avatar", in: namespace)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .matchedGeometryEffect(id: "\(turnID)-name", in: namespace)
        }
    }

    @ViewBuilder
    private func view(for item: Item) -> some View {
        switch item.content {
        case .text(let part):
            MarkdownView(text: part.text, isStreaming: isActive && part.state == .streaming)
                .textSelection(.enabled)
        case .reasoning(let part):
            ReasoningRow(part: part, isStreaming: isActive && part.state == .streaming)
        case .tool(let part):
            if part.toolName == DemoTools.weatherName {
                WeatherCard(part: part)
            } else if part.approval != nil || part.toolName == DemoTools.bookingName {
                ApprovalCard(part: part) { approved in
                    if let id = part.approval?.id { respond(id, approved) }
                }
            } else {
                GenericToolCard(part: part)
            }
        case .sources(let sources):
            SourcesRow(sources: sources)
        }
    }

    private var items: [Item] {
        var items: [Item] = []
        var sources: [SourceURLPart] = []
        var sourcesIndex: Int?
        for (index, part) in message.parts.enumerated() {
            switch part {
            case .text(let text) where !text.text.isEmpty:
                items.append(Item(id: index, content: .text(text)))
            case .reasoning(let reasoning) where !reasoning.text.isEmpty || reasoning.state == .streaming:
                items.append(Item(id: index, content: .reasoning(reasoning)))
            case .tool(let tool):
                items.append(Item(id: index, content: .tool(tool)))
            case .sourceURL(let source):
                sourcesIndex = sourcesIndex ?? index
                sources.append(source)
            default:
                continue
            }
        }
        if let sourcesIndex {
            items.append(Item(id: sourcesIndex, content: .sources(sources)))
        }
        return items
    }

    private struct Item: Identifiable {
        enum Content {
            case text(TextPart)
            case reasoning(ReasoningPart)
            case tool(ToolPart)
            case sources([SourceURLPart])
        }

        var id: Int
        var content: Content
    }
}
