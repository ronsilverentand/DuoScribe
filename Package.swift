// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DuoScribe",
    platforms: [
        .macOS("14.2"), // Core Audio taps (system audio capture) need 14.2
    ],
    dependencies: [
        // WhisperKit: Whisper speech-to-text running locally through Core ML.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "DuoScribe",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/DuoScribe"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
