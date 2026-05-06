// swift-tools-version:5.9
// Fixture project for perf-suite Swift adapter integration tests.
import PackageDescription

let package = Package(
    name: "FixtureSwift",
    targets: [
        .target(name: "FixtureSwift", path: "Sources/swift")
    ]
)
