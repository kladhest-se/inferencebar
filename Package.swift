// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InferenceBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "InferenceBar", targets: ["InferenceBar"]),
        // Named "inference-cli", not "inference" or "InferenceBar": the
        // default macOS volume format is case-insensitive, so a product
        // differing from "InferenceBar" only by case would land in the
        // same .build/release/ entry as the app's own binary, silently
        // clobbering whichever one built second. `make install-cli`
        // installs this one on PATH as plain "inference".
        .executable(name: "inference-cli", targets: ["InferenceBarCLI"]),
    ],
    targets: [
        .executableTarget(
            name: "InferenceBar",
            path: "Sources/InferenceBar"
        ),
        .executableTarget(
            name: "InferenceBarCLI",
            path: "Sources/InferenceBarCLI"
        ),
        .testTarget(
            name: "InferenceBarTests",
            dependencies: ["InferenceBar"]
        ),
        .testTarget(
            name: "InferenceBarCLITests",
            dependencies: ["InferenceBarCLI"]
        ),
    ]
)
