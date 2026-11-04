import AIChat
import SwiftUI

struct WeatherCard: View {
    var part: ToolPart

    @Environment(\.colorScheme) private var colorScheme

    private var report: WeatherReport? {
        guard part.state == .outputAvailable else { return nil }
        return try? part.decodeOutput(WeatherReport.self)
    }

    private var city: String {
        part.input?["city"]?.stringValue ?? "your city"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let report {
                details(report)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .opacity
                    ))
            }
        }
        .foregroundStyle(report == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(report == nil ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(sky(report)))
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .animation(.spring(duration: 0.55, bounce: 0.18), value: report)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ToolStatusIcon(state: part.state, idleSymbol: "cloud.sun", onTint: report != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text("get_weather")
                    .font(.caption.monospaced())
                    .opacity(0.7)
                Text(status)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.opacity)
                    .shimmer(part.isRunning)
            }
            Spacer()
        }
        .padding(14)
    }

    private var status: String {
        switch part.state {
        case .inputStreaming: "Preparing request"
        case .inputAvailable: "Checking \(city)"
        case .outputAvailable: report?.city ?? city
        case .outputError: part.errorText ?? "The forecast didn't load"
        default: city
        }
    }

    private func details(_ report: WeatherReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Text("\(report.temperature)°")
                    .font(.system(size: 64, weight: .thin, design: .rounded))
                    .contentTransition(.numericText(value: Double(report.temperature)))
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: report.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 34))
                    Text(report.condition)
                        .font(.subheadline.weight(.medium))
                    Text("H:\(report.high)°  L:\(report.low)°")
                        .font(.caption)
                        .opacity(0.8)
                }
            }
            HStack {
                ForEach(report.hourly, id: \.hour) { hour in
                    VStack(spacing: 6) {
                        Text(hour.hour).font(.caption2.weight(.medium)).opacity(0.8)
                        Image(systemName: hour.symbol).symbolRenderingMode(.multicolor).font(.callout)
                        Text("\(hour.temperature)°").font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 10)
            .background(.white.opacity(0.14), in: .rect(cornerRadius: 14, style: .continuous))
        }
        .padding([.horizontal, .bottom], 16)
    }

    private func sky(_ report: WeatherReport?) -> LinearGradient {
        let rainy = report?.condition.lowercased().contains("rain") == true
        let top: Color = rainy ? Color(red: 0.36, green: 0.45, blue: 0.56) : Color(red: 0.25, green: 0.55, blue: 0.92)
        let bottom: Color = rainy ? Color(red: 0.22, green: 0.29, blue: 0.38) : Color(red: 0.42, green: 0.71, blue: 0.98)
        let dim = colorScheme == .dark ? 0.78 : 1
        return LinearGradient(colors: [top.opacity(dim), bottom.opacity(dim)], startPoint: .top, endPoint: .bottom)
    }
}
