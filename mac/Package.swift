// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Stand",
    platforms: [.macOS("14.2")], // 14.2 for Core Audio process taps
    targets: [
        // What the app is made of: the voice model connection, everything it hears, the speakers, the project's text files.
        .target(name: "StandCore", path: "Sources/StandCore"),
        // The app. The same binary also runs `--probe` checks from the command line.
        .executableTarget(name: "Stand", dependencies: ["StandCore"], path: "Sources/Stand"),
    ]
)
