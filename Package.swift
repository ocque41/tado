// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tado",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CTadoCore",
            path: "Sources/CTadoCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Tado",
            dependencies: ["CTadoCore"],
            path: "Sources/Tado",
            resources: [
                // SwiftPM compiles .metal into a .metallib inside the
                // Tado_Tado.bundle. Loaded at runtime via Bundle.module.
                .process("Rendering/Shaders.metal"),
                // Plus Jakarta Sans — registered at app start via
                // `Typography.registerFonts()` and used by all UI chrome.
                // Terminal cells keep SF Mono (proportional fonts break
                // the grid).
                .copy("Resources/Fonts")
            ],
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
                .linkedLibrary("iconv"),
                // bt-core's `tokenizers` crate pulls in `esaxx_fast`,
                // which contains C++ TUs (`esaxx.o`) referencing
                // `__cxa_throw` / `__gxx_personality_v0`. Link the
                // C++ runtime so the Swift exec can resolve them.
                .linkedLibrary("c++")
            ]
        ),
        .testTarget(
            name: "TadoCoreTests",
            dependencies: ["Tado"],
            path: "Tests/TadoCoreTests"
        )
    ]
)
