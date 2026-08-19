// swift-tools-version:5.7
import PackageDescription

// The Swift Package Manager distribution of the Amwal ECR SDK.
//
// The same sources are published to CocoaPods from the AmwalECR-iOS-CocoaPods
// repository, and consumed by the Flutter plugin `amwal_ecr` — one
// implementation of the wire protocol, three ways to depend on it.
//
// SwiftPM resolves versions from this repository's tags and reads only plain
// semantic-version tags, so a release is tagged `vX.Y.Z`.
let package = Package(
    name: "AmwalECR",
    platforms: [
        // The wrapper's floor, not the protocol's. Raise it here and in the
        // CocoaPods repository's AmwalECR.podspec together.
        .iOS(.v12),
        // macOS is here so `swift test` runs the wire-format and rounding tests
        // on a plain Mac, with no simulator. Nothing in the SDK is iOS-only.
        .macOS(.v12),
    ],
    products: [
        .library(name: "AmwalECR", targets: ["AmwalECR"]),
    ],
    targets: [
        // Foundation and Darwin only: no third-party dependency, and nothing
        // that would drag a Flutter engine into a native app.
        .target(name: "AmwalECR"),
        .testTarget(name: "AmwalECRTests", dependencies: ["AmwalECR"]),
    ]
)
