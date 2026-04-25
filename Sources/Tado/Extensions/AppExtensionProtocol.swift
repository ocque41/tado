import SwiftUI

/// An **extension** is a self-contained feature bundled into the Tado
/// app binary. Each extension appears as a card in the Extensions
/// surface and opens in its own independent window (peer of the main
/// canvas window, not a sheet).
///
/// Extensions are declared at compile time by adding a new type that
/// conforms to `AppExtension` and registering it in ``ExtensionRegistry``.
/// v0 does not support dynamic (user-installable) extensions.
///
/// ## Contract parity with Dome
///
/// This protocol is intentionally identical to Dome's
/// `Sources/Terminal/Extensions/AppExtensionProtocol.swift`. Keeping
/// the two shapes in lockstep means a bundled extension can be
/// ported between apps with minimal edits when that ever matters,
/// and a future `tado-extensions` Rust crate can share manifest
/// schema with Dome's side without translation.
///
/// ## Why not wire `makeView()` yet
///
/// The type exists so later phases can land real extensions without
/// having to stand up the protocol at the same time. DomeApp wires
/// one `WindowGroup` per registered extension; TadoApp will follow
/// the same pattern when the first extension actually ships.
public protocol AppExtension {
    static var manifest: ExtensionManifest { get }

    @MainActor @ViewBuilder
    static func makeView() -> AnyView

    /// Optional one-time setup; default is a no-op.
    static func onAppLaunch() async
}

public extension AppExtension {
    static func onAppLaunch() async {}
}

/// Plain-data manifest for an extension. Codable so the shape stays
/// stable whether embedded in the binary, serialized to JSON, or
/// exchanged over IPC in a future dynamic-loading world.
public struct ExtensionManifest: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let shortDescription: String
    public let iconSystemName: String
    public let version: String
    public let defaultWindowSize: Size
    public let windowResizable: Bool

    public init(
        id: String,
        displayName: String,
        shortDescription: String,
        iconSystemName: String,
        version: String,
        defaultWindowSize: Size,
        windowResizable: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.shortDescription = shortDescription
        self.iconSystemName = iconSystemName
        self.version = version
        self.defaultWindowSize = defaultWindowSize
        self.windowResizable = windowResizable
    }

    public struct Size: Codable, Hashable, Sendable {
        public let width: Double
        public let height: Double
        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
        public var cgSize: CGSize { CGSize(width: width, height: height) }
    }
}

/// Stable window id namespace. Each extension gets
/// `"ext-\(manifest.id)"` as its SwiftUI scene id.
public enum ExtensionWindowID {
    public static func string(for id: String) -> String { "ext-\(id)" }
}
