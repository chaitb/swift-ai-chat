import AIChat
import Foundation

struct WeatherReport: Codable, Hashable, Sendable {
    struct Hour: Codable, Hashable, Sendable {
        var hour: String
        var temperature: Int
        var symbol: String
    }

    var city: String
    var temperature: Int
    var high: Int
    var low: Int
    var condition: String
    var symbol: String
    var humidity: Int
    var wind: Int
    var hourly: [Hour]
}

struct WeatherInput: Codable, Sendable {
    var city: String
}

enum DemoTools {
    static let weatherName = "get_weather"
    static let bookingName = "book_table"

    static let weather = ChatTool.typed(
        name: weatherName,
        description: "The current weather and a short hourly forecast for a city. Returns demo data.",
        inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]
    ) { (input: WeatherInput) async throws -> WeatherReport in
        try await Task.sleep(for: .milliseconds(Int.random(in: 1100...1600)))
        return report(for: input.city)
    }

    static func report(for city: String) -> WeatherReport {
        let presets: [(String, Int, String, String)] = [
            ("Partly cloudy", 18, "cloud.sun.fill", "cloud.sun.fill"),
            ("Sunny", 24, "sun.max.fill", "sun.max.fill"),
            ("Light rain", 12, "cloud.drizzle.fill", "cloud.rain.fill"),
            ("Clear", 21, "sun.max.fill", "moon.stars.fill"),
        ]
        let seed = city.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let preset = presets[seed % presets.count]
        let base = preset.1 + (seed % 5) - 2
        let hours = ["Now", "1 PM", "2 PM", "3 PM", "4 PM", "5 PM"]
        let hourly = hours.enumerated().map { index, label in
            WeatherReport.Hour(hour: label, temperature: base + [0, 1, 2, 2, 1, -1][index], symbol: index < 4 ? preset.2 : preset.3)
        }
        return WeatherReport(
            city: city.capitalized,
            temperature: base,
            high: base + 3,
            low: base - 6,
            condition: preset.0,
            symbol: preset.2,
            humidity: 40 + seed % 40,
            wind: 6 + seed % 18,
            hourly: hourly
        )
    }
}
