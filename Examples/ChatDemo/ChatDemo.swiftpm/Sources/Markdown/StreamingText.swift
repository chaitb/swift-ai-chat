import SwiftUI

struct ArrivalAttribute: TextAttribute {
    var time: TimeInterval
}

struct CaretAttribute: TextAttribute {}

@MainActor
final class ArrivalTracker {
    private struct Mark {
        var end: Int
        var time: TimeInterval
    }

    private var marks: [Mark] = []
    private var plain = ""
    private(set) var lastArrival: TimeInterval = 0

    nonisolated static let fadeDuration: TimeInterval = 0.55

    func segments(for content: AttributedString, streaming: Bool) -> [(AttributedString, TimeInterval?)] {
        let now = Date.timeIntervalSinceReferenceDate
        let newPlain = String(content.characters)
        if newPlain != plain {
            let common = newPlain.commonPrefix(with: plain).count
            marks = marks.compactMap { mark in
                guard mark.end > 0 else { return nil }
                return Mark(end: min(mark.end, common), time: mark.time)
            }
            while let last = marks.last, marks.count > 1, last.end <= marks[marks.count - 2].end { marks.removeLast() }
            let count = newPlain.count
            if count > (marks.last?.end ?? 0) {
                let isFirst = plain.isEmpty && marks.isEmpty
                let time = streaming || (!isFirst && now - lastArrival < 2) ? now : -.infinity
                marks.append(Mark(end: count, time: time))
                if time.isFinite { lastArrival = now }
            }
            plain = newPlain
        }
        coalesce(before: now - Self.fadeDuration - 0.4)
        var result: [(AttributedString, TimeInterval?)] = []
        var start = 0
        for mark in marks where mark.end > start {
            let lower = content.characters.index(content.startIndex, offsetBy: start)
            let upper = content.characters.index(content.startIndex, offsetBy: mark.end)
            result.append((AttributedString(content[lower..<upper]), mark.time.isFinite ? mark.time : nil))
            start = mark.end
        }
        return result
    }

    private func coalesce(before cutoff: TimeInterval) {
        guard let index = marks.lastIndex(where: { $0.time < cutoff }), index > 0 else {
            if let first = marks.first, first.time < cutoff { marks[0].time = -.infinity }
            return
        }
        let end = marks[index].end
        marks.removeFirst(index + 1)
        marks.insert(Mark(end: end, time: -.infinity), at: 0)
    }
}

struct FrameSchedule: TimelineSchedule {
    var end: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
        let step: TimeInterval = mode == .lowFrequency ? 1 : 1.0 / 60
        let end = end
        return sequence(first: startDate) { date in
            let next = date.addingTimeInterval(step)
            return next <= end ? next : nil
        }
    }
}

struct StreamRenderer: TextRenderer {
    var now: TimeInterval
    var reduceMotion: Bool

    var displayPadding: EdgeInsets { EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[CaretAttribute.self] != nil {
                    var caret = context
                    let phase = (sin(now * 5) + 1) / 2
                    caret.opacity = reduceMotion ? 0.6 : 0.25 + 0.6 * phase
                    caret.draw(run)
                    continue
                }
                guard let arrival = run[ArrivalAttribute.self] else {
                    context.draw(run)
                    continue
                }
                let duration = reduceMotion ? 0.25 : ArrivalTracker.fadeDuration
                let runProgress = min(max((now - arrival.time) / duration, 0), 1)
                if runProgress >= 1 && reduceMotion {
                    context.draw(run)
                    continue
                }
                var runContext = context
                let runEased = 1 - pow(1 - runProgress, 3)
                if !reduceMotion && runEased < 0.85 {
                    runContext.addFilter(.blur(radius: (1 - runEased) * 5))
                }
                for (index, slice) in run.enumerated() {
                    let delay = reduceMotion ? 0 : Double(index) * 0.012
                    let progress = min(max((now - arrival.time - delay) / duration, 0), 1)
                    if progress >= 1 {
                        runContext.draw(slice)
                        continue
                    }
                    let eased = 1 - pow(1 - progress, 3)
                    var glyph = runContext
                    glyph.opacity = eased
                    if !reduceMotion {
                        glyph.translateBy(x: 0, y: (1 - eased) * 4)
                    }
                    glyph.draw(slice)
                }
            }
        }
    }
}

struct StreamingText: View {
    var content: AttributedString
    var isStreaming: Bool
    var showsCaret: Bool

    @State private var tracker = ArrivalTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let segments = tracker.segments(for: content, streaming: isStreaming)
        let caret = isStreaming && showsCaret
        let settleEnd = caret && !reduceMotion ? Date.distantFuture : Date(timeIntervalSinceReferenceDate: tracker.lastArrival + ArrivalTracker.fadeDuration + 0.4)
        TimelineView(FrameSchedule(end: settleEnd)) { timeline in
            composed(segments, caret: caret)
                .textRenderer(StreamRenderer(now: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion))
                .accessibilityLabel(Text(content))
        }
    }

    private func composed(_ segments: [(AttributedString, TimeInterval?)], caret: Bool) -> Text {
        var text = Text(verbatim: "")
        for (segment, time) in segments {
            let piece = time.map { Text(segment).customAttribute(ArrivalAttribute(time: $0)) } ?? Text(segment)
            text = Text("\(text)\(piece)")
        }
        if caret {
            let mark = Text(Image(systemName: "circle.fill")).font(.system(size: 9)).foregroundStyle(.tint).baselineOffset(1).customAttribute(CaretAttribute())
            text = Text("\(text)\u{2009}\(mark)")
        }
        return text
    }
}
