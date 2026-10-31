// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInkParakeet",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "voiceink-cli", targets: ["voiceink-cli"]),
        .executable(name: "voiceink-history", targets: ["voiceink-history"]),
    ],
    dependencies: [
        .package(url: "git@github.com:FluidInference/FluidAudio.git",
                 revision: "762baf6733ca0f0dbeb1ce335363fc75066bd2c9"),
    ],
    targets: [
        .target(name: "TranscriptionText"),
        .target(name: "ParakeetCLI", dependencies: [
            "TranscriptionText", .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .executableTarget(name: "voiceink-cli", dependencies: ["ParakeetCLI"]),
        .testTarget(name: "ParakeetCLITests", dependencies: ["ParakeetCLI", "TranscriptionText"]),
        .target(name: "HistoryAccessCLI", dependencies: ["TranscriptionText"]),
        .executableTarget(name: "voiceink-history", dependencies: ["HistoryAccessCLI"]),
        .testTarget(name: "HistoryAccessCLITests", dependencies: ["HistoryAccessCLI", "TranscriptionText"]),
    ],
    swiftLanguageModes: [.v5]
)
