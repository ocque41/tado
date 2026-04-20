import SwiftUI
import SwiftData
import AppKit

@main
struct TadoApp: App {
    @State private var appState = AppState()
    @State private var terminalManager = TerminalManager()
    @State private var ipcBrokerInitialized = false

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

        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: TodoItem.self, AppSettings.self, Project.self,
                Team.self, EternalRun.self, DispatchRun.self
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
            // Mark the session boundary for the event log. Useful
            // when paging through `events/current.ndjson` — you can
            // spot where one launch ended and the next began.
            EventBus.shared.publish(.systemAppLaunched())
        }
    }

    var body: some Scene {
        WindowGroup {
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
        }
    }
}
