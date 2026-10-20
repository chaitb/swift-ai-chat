// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "swift-ai-chat",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AIChat", targets: ["AIChat"]),
        .library(name: "AIChatAnthropic", targets: ["AIChatAnthropic"]),
        .library(name: "AIChatOpenAI", targets: ["AIChatOpenAI"]),
        .library(name: "AIChatTesting", targets: ["AIChatTesting"]),
    ],
    targets: [
        .target(name: "AIChat", swiftSettings: swiftSettings),
        .target(name: "AIChatAnthropic", dependencies: ["AIChat"], swiftSettings: swiftSettings),
        .target(name: "AIChatOpenAI", dependencies: ["AIChat"], swiftSettings: swiftSettings),
        .target(name: "AIChatTesting", dependencies: ["AIChat"], swiftSettings: swiftSettings),
        .testTarget(
            name: "AIChatTests",
            dependencies: ["AIChat", "AIChatTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AIChatAnthropicTests",
            dependencies: ["AIChat", "AIChatAnthropic", "AIChatTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AIChatOpenAITests",
            dependencies: ["AIChat", "AIChatOpenAI", "AIChatTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
