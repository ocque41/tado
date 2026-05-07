import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query private var allSettings: [AppSettings]
    @State private var eventMonitor: Any?
    /// Phase 12 — first-run onboarding gate. Set to true by the
    /// onboarding flow's `finish()`. Until then, the entire app
    /// is replaced by the onboarding view.
    @AppStorage("relay.onboarded") private var onboarded: Bool = false
    /// Phase 3 — ⌘K command palette presentation state. Toggled by
    /// the palette's keyboard shortcut and the Jump button in the
    /// topbar (already wired via `.keyboardShortcut("k", modifiers:
    /// .command)`). The palette overlays everything else via the
    /// outer `ZStack`.
    @State private var paletteOpen: Bool = false
    /// Phase 4 — ⌘E Explore left panel presentation state. Toggled
    /// by the keyboard shortcut, by clicking the workspace pill in
    /// the topbar, or by clicking the brand-mark dot in the rail
    /// nav.
    @State private var exploreOpen: Bool = false

    /// Surface name shown in the titlebar accessory — derived from
    /// the active `currentView`. Renders as "Tado · {Surface}" in
    /// the centered title slot.
    private var surfaceName: String? {
        appState.currentView.label
    }

    var body: some View {
        if !onboarded {
            RelayOnboarding()
        } else {
            mainBody
        }
    }

    @ViewBuilder
    private var mainBody: some View {
        ZStack(alignment: .bottomTrailing) {
        VStack(spacing: 0) {
            // Hidden zero-sized button carrying Cmd+Shift+U so the
            // hotkey resolves while the main window is key. Matches
            // `DomeHotkeyRegistrar`'s pattern.
            TadoUseHotkeyRegistrar()

            // Phase 2 — Relay shell. Wraps the titlebar accessory
            // (32px, with version pill + paper/ink toggle) and the
            // width-aware nav (topbar default / rail alternate /
            // narrow-viewport drawer trigger). The page tree below
            // is the shell's content — it stays unchanged.
            RelayShell(surfaceName: surfaceName) {
            HStack(spacing: 0) {
                // Tado Use drawer — slides in from the left edge,
                // sibling to the existing SidebarView. Both can
                // coexist; the drawer is wider (360pt) because chat
                // needs reading width.
                if appState.showTadoUse {
                    TadoUsePanel()
                        .frame(width: 360)
                        .transition(.move(edge: .leading))
                }
                // Sidebar takes real layout space — TodoListView / ProjectsView
                // reflow into the remaining width instead of being covered.
                // Canvas still fills the remaining width via `maxWidth:
                // .infinity` below; its pan/zoom math works in canvas-space,
                // so a narrower viewport doesn't disturb tile positions.
                if appState.showSidebar {
                    SidebarView()
                        .frame(width: 260)
                        .transition(.move(edge: .leading))
                }

                ZStack {
                    // All views stay alive — never destroyed/recreated.
                    // Terminals keep running when switching views.
                    CanvasView()
                        .opacity(appState.currentView == .canvas ? 1 : 0)
                        .allowsHitTesting(appState.currentView == .canvas)

                    // Relay redesign — RelayTodoListView replaces
                    // TodoListView at the .todos route. Same data
                    // flow (TodoItem + TerminalManager.spawnAndWire),
                    // new chrome.
                    RelayTodoListView()
                        .opacity(appState.currentView == .todos ? 1 : 0)
                        .allowsHitTesting(appState.currentView == .todos)

                    // Phase 7 — Relay Projects landing surface.
                    // Drills into the legacy ProjectsView chain
                    // when an active project is selected.
                    RelayProjectsView()
                        .opacity(appState.currentView == .projects ? 1 : 0)
                        .allowsHitTesting(appState.currentView == .projects)

                    // Extensions page — discovery surface for every
                    // bundled extension. Stays mounted like the others
                    // so its scroll position survives view switches.
                    ExtensionsPageView()
                        .opacity(appState.currentView == .extensions ? 1 : 0)
                        .allowsHitTesting(appState.currentView == .extensions)

                    // Details — top-level live status dashboard reached
                    // by clicking the Tado wordmark. Stays mounted like
                    // the others so the 2 s polling Task and EventBus
                    // observation stay warm across view switches.
                    DetailsView()
                        .opacity(appState.currentView == .details ? 1 : 0)
                        .allowsHitTesting(appState.currentView == .details)

                    // Phase 5 — Relay Sessions surface (full-page list
                    // of every active terminal tile, grouped by status).
                    RelaySessionsView()
                        .opacity(appState.currentView == .sessions ? 1 : 0)
                        .allowsHitTesting(appState.currentView == .sessions)

                    // Phase 7 + 10 — Teams / Kanban / Dispatch / Eternal
                    // landing surfaces. Each renders the full-page
                    // overview; clicking through drills into the
                    // existing project-scoped detail flows.
                    RelayTeamsView()
                        .opacity(appState.currentView == .teams ? 1 : 0)
                        .allowsHitTesting(appState.currentView == .teams)
                    RelayKanbanView()
                        .opacity(appState.currentView == .kanban ? 1 : 0)
                        .allowsHitTesting(appState.currentView == .kanban)
                    RelayDispatchView()
                        .opacity(appState.currentView == .dispatch ? 1 : 0)
                        .allowsHitTesting(appState.currentView == .dispatch)
                    RelayEternalView()
                        .opacity(appState.currentView == .eternal ? 1 : 0)
                        .allowsHitTesting(appState.currentView == .eternal)

                    // Non-blocking banner overlay. Sits on top of whatever
                    // page is active; hit-testing limited to visible pills
                    // so it doesn't eat clicks on the canvas/todos below.
                    InAppBannerOverlay()
                        .allowsHitTesting(true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            } // closes the inner HStack(spacing: 0)
        } // closes the `RelayShell { ... }` content closure
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
        .animation(.easeInOut(duration: 0.2), value: appState.showTadoUse)
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
            get: { appState.showNewProjectSheet },
            set: { appState.showNewProjectSheet = $0 }
        )) {
            NewProjectSheet()
        }
        .sheet(isPresented: Binding(
            get: { appState.dispatchModalRunID != nil },
            set: { if !$0 { appState.dispatchModalRunID = nil } }
        )) {
            if let id = appState.dispatchModalRunID,
               let run = fetchDispatchRun(id) {
                DispatchFileModal(run: run)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.eternalModalRunID != nil },
            set: { if !$0 { appState.eternalModalRunID = nil } }
        )) {
            if let id = appState.eternalModalRunID,
               let run = fetchEternalRun(id) {
                EternalFileModal(run: run)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.eternalInterveneRunID != nil },
            set: { if !$0 { appState.eternalInterveneRunID = nil } }
        )) {
            if let id = appState.eternalInterveneRunID,
               let run = fetchEternalRun(id) {
                EternalInterveneModal(run: run)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.craftedReviewRunID != nil && appState.craftedReviewKind != nil },
            set: { if !$0 {
                appState.craftedReviewRunID = nil
                appState.craftedReviewKind = nil
            } }
        )) {
            if let id = appState.craftedReviewRunID,
               let kind = appState.craftedReviewKind {
                CraftedReviewModal(runID: id, kind: kind)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear { installKeyboardMonitor() }
        .onDisappear { removeKeyboardMonitor() }
        .task {
            reconnectOnLaunch()
            wireSpawnCallback()
            syncTerminalManagerSettings()
            runEternalStartupMigrations()
        }
        .onChange(of: allSettings.first?.randomTileColor) { _, _ in
            syncTerminalManagerSettings()
        }
        .onChange(of: appState.currentView) { _, newView in
            releaseTerminalFocusIfNeeded(for: newView)
        }

        // Phase 6 — Focused-tile modal. Renders centered over the
        // canvas (or any active surface) when
        // `appState.focusedTileModalTodoID` is non-nil.
        if appState.focusedTileModalTodoID != nil {
            RelayFocusedTileModal(todoID: Binding(
                get: { appState.focusedTileModalTodoID },
                set: { appState.focusedTileModalTodoID = $0 }
            ))
            .transition(.opacity)
        }

        // Phase 4 — Explore left panel overlay. Sits inside the
        // outer ZStack at the leading edge. Only renders when
        // `exploreOpen` is true.
        if exploreOpen {
            HStack(spacing: 0) {
                RelayExplorePanel(isPresented: $exploreOpen)
                Spacer(minLength: 0)
            }
            .transition(.move(edge: .leading))
        }

        // Phase 3 — ⌘K command palette overlay. Sits inside the
        // outer ZStack so its scrim + backdrop blur applies to the
        // host content. Only renders when `paletteOpen` is true.
        if paletteOpen {
            RelayCommandPalette(
                isPresented: $paletteOpen,
                onOpenExplore: {
                    paletteOpen = false
                    withAnimation(.easeOut(duration: 0.24)) {
                        exploreOpen = true
                    }
                }
            )
            .transition(.opacity)
        }

        // Hidden zero-sized buttons — register ⌘K and ⌘E everywhere
        // so palette + Explore toggle regardless of focused control.
        Group {
            Button("Open palette") { paletteOpen = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("Toggle Explore") {
                withAnimation(.easeOut(duration: 0.24)) {
                    exploreOpen.toggle()
                }
            }
            .keyboardShortcut("e", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)

        // Phase 13 — Relay toast overlay. Bottom-center, listens
        // on the `.relayToastRequest` NotificationCenter event,
        // auto-dismisses after 2400ms.
        RelayToastHost()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

        // Relay tweaks panel — bottom-right floating developer panel
        // for switching nav mode + theme at runtime. Visibility
        // gated by `@AppStorage("relay.tweaksVisible")` so it only
        // renders when explicitly toggled on. Sits on top of all
        // page content via the outer `ZStack(.bottomTrailing)`.
        RelayTweaksPanel()
        }
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
        // Coordinator-driven Unix socket. Same shape as
        // onSpawnRequest — we capture the SwiftUI environment values
        // and route through `ControlRequestRouter.handle`.
        terminalManager.ipcBroker?.controlSocket.onRequest = { request in
            ControlRequestRouter.handle(
                request: request,
                terminalManager: manager,
                modelContext: context,
                appState: state
            )
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

        // Honor per-phase `model:` / `effort:` frontmatter on dispatched agents.
        // Phase agents emitted by tado-dispatch-agent-creator pin Haiku for
        // volume work and Opus for the occasional design-heavy phase; without
        // this override the tile would inherit whatever the user picked in
        // Settings (usually Opus), defeating the point of per-phase routing.
        if let agentName = request.agentName, let root = projectRoot,
           engine == .claude,
           let session = terminalManager.session(forTodoID: todo.id) {
            let override = AgentDiscoveryService.phaseOverride(
                agentName: agentName,
                projectRoot: root
            )
            session.modelFlagsOverride = override.modelFlags
            session.effortFlagsOverride = override.effortFlags
        }

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

    private func fetchEternalRun(_ id: UUID) -> EternalRun? {
        let descriptor = FetchDescriptor<EternalRun>()
        return (try? modelContext.fetch(descriptor))?.first { $0.id == id }
    }

    private func fetchDispatchRun(_ id: UUID) -> DispatchRun? {
        let descriptor = FetchDescriptor<DispatchRun>()
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

    /// One-shot migration (flip all projects to Full Auto on) plus every-launch
    /// reconciliation (clean up stale `.tado/eternal/active` flags left by
    /// crashed sessions). Order matters: migrate first so state is canonical
    /// before we inspect which projects have live sessions.
    ///
    /// Also writes the user-scope `~/.claude/settings.json` so every Claude
    /// Code session this machine spawns (not just Tado's) inherits
    /// bypassPermissions + a wide allowlist + the no-prompt flag. This is
    /// load-bearing: `--dangerously-skip-permissions` does not by itself
    /// bypass the one-time "confirm bypass mode" dialog, nor the protected-
    /// path prompts on `.claude/` writes. The merge is idempotent and runs
    /// every launch cheaply.
    private func runEternalStartupMigrations() {
        // `writeUserScopeSettings` is JSON read/parse/merge/write against
        // `~/.claude/settings.json` — small, but synchronous file IO.
        // Hop it to a background queue at `.utility` so it never adds
        // a frame of jank to app launch on a cold disk.
        Task.detached(priority: .utility) {
            EternalService.writeUserScopeSettings()
        }
        EternalService.migrateEternalDefaults(modelContext: modelContext)
        // One-shot: lift legacy per-project eternal/dispatch state into
        // EternalRun / DispatchRun rows, with files moved under
        // `.tado/{eternal,dispatch}/runs/<id>/`. Gated by
        // `AppSettings.didMigrateToMultipleRuns` so it only runs once.
        // MUST run BEFORE `refreshAllHookScripts` (hooks now reference the
        // run-scoped layout) and BEFORE `reconcileActiveFlagsOnLaunch`
        // (that pass iterates EternalRun, not Project).
        EternalService.migrateToMultipleRuns(modelContext: modelContext)
        // Overwrite every project's on-disk hook scripts with the current
        // in-binary templates. An already-running worker keeps its in-
        // memory copy, but the next Stop + Start picks up the fresh file
        // immediately — users don't have to wait for the "next spawn after
        // upgrading" cycle to see wrapper improvements. The function
        // snapshots project paths on @MainActor and hops the file writes
        // off-main internally.
        EternalService.refreshAllHookScripts(modelContext: modelContext)
        EternalService.reconcileActiveFlagsOnLaunch(
            modelContext: modelContext,
            terminalManager: terminalManager
        )
    }

    /// When the user switches away from the canvas, release any terminal
    /// that still holds firstResponder back to the window's contentView.
    /// All three views stay mounted (opacity toggle in this ZStack), so a
    /// Metal tile that had been clicked would otherwise keep eating key
    /// events — including arrow keys in TextFields on the newly-visible
    /// Projects/Todos view. Bug fix for the "arrow keys break with ≥2
    /// terminals" report.
    private func releaseTerminalFocusIfNeeded(for view: ViewMode) {
        guard view != .canvas else { return }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else { return }
        // Only resign if the current firstResponder is actually a terminal
        // view — don't clobber a TextField's focus on the destination view.
        if isFirstResponderInsideTerminal(window: window) {
            window.makeFirstResponder(contentView)
        }
        // Also clear the canvas's tile selection so returning to canvas
        // starts fresh rather than with a stale highlight.
        appState.focusedTileTodoID = nil
    }

    private func isFirstResponderInsideTerminal(window: NSWindow) -> Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        var current: NSView? = view
        while let v = current {
            if v is TerminalMTKView { return true }
            current = v.superview
        }
        return false
    }

    private func reconnectOnLaunch() {
        let todoDescriptor = FetchDescriptor<TodoItem>()
        guard let todos = try? modelContext.fetch(todoDescriptor) else { return }
        // Mark stale sessions as completed — the processes died when the app closed.
        // Do NOT re-spawn terminals; that would re-run CLI prompts and waste tokens.
        for todo in todos where !todo.isComplete
            && (todo.status == .running
                || todo.status == .needsInput
                || todo.status == .awaitingResponse) {
            todo.status = .completed
        }
        try? modelContext.save()
    }
}
