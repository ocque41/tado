import SwiftUI
import SwiftData
import AppKit

@main
struct TadoApp: App {
    @State private var appState = AppState()
    @State private var terminalManager = TerminalManager()
    @State private var ipcBrokerInitialized = false
    // One zoom-state per WindowGroup. Lifted to the App so the View
    // menu's commands can target the main window's zoom directly;
    // each instance is observed inside the per-window root view it
    // gets handed to.
    @State private var mainZoom = WindowZoomState()
    @State private var notificationsZoom = WindowZoomState()
    @State private var domeZoom = WindowZoomState()
    @State private var crossRunBrowserZoom = WindowZoomState()

    // Owning a single ModelContainer (instead of letting the scene
    // modifier create one implicitly) lets migrations and
    // AppSettingsSync share the same store as the SwiftUI @Query
    // observers. Creating it in init() ensures bootstrap runs before
    // the first view queries the container.
    private let modelContainer: ModelContainer
    private let settingsSync: AppSettingsSync
    private let projectSync: ProjectSettingsSync
    private let runEventWatcher: RunEventWatcher

    init() {
        // Register Plus Jakarta Sans with Core Text before any view
        // asks for it. Safe to call from `init()`; only touches
        // `CTFontManager`, not SwiftUI state.
        Typography.registerFonts()

        StorageLocationManager.applyPendingMoveIfNeeded()
        StorageLocationManager.importLegacySwiftDataStoreIfNeeded()
        try? FileManager.default.createDirectory(
            at: StorageLocationManager.swiftDataStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let container: ModelContainer
        do {
            let schema = Schema([
                TodoItem.self, AppSettings.self, Project.self,
                Team.self, EternalRun.self, DispatchRun.self
            ])
            let configuration = ModelConfiguration(
                schema: schema,
                url: StorageLocationManager.swiftDataStoreURL
            )
            container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        self.modelContainer = container

        // Packet 1 bootstrap: migrations → ScopedConfig → SwiftData sync.
        // Order matters: migrations seed global.json from the existing
        // AppSettings row (if any), ScopedConfig loads it and starts
        // watching, then AppSettingsSync bridges two-way once both are
        // up. SwiftUI views see the same container and redraw when the
        // cache row refreshes.
        MainActor.assumeIsolated {
            MigrationRunner.run(context: ModelContext(container))
            ScopedConfig.shared.bootstrap()
            // Phase 4 — keep `DomeContextPreamble._contextPacksV2Override`
            // synced with the live `global.json` value. Bootstrap reads
            // the flag once; the `addOnChange` hook propagates Settings
            // UI toggles mid-session without an app restart.
            DomeContextPreamble._contextPacksV2Override.set(
                ScopedConfig.shared.get().dome.contextPacksV2
            )
            ScopedConfig.shared.addOnChange { scope in
                if case .global = scope {
                    DomeContextPreamble._contextPacksV2Override.set(
                        ScopedConfig.shared.get().dome.contextPacksV2
                    )
                }
            }
        }
        let sync = AppSettingsSync(container: container)
        self.settingsSync = sync
        let pSync = ProjectSettingsSync(container: container)
        self.projectSync = pSync
        let rew = RunEventWatcher(container: container)
        self.runEventWatcher = rew
        MainActor.assumeIsolated {
            sync.start()
            pSync.start()
            rew.start()
            // Event deliverers — subscribe once, fire for every
            // event the bus publishes thereafter. Order doesn't
            // matter (each deliverer is independent).
            SoundPlayer.shared.install()
            DockBadgeUpdater.shared.install()
            SystemNotifier.shared.install()
            // A6: real-time A2A socket at
            // `/tmp/tado-ipc-<pid>/events.sock`. Install before
            // `.systemAppLaunched` so that the boundary event
            // itself is on the firehose for any early subscriber.
            EventsSocketBridge.install()
            // Mark the session boundary for the event log. Useful
            // when paging through `events/current.ndjson` — you can
            // spot where one launch ended and the next began.
            EventBus.shared.publish(.systemAppLaunched())
        }

        // Fan out to every registered extension's `onAppLaunch` hook.
        // Detached so extensions that block (model downloads, daemon
        // boot, etc.) never stall the first-frame paint. Extensions are
        // expected to run their own MainActor hops for UI work.
        Task.detached(priority: .utility) {
            await ExtensionRegistry.runOnAppLaunchHooks()
        }

        // A7: register the Rust tado-mcp bridge with Claude Code if
        // it's installed. Independent of ExtensionRegistry because
        // tado-mcp isn't a UI extension — it's a stdio tool Claude
        // spawns on demand.
        TadoMcpAutoRegister.kickoff()

        // v0.15 — clean shutdown for the in-process bt-core daemon.
        // The Phase-2 stub `tado_dome_stop` is finally wired: when
        // the OS posts `willTerminateNotification`, we ask bt-core
        // to flush its WAL + close its socket cleanly. Without this
        // hook the daemon was just being torn down by the kernel,
        // leaving the WAL file at a non-checkpointed boundary on
        // every quit. `DomeRpcClient.domeStop` wraps the FFI shim
        // so TadoApp doesn't need to import CTadoCore directly.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            DomeRpcClient.domeStop()
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindowRoot(
                appState: appState,
                terminalManager: terminalManager,
                zoomState: mainZoom,
                ipcBrokerInitialized: $ipcBrokerInitialized
            )
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Settings") {
                    appState.showSettings.toggle()
                }
                .keyboardShortcut("m", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    appState.showSidebar.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)
            }
            CommandMenu("Navigate") {
                Button("Projects") {
                    appState.currentView = .projects
                }
                .keyboardShortcut("p", modifiers: .command)
            }
            CommandMenu("Lists") {
                Button("Done List") {
                    appState.showDoneList.toggle()
                }
                .keyboardShortcut("d", modifiers: .command)

                Button("Trash") {
                    appState.showTrashList.toggle()
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            CommandMenu("View") {
                // Menu fallback for app-zoom on the main window. The
                // Cmd-shortcut here is the same as the in-window
                // NSEvent monitor handles, so on non-canvas pages the
                // monitor consumes it before this fires; on the canvas
                // page the canvas's own keyMonitor consumes it for
                // tile-only zoom — which means the keyboard equivalent
                // never reaches this menu item, but a mouse click still
                // works to app-zoom while the canvas is visible.
                Button("Zoom In") {
                    withAnimation(.easeOut(duration: 0.06)) { mainZoom.zoomIn() }
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    withAnimation(.easeOut(duration: 0.06)) { mainZoom.zoomOut() }
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    withAnimation(.easeOut(duration: 0.06)) { mainZoom.reset() }
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        // Extension windows — one WindowGroup per registered extension.
        // SwiftUI's Scene composition can't iterate dynamic lists, so each
        // scene is wired explicitly. Adding an entry to
        // ExtensionRegistry.all requires a matching block here.
        WindowGroup(id: ExtensionWindowID.string(for: NotificationsExtension.manifest.id)) {
            NotificationsWindowRoot(appState: appState, zoomState: notificationsZoom)
        }
        .windowResizability(NotificationsExtension.manifest.windowResizable ? .contentMinSize : .contentSize)

        WindowGroup(id: ExtensionWindowID.string(for: DomeExtension.manifest.id)) {
            DomeWindowRoot(appState: appState, zoomState: domeZoom)
        }
        .modelContainer(modelContainer)
        .windowResizability(DomeExtension.manifest.windowResizable ? .contentMinSize : .contentSize)

        WindowGroup(id: ExtensionWindowID.string(for: CrossRunBrowserExtension.manifest.id)) {
            CrossRunBrowserWindowRoot(appState: appState, zoomState: crossRunBrowserZoom)
        }
        .modelContainer(modelContainer)
        .windowResizability(CrossRunBrowserExtension.manifest.windowResizable ? .contentMinSize : .contentSize)
    }
}

// MARK: - Per-window root views
//
// Each WindowGroup hands its content off to a small wrapper struct that
// owns the per-window zoom plumbing. SwiftUI's WindowGroup builder
// closure can't declare @State directly, so the wrappers exist purely to
// receive the lifted zoom-state and apply `.windowZoom(...)`. They also
// pin the per-window minimum frame size, lowered from each extension's
// `defaultWindowSize` to a much smaller floor so corner-drag-resize can
// shrink each window aggressively — content reflows via the
// browser-style scaler at any size between the floor and the screen.

struct MainWindowRoot: View {
    let appState: AppState
    let terminalManager: TerminalManager
    let zoomState: WindowZoomState
    @Binding var ipcBrokerInitialized: Bool

    var body: some View {
        ContentView()
            .environment(appState)
            .environment(terminalManager)
            // Pin the whole window tree to dark mode. Without this
            // SwiftUI's adaptive system colors (sidebar, form bg,
            // sheet chrome) sample the host's appearance — if macOS
            // is in light mode the sidebar would paint near-white
            // on top of our neutral #1A1A1A. Pinning dark scheme
            // ensures every child (including `.sheet()` presentations,
            // which spawn their own windows) reads from the same
            // darker system table.
            .preferredColorScheme(.dark)
            .frame(minWidth: 280, minHeight: 200)
            // Defer Cmd+/-/0 to the canvas's own keyMonitor while the
            // canvas page is visible so tile-only zoom keeps working
            // there; on every other page (Projects, Todos, Extensions)
            // the predicate is true and Cmd+/-/0 app-zooms the window.
            .windowZoom(zoomState, shouldIntercept: { appState.currentView != .canvas })
            .onAppear {
                if !ipcBrokerInitialized {
                    terminalManager.ipcBroker = IPCBroker(terminalManager: terminalManager)
                    ipcBrokerInitialized = true
                }
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first {
                        window.makeKeyAndOrderFront(nil)
                        window.orderFrontRegardless()
                    }
                }
            }
    }
}

struct NotificationsWindowRoot: View {
    let appState: AppState
    let zoomState: WindowZoomState

    var body: some View {
        NotificationsExtension.makeView()
            .environment(appState)
            .preferredColorScheme(.dark)
            .frame(minWidth: 240, minHeight: 180)
            .windowZoom(zoomState)
    }
}

struct DomeWindowRoot: View {
    let appState: AppState
    let zoomState: WindowZoomState

    var body: some View {
        DomeExtension.makeView()
            .environment(appState)
            .preferredColorScheme(.dark)
            .frame(minWidth: 240, minHeight: 180)
            .windowZoom(zoomState)
    }
}

struct CrossRunBrowserWindowRoot: View {
    let appState: AppState
    let zoomState: WindowZoomState

    var body: some View {
        CrossRunBrowserExtension.makeView()
            .environment(appState)
            .preferredColorScheme(.dark)
            .frame(minWidth: 240, minHeight: 180)
            .windowZoom(zoomState)
    }
}
