// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WatchGPTCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "WatchGPTCore", targets: ["WatchGPTCore"])
    ],
    targets: [
        .target(
            name: "WatchGPTCore",
            path: ".",
            exclude: [
                ".claude",
                ".github",
                "Tests",
                "WatchGPT",
                "WatchGPT.xcodeproj",
                "WatchGPTPhone/Config",
                "WatchGPTPhone/Info.plist",
                "WatchGPTPhone/Resources",
                "WatchGPTPhone/Services",
                "WatchGPTPhone/Support/KeychainStore.swift",
                "WatchGPTPhone/Support/PhoneConfiguration.swift",
                "WatchGPTPhone/Views",
                "WatchGPTPhone/WatchGPTPhoneApp.swift",
                "Shared/LiquidGlass.swift",
                "docs",
                "scripts",
                "CLAUDE.md",
                "LICENSE",
                "Mintfile",
                "README.md",
                "SECURITY.md",
                "icon-watch.png",
                "icon.png",
                "package.json",
                "project.yml"
            ],
            sources: [
                "Shared/AudioSupport.swift",
                "Shared/RealtimeMessages.swift",
                "Shared/RealtimeTransport.swift",
                "WatchGPTPhone/Support/OpenAIParsing.swift",
                "WatchGPTPhone/Support/TranscriptModels.swift",
                "WatchGPTPhone/Support/TranscriptStore.swift"
            ]
        ),
        .testTarget(
            name: "WatchGPTCoreTests",
            dependencies: ["WatchGPTCore"],
            path: "Tests/Logic"
        )
    ]
)
