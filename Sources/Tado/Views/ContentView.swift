import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @State private var eventMonitor: Any?

    var body: some View {
        ZStack {
            // All views stay alive — never destroyed/recreated.
            // Terminals keep running when switching views.
            CanvasView()
                .opacity(appState.currentView == .canvas ? 1 : 0)
                .allowsHitTesting(appState.currentView == .canvas)

            TodoListView()
                .opacity(appState.currentView == .todos ? 1 : 0)
                .allowsHitTesting(appState.currentView == .todos)

            ProjectsView()
                .opacity(appState.currentView == .projects ? 1 : 0)
                .allowsHitTesting(appState.currentView == .projects)

            TeamsView()
                .opacity(appState.currentView == .teams ? 1 : 0)
                .allowsHitTesting(appState.currentView == .teams)

            // Sidebar overlay
            if appState.showSidebar {
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: 260)
                        .transition(.move(edge: .leading))

                    Spacer()
                }
            }

            // Page navigation indicator
            VStack {
                Spacer()
                HStack {
                    pageNavigation
                        .padding(12)
                    Spacer()
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.currentView)
        .animation(.easeInOut(duration: 0.2), value: appState.showSidebar)
        .sheet(isPresented: Binding(
            get: { appState.showSettings },
            set: { appState.showSettings = $0 }
        )) {
            SettingsView()
        }
        .sheet(isPresented: Binding(
            get: { appState.showDoneList },
            set: { appState.showDoneList = $0 }
        )) {
            DoneListView()
        }
        .sheet(isPresented: Binding(
            get: { appState.showTrashList },
            set: { appState.showTrashList = $0 }
        )) {
            TrashListView()
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear { installKeyboardMonitor() }
        .onDisappear { removeKeyboardMonitor() }
        .task { reconnectOnLaunch() }
    }

    private var pageNavigation: some View {
        VStack(spacing: 4) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Button(action: { appState.currentView = mode }) {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10))
                        Text(mode.label)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(appState.currentView == mode ? Color.accentColor : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func installKeyboardMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ctrl+Tab: cycle through pages
            if event.keyCode == 48 && event.modifierFlags.contains(.control) {
                withAnimation {
                    let allCases = ViewMode.allCases
                    if let idx = allCases.firstIndex(of: appState.currentView) {
                        let next = allCases.index(after: idx)
                        appState.currentView = next < allCases.endIndex ? allCases[next] : allCases[allCases.startIndex]
                    }
                }
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func reconnectOnLaunch() {
        let todoDescriptor = FetchDescriptor<TodoItem>()
        guard let todos = try? modelContext.fetch(todoDescriptor) else { return }
        // Mark stale sessions as completed — the processes died when the app closed.
        // Do NOT re-spawn terminals; that would re-run CLI prompts and waste tokens.
        for todo in todos where !todo.isComplete && (todo.status == .running || todo.status == .needsInput) {
            todo.status = .completed
        }
        try? modelContext.save()
    }
}
