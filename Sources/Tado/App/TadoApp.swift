import SwiftUI
import SwiftData
import AppKit

@main
struct TadoApp: App {
    @State private var appState = AppState()
    @State private var terminalManager = TerminalManager()
    @State private var ipcBrokerInitialized = false

    init() {
        // Register Plus Jakarta Sans with Core Text before any view
        // asks for it. Safe to call from `init()`; only touches
        // `CTFontManager`, not SwiftUI state.
        Typography.registerFonts()
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
        .modelContainer(for: [TodoItem.self, AppSettings.self, Project.self, Team.self])
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

                Button("Teams") {
                    appState.currentView = .teams
                }
                .keyboardShortcut("e", modifiers: .command)
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
