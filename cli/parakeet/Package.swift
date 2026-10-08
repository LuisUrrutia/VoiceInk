// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInkParakeet",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "voiceink-cli", targets: ["voiceink-cli"])],
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
    ],
    swiftLanguageModes: [.v5]
)
