// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInkParakeet",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "voiceink-cli", targets: ["voiceink-cli"]),
        .executable(name: "voiceink-vocab-eval", targets: ["voiceink-vocab-eval"]),
    ],
    dependencies: [
        .package(url: "git@github.com:FluidInference/FluidAudio.git",
                 revision: "6f7938938f1580d1abee28dd980b5f79da5f794c"),
    ],
    targets: [
        .target(name: "TranscriptionText"),
        .target(name: "ParakeetCLI", dependencies: [
            "TranscriptionText", .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .executableTarget(name: "voiceink-cli", dependencies: ["ParakeetCLI"]),
        .executableTarget(name: "voiceink-vocab-eval", dependencies: ["ParakeetCLI"]),
        .testTarget(name: "ParakeetCLITests", dependencies: ["ParakeetCLI", "TranscriptionText"]),
    ],
    swiftLanguageModes: [.v5]
)
