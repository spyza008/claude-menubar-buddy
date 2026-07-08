// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeMenuBarBuddy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeMenuBarBuddy",
            path: "Sources/ClaudeMenuBarBuddy",
            resources: [
                .copy("Resources/buddy_idle.gif"),
                .copy("Resources/buddy_pending.gif")
            ]
        )
    ]
)
