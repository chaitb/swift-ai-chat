// swift-tools-version: 6.0
import AppleProductTypes
import PackageDescription

let package = Package(
    name: "ChatDemo",
    platforms: [.iOS("26.0")],
    products: [
        .iOSApplication(
            name: "ChatDemo",
            targets: ["ChatDemo"],
            bundleIdentifier: "dev.swiftaichat.ChatDemo",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .chatMessage),
            accentColor: .presetColor(.indigo),
            supportedDeviceFamilies: [.phone, .pad],
            supportedInterfaceOrientations: [.portrait, .landscapeRight, .landscapeLeft, .portraitUpsideDown(.when(deviceFamilies: [.pad]))]
        ),
    ],
    dependencies: [.package(name: "swift-ai-chat", path: "../../..")],
    targets: [
        .executableTarget(
            name: "ChatDemo",
            dependencies: [
                .product(name: "AIChat", package: "swift-ai-chat"),
                .product(name: "AIChatAnthropic", package: "swift-ai-chat"),
                .product(name: "AIChatOpenAI", package: "swift-ai-chat"),
            ],
            path: "Sources"
        ),
    ],
    swiftLanguageModes: [.v6]
)
