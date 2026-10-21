// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChatCLI",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "ChatCLI",
            dependencies: [
                .product(name: "AIChat", package: "swift-ai-chat"),
                .product(name: "AIChatAnthropic", package: "swift-ai-chat"),
                .product(name: "AIChatOpenAI", package: "swift-ai-chat"),
            ]
        ),
    ]
)
