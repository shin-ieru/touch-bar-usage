// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TouchBarUsage",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure-logic, testable core. Deliberately free of AppKit and of any
        // private-API knowledge so it runs headless in CI.
        .target(name: "TouchBarUsageKit"),

        // The app: AppKit UI plus the narrow private Touch Bar bridge.
        .executableTarget(
            name: "TouchBarUsage",
            dependencies: ["TouchBarUsageKit"],
            resources: [.process("Resources")]
        ),

        .testTarget(
            name: "TouchBarUsageKitTests",
            dependencies: ["TouchBarUsageKit"],
            resources: [.process("Fixtures")]
        ),
    ]
)
