// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tado",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Tado",
            dependencies: ["SwiftTerm"],
            path: "Sources/Tado"
        )
    ]
)
