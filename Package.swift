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
        .target(
            name: "CTadoCore",
            path: "Sources/CTadoCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Tado",
            dependencies: ["SwiftTerm", "CTadoCore"],
            path: "Sources/Tado",
            linkerSettings: [
                // Link the Rust static library. `make core` builds it at
                // `tado-core/target/release/libtado_core.a` before `swift build`.
                .unsafeFlags([
                    "-L", "tado-core/target/release",
                    "-ltado_core"
                ]),
                // portable-pty + Rust std require these frameworks/libraries on macOS.
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedLibrary("resolv"),
                .linkedLibrary("iconv")
            ]
        ),
        .testTarget(
            name: "TadoCoreTests",
            dependencies: ["Tado"],
            path: "Tests/TadoCoreTests"
        )
    ]
)
