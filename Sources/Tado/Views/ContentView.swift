import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @State private var eventMonitor: Any?

    var body: some View {
        ZStack {
            // Both views stay alive — never destroyed/recreated.
            // Terminals keep running when switching to the todo list.
            CanvasView()
                .opacity(appState.currentView == .canvas ? 1 : 0)
                .allowsHitTesting(appState.currentView == .canvas)

            TodoListView()
                .opacity(appState.currentView == .todoList ? 1 : 0)
                .allowsHitTesting(appState.currentView == .todoList)

            // Sidebar overlay
            if appState.showSidebar {
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: 260)
                        .transition(.move(edge: .leading))

                    Spacer()
                }
            }

            // View mode indicator
            VStack {
                Spacer()
                HStack {
                    viewModeIndicator
                        .padding(12)
                    Spacer()
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.currentView == .canvas)
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

    private var viewModeIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: appState.currentView == .todoList ? "checklist" : "square.grid.3x3")
                .font(.system(size: 10))
            Text(appState.currentView == .todoList ? "Todos" : "Canvas")
                .font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private func installKeyboardMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ctrl+Tab: toggle view
            if event.keyCode == 48 && event.modifierFlags.contains(.control) {
                withAnimation {
                    appState.currentView = appState.currentView == .todoList ? .canvas : .todoList
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
