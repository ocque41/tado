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
            // Quarantine path for in-flight WIP files — author renames
            // a partial-extension file to `.swift.wip` to keep it on
            // disk without dragging the whole package out of compile.
            // Once the WIP merges or gets dropped, the rename comes off
            // and SwiftPM picks it up again.
            exclude: [
                "Extensions/Pets/PetsCoordinator+Companion.swift.wip",
                "Extensions/Pets/PetsCoordinator+Settings.swift.wip"
            ],
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
        // Tado Use bridge — stdio MCP server that proxies the six
        // in-process tool calls into the running Tado app's
        // ControlSocketServer. Foundation-only, no SwiftUI / AppKit /
        // SwiftData / Rust deps so it stays a tiny standalone binary.
        // Bundled at `Tado.app/Contents/MacOS/tado-use-bridge` next to
        // the Rust `tado-mcp` and `dome-mcp` binaries.
        .executableTarget(
            name: "tado-use-bridge",
            path: "Sources/TadoUseBridge"
        ),
        .testTarget(
            name: "TadoCoreTests",
            dependencies: ["Tado"],
            path: "Tests/TadoCoreTests"
        )
    ]
)
