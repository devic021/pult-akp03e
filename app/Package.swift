// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pult",
    // Liquid Glass is a macOS 26 API, and the look is the point.
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Pult",
            path: "Sources/Pult",
            // The app is a single-window SwiftUI front end over a local socket;
            // strict concurrency buys nothing here and costs a lot of noise.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
