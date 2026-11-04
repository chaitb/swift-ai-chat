import AIChat
import SwiftUI

struct SourcesRow: View {
    var sources: [SourceURLPart]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sources", systemImage: "link")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(sources.enumerated()), id: \.element.sourceId) { index, source in
                        SourceChip(index: index + 1, source: source)
                            .transition(Motion.insertion(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)), reduced: reduceMotion))
                    }
                }
                .padding(.vertical, 2)
            }
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .padding(.horizontal, -18)
        }
        .animation(Motion.spring(0.45, bounce: 0.25, reduced: reduceMotion), value: sources.count)
    }
}

private struct SourceChip: View {
    var index: Int
    var source: SourceURLPart

    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 18

    private var host: String {
        URL(string: source.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? source.url
    }

    var body: some View {
        if let url = URL(string: source.url) {
            Link(destination: url) { chip }
                .buttonStyle(.plain)
        } else {
            chip
        }
    }

    private var chip: some View {
            HStack(spacing: 8) {
                Text("\(index)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(.tint, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title ?? host)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.fill.quaternary, in: .capsule)
    }
}
