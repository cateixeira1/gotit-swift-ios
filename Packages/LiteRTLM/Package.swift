// swift-tools-version: 5.9
// The Swift wrapper of Google AI Edge's LiteRT-LM, vendored unchanged from tag v0.19.1
// (https://github.com/google-ai-edge/LiteRT-LM, Apache 2.0, see LICENSE), with its prebuilt iOS
// framework from the same release. Vendored so that building the app does not clone the whole
// LiteRT-LM repository (and its Git LFS binaries), and so the Linux build of the core never sees
// a binary target. Only the iOS app depends on it.
import PackageDescription

let package = Package(
    name: "LiteRTLM",
    platforms: [.iOS(.v15)],
    products: [.library(name: "LiteRTLM", targets: ["LiteRTLM"])],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.19.1/CLiteRTLM.xcframework.zip",
            checksum: "21cf294b3dfdd9c8166b0f7934ed392d5c69c8bfa57cd1a20e341a7d16874017"
        ),
        .target(name: "LiteRTLM", dependencies: ["CLiteRTLM"], path: "Sources/LiteRTLM"),
    ]
)
