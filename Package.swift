// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Airflow",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Airflow", targets: ["Airflow"]),
    ],
    targets: [
        // Pure logic: config, hotkey state machine, text processing, prompts, Claude client, history.
        .target(
            name: "AirflowCore",
            path: "Sources/AirflowCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The macOS menu-bar app: audio, speech engines, event tap, UI.
        .executableTarget(
            name: "Airflow",
            dependencies: ["AirflowCore"],
            path: "Sources/Airflow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Unit checks for AirflowCore: `swift run airflow-checks`.
        // A plain executable rather than a test target because the Command Line Tools
        // don't ship working XCTest / swift-testing macro plugins (full Xcode does).
        .executableTarget(
            name: "airflow-checks",
            dependencies: ["AirflowCore"],
            path: "Tests/AirflowChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
