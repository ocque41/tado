import Foundation

/// Compile-time registry of every extension bundled into the Tado `.app`.
///
/// Adding an extension: create
/// `Sources/Tado/Extensions/<id>/<Name>Extension.swift` conforming to
/// ``AppExtension``, add the type to ``all``, and add a matching
/// `WindowGroup(id: ExtensionWindowID.string(for:))` scene to
/// `TadoApp.body`.
///
/// ## T5 status
///
/// Empty registry. Infrastructure is in place so future phases (T6
/// migrates Eternal / Dispatch / Notifications out of core and into
/// extensions) can drop new types in without having to stand up the
/// protocol first.
public enum ExtensionRegistry {
    public static let all: [any AppExtension.Type] = [
        NotificationsExtension.self,
        DomeExtension.self,
        CrossRunBrowserExtension.self,
    ]

    public static func type(for id: String) -> (any AppExtension.Type)? {
        all.first { $0.manifest.id == id }
    }

    public static func manifest(for id: String) -> ExtensionManifest? {
        type(for: id)?.manifest
    }

    /// Fan-out hook called once at app launch so each extension can
    /// do its one-time setup. Executed concurrently.
    public static func runOnAppLaunchHooks() async {
        await withTaskGroup(of: Void.self) { group in
            for ext in all {
                group.addTask { await ext.onAppLaunch() }
            }
        }
    }
}
