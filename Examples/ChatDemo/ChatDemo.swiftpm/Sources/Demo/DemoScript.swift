import AIChat
import Foundation

enum DemoScript {
    static func beats(for messages: [UIMessage], continuing messageID: String? = nil) -> [DemoBeat] {
        if let messageID, let target = messages.last(where: { $0.id == messageID }), target.role == .assistant {
            return continuation(after: target)
        }
        guard let last = messages.last else { return reply(intro) }
        if last.role == .assistant {
            return continuation(after: last)
        }
        switch Showcase.match(last.text) {
        case .weather: return weather(city: city(in: last.text)?.capitalized ?? "Lisbon")
        case .reasoning: return reasoning
        case .approval: return booking
        case .sources: return sources
        case .markdown: return reply(markdown)
        case nil: return reply(intro)
        }
    }

    private static func continuation(after message: UIMessage) -> [DemoBeat] {
        let tools = message.lastStepParts.compactMap(\.toolPart)
        if let weather = tools.last(where: { $0.toolName == DemoTools.weatherName }) {
            guard weather.state == .outputAvailable, let report = try? weather.decodeOutput(WeatherReport.self) else {
                return reply("I couldn't reach the weather service. Try again in a moment.")
            }
            return reply(weatherSummary(report), latency: 250...500)
        }
        if let booking = tools.last(where: { $0.toolName == DemoTools.bookingName && $0.state == .approvalResponded }) {
            if booking.approval?.approved == true {
                let output: JSONValue = ["confirmation": "NP-4821", "restaurant": "Nopa", "partySize": 2, "time": "Friday, 7:30 PM"]
                return [
                    .chunk(.start()),
                    .wait(500...800),
                    .chunk(.toolOutputAvailable(ToolOutputAvailableChunk(toolCallId: booking.toolCallId, output: output))),
                    .wait(250...450),
                    .chunk(.startStep),
                    .text(id: id(), bookingConfirmed),
                    .chunk(.finishStep),
                    .chunk(.finish(finishReason: .stop)),
                ]
            }
            return [
                .chunk(.start()),
                .wait(200...400),
                .chunk(.toolOutputDenied(toolCallId: booking.toolCallId)),
                .chunk(.startStep),
                .text(id: id(), "No problem, I didn't book anything. Want me to look for a different time or another spot nearby?"),
                .chunk(.finishStep),
                .chunk(.finish(finishReason: .stop)),
            ]
        }
        return reply("Done.")
    }

    private static func reply(_ text: String, latency: ClosedRange<Int> = 450...900) -> [DemoBeat] {
        [
            .chunk(.start()),
            .wait(latency),
            .chunk(.startStep),
            .text(id: id(), text),
            .chunk(.finishStep),
            .chunk(.finish(finishReason: .stop)),
        ]
    }

    private static func weather(city: String) -> [DemoBeat] {
        let callID = "call_" + ChatID.generate()
        return [
            .chunk(.start()),
            .wait(400...700),
            .chunk(.startStep),
            .text(id: id(), "Let me check the forecast for **\(city)**."),
            .wait(150...300),
            .toolInput(callID: callID, name: DemoTools.weatherName, input: ["city": .string(city)]),
            .chunk(.finishStep),
            .chunk(.finish(finishReason: .toolCalls)),
        ]
    }

    private static var reasoning: [DemoBeat] {
        [
            .chunk(.start()),
            .wait(350...600),
            .chunk(.startStep),
            .reasoning(id: id(), """
            A relaxed weekend means fewer sights and more time in each. Kyoto's big temples get crowded after 9 AM, so the early slots should go to Fushimi Inari and Kiyomizu-dera. \
            Arashiyama works best on the second morning, before the tour buses. Afternoons can stay loose: tea in Gion, a long lunch, the Philosopher's Path. \
            I'll keep it to two or three anchors per day and leave the evenings open.
            """),
            .wait(200...400),
            .text(id: id(), kyotoPlan),
            .chunk(.finishStep),
            .chunk(.finish(finishReason: .stop)),
        ]
    }

    private static var booking: [DemoBeat] {
        let callID = "call_" + ChatID.generate()
        let input: JSONValue = ["restaurant": "Nopa", "partySize": 2, "date": "Friday", "time": "7:30 PM"]
        return [
            .chunk(.start()),
            .wait(450...800),
            .chunk(.startStep),
            .text(id: id(), "Nopa has a table for two on **Friday at 7:30 PM**. I'll book it as soon as you confirm."),
            .wait(150...300),
            .toolInput(callID: callID, name: DemoTools.bookingName, input: input),
            .wait(150...250),
            .chunk(.toolApprovalRequest(ToolApprovalRequestChunk(approvalId: "approval_" + ChatID.generate(), toolCallId: callID))),
            .chunk(.finishStep),
            .chunk(.finish(finishReason: .toolCalls)),
        ]
    }

