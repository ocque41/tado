import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query private var allSettings: [AppSettings]
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Paint the window base as neutral dark. Individual views
        // (TodoList, Projects) may add their own `surface` /
        // `surfaceElevated` strips on top of this, but anything that
        // doesn't is guaranteed to read `Palette.background` instead
        // of the system default window colour.
        .background(Palette.background)
        // Blur the main window when Settings is presented. The sheet
        // itself sits in a separate window layer and is NOT blurred —
        // only the backdrop is, so Settings reads as a clearly
        // modal frame over a defocused app.
        .blur(radius: appState.showSettings ? 10 : 0)
        .animation(.easeInOut(duration: 0.2), value: appState.showSettings)
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
        .sheet(isPresented: Binding(
            get: { appState.dispatchModalProjectID != nil },
            set: { if !$0 { appState.dispatchModalProjectID = nil } }
        )) {
            if let id = appState.dispatchModalProjectID,
               let project = fetchProject(id) {
                DispatchFileModal(project: project)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear { installKeyboardMonitor() }
        .onDisappear { removeKeyboardMonitor() }
        .task {
            reconnectOnLaunch()
            wireSpawnCallback()
            syncTerminalManagerSettings()
        }
        .onChange(of: allSettings.first?.randomTileColor) { _, _ in
            syncTerminalManagerSettings()
        }
    }

    private var pageNavigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Button(action: { appState.currentView = mode }) {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10))
                        Text(mode.label)
                            .font(Typography.callout)
                    }
                    .frame(width: 100, alignment: .leading)
                    .foregroundStyle(appState.currentView == mode ? Palette.accent : Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(appState.currentView == mode ? Palette.surfaceAccent : Color.clear)
                    )
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

    private func wireSpawnCallback() {
        let manager = terminalManager
        let context = modelContext
        let state = appState
        terminalManager.ipcBroker?.onSpawnRequest = { request in
            ContentView.handleSpawnRequest(request, terminalManager: manager, modelContext: context, appState: state)
        }
    }

    private static func handleSpawnRequest(_ request: SpawnRequest, terminalManager: TerminalManager, modelContext: ModelContext, appState: AppState) {
        // Resolve project first — needed for agent source lookup
        var projectID: UUID?
        var projectRoot: String?
        if let projectName = request.projectName {
            let descriptor = FetchDescriptor<Project>()
            if let projects = try? modelContext.fetch(descriptor),
               let project = projects.first(where: { $0.name.lowercased() == projectName.lowercased() }) {
                projectID = project.id
                projectRoot = request.projectRoot ?? project.rootPath
            }
        }
        if projectRoot == nil { projectRoot = request.projectRoot }

        // Smart engine resolution:
        // 1. Agent source: .claude/agents/ → claude, .codex/agents/ → codex
        // 2. Explicit --engine from tado-deploy
        // 3. Fall back to user's default engine
        let engine: TerminalEngine
        if let agentName = request.agentName, let root = projectRoot,
           let resolved = AgentDiscoveryService.resolveEngine(agentName: agentName, projectRoot: root) {
            engine = resolved
        } else if let engineStr = request.engine, let parsed = TerminalEngine(rawValue: engineStr) {
            engine = parsed
        } else {
            engine = ContentView.fetchOrCreateSettings(modelContext: modelContext).engine
        }

        // Resolve team
        var teamID: UUID?
        var teamName: String?
        var teamAgents: [String]?
        if let reqTeamName = request.teamName {
            let descriptor = FetchDescriptor<Team>()
            if let teams = try? modelContext.fetch(descriptor) {
                let team = teams.first(where: {
                    $0.name.lowercased() == reqTeamName.lowercased()
                    && (projectID == nil || $0.projectID == projectID)
                })
                if let team {
                    teamID = team.id
                    teamName = team.name
                    teamAgents = team.agentNames
                }
            }
        }

        // If agent provided but no team, try to find the team containing this agent
        if teamID == nil, let agentName = request.agentName, let projectID {
            let descriptor = FetchDescriptor<Team>()
            if let teams = try? modelContext.fetch(descriptor) {
                let team = teams.first { $0.projectID == projectID && $0.agentNames.contains(agentName) }
                if let team {
                    teamID = team.id
                    teamName = team.name
                    teamAgents = team.agentNames
                }
            }
        }

        // Allocate grid index
        let todoDescriptor = FetchDescriptor<TodoItem>()
        let allTodos = (try? modelContext.fetch(todoDescriptor)) ?? []
        let usedIndices = Set(allTodos.filter { $0.listState == .active }.map(\.gridIndex))
        var index = 0
        while usedIndices.contains(index) { index += 1 }

        let settings = ContentView.fetchOrCreateSettings(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        // Create TodoItem
        let todo = TodoItem(text: request.prompt, gridIndex: index, canvasPosition: position)
        todo.projectID = projectID
        todo.teamID = teamID
        todo.agentName = request.agentName
        modelContext.insert(todo)

        // Spawn session
        terminalManager.spawnAndWire(
            todo: todo,
            engine: engine,
            cwd: projectRoot,
            agentName: request.agentName,
            projectName: request.projectName,
            teamName: teamName,
            teamID: teamID,
            teamAgents: teamAgents
        )

        try? modelContext.save()

        // Navigate to canvas
        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    private static func fetchOrCreateSettings(modelContext: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? modelContext.fetch(descriptor).first { return existing }
        let settings = AppSettings()
        modelContext.insert(settings)
        try? modelContext.save()
        return settings
    }

    private func fetchProject(_ id: UUID) -> Project? {
        let descriptor = FetchDescriptor<Project>()
        return (try? modelContext.fetch(descriptor))?.first { $0.id == id }
    }

    /// Mirror tile-color randomness from AppSettings into the TerminalManager so
    /// new sessions pick a random theme. Called at startup and whenever the user
    /// flips the toggle in SettingsView.
    private func syncTerminalManagerSettings() {
        let settings = ContentView.fetchOrCreateSettings(modelContext: modelContext)
        terminalManager.randomTileColors = settings.randomTileColor
        terminalManager.defaultTheme = TerminalTheme.theme(id: settings.defaultThemeId)
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
