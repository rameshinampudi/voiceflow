// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceFlow",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "VoiceFlow", targets: ["VoiceFlow"]),
    ],
    targets: [
        // Pure logic: config, hotkey state machine, text processing, prompts, Claude client, history.
        .target(
            name: "VoiceFlowCore",
            path: "Sources/VoiceFlowCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The macOS menu-bar app: audio, speech engines, event tap, UI.
        .executableTarget(
            name: "VoiceFlow",
            dependencies: ["VoiceFlowCore"],
            path: "Sources/VoiceFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Unit checks for VoiceFlowCore: `swift run voiceflow-checks`.
        // A plain executable rather than a test target because the Command Line Tools
        // don't ship working XCTest / swift-testing macro plugins (full Xcode does).
        .executableTarget(
            name: "voiceflow-checks",
            dependencies: ["VoiceFlowCore"],
            path: "Tests/VoiceFlowChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