    private static var sources: [DemoBeat] {
        let links: [(String, String)] = [
            ("https://www.swift.org/blog/", "Swift.org blog"),
            ("https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md", "SE-0466: Default actor isolation"),
            ("https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md", "SE-0461: Nonisolated async functions"),
        ]
        var beats: [DemoBeat] = [
            .chunk(.start()),
            .wait(500...900),
            .chunk(.startStep),
            .text(id: id(), swiftConcurrency),
        ]
        for (index, link) in links.enumerated() {
            beats.append(.wait(90...180))
            beats.append(.chunk(.sourceURL(SourceURLPart(sourceId: "src-\(index + 1)", url: link.0, title: link.1))))
        }
        beats += [.chunk(.finishStep), .chunk(.finish(finishReason: .stop))]
        return beats
    }

    private static func city(in text: String) -> String? {
        let skipped: Set<String> = ["the", "a", "an", "this", "that", "my", "our", "today", "tonight", "tomorrow", "now", "morning", "afternoon", "evening", "night", "weekend", "all", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        for match in text.matches(of: /\b(?i:in|for|at)\s+(\p{L}+(?:\s+\p{Lu}\p{L}+)?)/).reversed() {
            let city = String(match.1)
            let first = city.split(separator: " ").first.map { $0.lowercased() } ?? ""
            if !skipped.contains(first) { return city }
        }
        return nil
    }

    private static func id() -> String { "part_" + ChatID.generate() }

    private static func weatherSummary(_ report: WeatherReport) -> String {
        let advice = report.condition.contains("rain")
            ? "Pack an umbrella; the rain eases off later in the afternoon."
            : "Great weather for a walk. Take a light layer for the evening."
        return """
        It's **\(report.temperature)°** and \(report.condition.lowercased()) in \(report.city), with a high of \(report.high)° and a low of \(report.low)°.

        - Humidity is around \(report.humidity)% with a \(report.wind) km/\u{2060}h breeze.
        - \(advice)
        """
    }

    private static let bookingConfirmed = """
    You're booked. **Nopa, Friday at 7:30 PM**, table for two.

    Your confirmation code is `NP-4821`. I'll remind you an hour before.
    """

    private static let kyotoPlan = """
    ## A slow weekend in Kyoto

    **Saturday**
    1. **Fushimi Inari** at 7 AM, before the crowds. Walk up to the Yotsutsuji viewpoint.
    2. Late breakfast at **Nishiki Market**.
    3. Afternoon in **Gion**: tea, a nap, and a stroll down Hanamikoji at dusk.

    **Sunday**
    1. **Arashiyama** bamboo grove at 8 AM, then the Okochi Sanso garden.
    2. Lunch by the river, then the **Philosopher's Path** at your own pace.

    > Keep evenings free. Kyoto is best when you wander into a side street with no plan.
    """

    private static let swiftConcurrency = """
    Swift 6.2 made concurrency much more approachable:

    - **Default actor isolation.** A module can opt into running code on the main actor by default, which removes most annotations in app code [2].
    - **`nonisolated(nonsending)` by default.** Async functions now run on the caller's actor unless marked `@concurrent`, so fewer values have to be `Sendable` [3].
    - **Approachable concurrency** bundles these as upcoming features you can turn on per target [1].

    The short version: write single-threaded code first, and reach for `@concurrent` only where you want real parallelism.
    """

    private static let markdown = """
    # Markdown, rendered natively

    Text can be **bold**, *italic*, ~~struck~~, or `inline code`, and links like [swift.org](https://www.swift.org) are tappable.

    ## Lists
    - Bulleted items with **emphasis**
    - Streaming-friendly: each block renders as it arrives
    - No web views and no dependencies

    1. Numbered lists
    2. Keep their numbers

    ## Code
    ```swift
    let chat = Chat(transport: DemoTransport())
    await chat.sendMessage("Hello!")
    ```

    > Quotes get a soft rule on the leading edge.

    ---

    That's every block type this renderer knows.
    """

    private static let intro = """
    I'm a scripted assistant that runs **fully offline**, built from the same `UIMessageChunk`s a real model streams.

    Try one of these:
    - **Weather** to see a client tool render a card
    - **Plan a trip** to watch reasoning stream first
    - **Book a table** for an approval card
    - **Swift news** for cited sources
    - **Markdown** for every block type

    Add an Anthropic or OpenAI key in Settings to talk to a real model.
    """
}
