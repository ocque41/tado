import Foundation
import SwiftData

/// Stateless helper for the project-level actions that used to live
/// inline in `ProjectListView` and `ProjectDetailView`. Now also called
/// from `TopNavBar`, so the three call sites share one implementation
/// instead of drifting copies of bootstrap/delete logic.
@MainActor
enum ProjectActionsService {
    /// Spawn a tile that bootstraps the Tado A2A CLI tools into the
    /// target project. Mirrors the previous inline implementation —
    /// runs in the Tado repo cwd against the project's path, navigates
    /// to the canvas so the user can watch the run.
    static func bootstrapTools(
        project: Project,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        guard let tadoRoot = ProcessSpawner.tadoRepoRoot() else { return }

        let prompt = ProcessSpawner.bootstrapPrompt(targetPath: project.rootPath)
        let settings = fetchOrCreateSettings(modelContext: modelContext)
        let index = nextAvailableGridIndex(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        modelContext.insert(todo)

        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: tadoRoot,
            projectName: "Tado"
        )

        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    /// Spawn a tile that teaches existing teams about each other. No-op
    /// when the project has no teams — callers should disable the menu
    /// entry in that case so the click never lands here.
    static func bootstrapTeam(
        project: Project,
        teams: [Team],
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        guard !teams.isEmpty else { return }

        let prompt = ProcessSpawner.bootstrapTeamPrompt(
            targetPath: project.rootPath,
            projectName: project.name,
            teams: teams.map { ($0.name, $0.agentNames) }
        )
        let settings = fetchOrCreateSettings(modelContext: modelContext)
        let index = nextAvailableGridIndex(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        modelContext.insert(todo)

        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: project.rootPath,
            projectName: project.name
        )

        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    /// Spawn a one-shot tile that merges Tado's recommended auto-mode
    /// configuration into the user's Claude Code settings. Handles the
    /// merge through an agent (rather than writing JSON directly from
    /// Swift) so the user has a real transcript showing exactly what
    /// changed and can intervene if needed.
    ///
    /// The spawned agent updates both `~/.claude/settings.json` (user
    /// scope — affects every Claude Code session on this machine) and
    /// `<project>/.claude/settings.local.json` (project-local scope —
    /// gitignored, specific to this project's Tado work).
    static func bootstrapAutoMode(
        project: Project,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        let prompt = ProcessSpawner.bootstrapAutoModePrompt(
            projectName: project.name,
            projectRoot: project.rootPath
        )
        let settings = fetchOrCreateSettings(modelContext: modelContext)
        let index = nextAvailableGridIndex(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        modelContext.insert(todo)

        // Pin Opus + high effort: this is config-writing work where
        // subtle JSON merging mistakes silently break everything.
        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: project.rootPath,
            projectName: project.name,
            modeFlagsOverride: ProcessSpawner.eternalPermissionFlags(skipPermissions: true),
            modelFlagsOverride: ["--model", ClaudeModel.opus47.rawValue],
            effortFlagsOverride: ["--effort", ClaudeEffort.high.rawValue]
        )

        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    /// Spawn a tile that injects Tado's knowledge-layer docs (Dome second
    /// brain + spawn-time context preamble + the `dome-mcp` / `tado-mcp`
    /// MCP tool surfaces) into the project's CLAUDE.md and AGENTS.md.
    ///
    /// Parallel to `bootstrapTools` and `bootstrapTeam` — runs from the
    /// project root so the agent has direct access to the target docs,
    /// inherits the project's name/path for the prompt, and the spawned
    /// agent's own context preamble already references the same vault
    /// it's documenting (nice closure on the loop).
    static func bootstrapKnowledge(
        project: Project,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        let prompt = ProcessSpawner.bootstrapKnowledgePrompt(
            projectName: project.name,
            projectRoot: project.rootPath
        )
        let settings = fetchOrCreateSettings(modelContext: modelContext)
        let index = nextAvailableGridIndex(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        modelContext.insert(todo)

        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: project.rootPath,
            projectName: project.name
        )

        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    /// Install the bundled `tado-cowork-plugin` into the user's
    /// Claude install. Runs as a one-shot Claude Code agent tile so
    /// the operator sees what's happening (rather than firing the
    /// install silently from a `Task.detached` somewhere). Mirrors
    /// the four existing bootstrap actions exactly: spawns a tile,
    /// the prompt instructs the agent to run `claude plugin
    /// marketplace add` + `claude plugin install`, the agent reports
    /// back, then exits.
    ///
    /// This is the project-scoped front door for the same install
    /// the Settings → Engine → "Bootstrap Cowork plugin" button
    /// fires (which in turn calls `CoworkPluginInstaller.install()`
    /// — the in-process equivalent that doesn't spawn a tile).
    /// Both surfaces converge on the same `claude plugin install`
    /// invocation; the difference is whether the operator wants
    /// visible feedback (this surface) or quiet feedback (the
    /// Settings button).
    static func bootstrapCoworkPlugin(
        project: Project,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        let prompt = ProcessSpawner.bootstrapCoworkPluginPrompt(
            projectName: project.name,
            projectRoot: project.rootPath
        )
        let settings = fetchOrCreateSettings(modelContext: modelContext)
        let index = nextAvailableGridIndex(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        modelContext.insert(todo)

        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: project.rootPath,
            projectName: project.name
        )

        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    /// Tear down every session belonging to the project, then delete
    /// the project itself. Caller is responsible for clearing any
    /// `appState.activeProjectID` it owns — kept out of here so the
    /// list view (which has no active selection) doesn't need a no-op.
    static func deleteProject(
        _ project: Project,
        modelContext: ModelContext,
        terminalManager: TerminalManager
    ) {
        let descriptor = FetchDescriptor<TodoItem>()
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        for todo in todos where todo.projectID == project.id {
            terminalManager.terminateSessionForTodo(todo.id)
        }
        // Clean up the perf-baselines directory for this project
        // before the SwiftData record disappears. The baselines live
        // under <project-root>/.tado/perf-baselines/ — same scope as
        // the rest of the per-project Tado state, so deletion lines
        // up with how Eternal/Dispatch run dirs are handled.
        cleanupPerfBaselines(for: project)
        modelContext.delete(project)
        try? modelContext.save()
    }

    /// Remove the perf-baselines directory for a project. Best-
    /// effort — failures are logged but never block the deletion.
    /// Called from `deleteProject` and from the Reset Tado data
    /// flow.
    static func cleanupPerfBaselines(for project: Project) {
        let baselineDir = URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".tado")
            .appendingPathComponent("perf-baselines")
        if FileManager.default.fileExists(atPath: baselineDir.path) {
            do {
                try FileManager.default.removeItem(at: baselineDir)
                NSLog("ProjectActionsService: removed perf-baselines for \(project.name) at \(baselineDir.path)")
            } catch {
                NSLog("ProjectActionsService: failed to remove perf-baselines at \(baselineDir.path): \(error)")
            }
        }
    }

    // MARK: - Kanban

    /// Seed the default `Backlog / Doing / Done` columns for one
    /// project's general Kanban board if it has none yet. Called from
    /// `ProjectKanbanView.onAppear` so the user lands on a populated
    /// board the first time they switch the page mode. Safe to call
    /// every onAppear — the early-exit short-circuits when columns
    /// already exist. Only seeds `kind == "project"` rows;
    /// dispatch-phase columns are owned by `materializeKanbanColumns`.
    @discardableResult
    static func seedKanbanColumns(
        project: Project,
        modelContext: ModelContext
    ) -> [KanbanColumn] {
        let projectID = project.id
        let descriptor = FetchDescriptor<KanbanColumn>(
            predicate: #Predicate<KanbanColumn> { col in
                col.kind == "project" && col.project?.id == projectID
            }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        if !existing.isEmpty {
            return existing.sorted { $0.orderIndex < $1.orderIndex }
        }
        var seeded: [KanbanColumn] = []
        for (index, defaults) in KanbanColumn.defaultProjectColumns.enumerated() {
            let col = KanbanColumn(
                project: project,
                kind: "project",
                columnKey: defaults.key,
                title: defaults.title,
                orderIndex: index
            )
            modelContext.insert(col)
            seeded.append(col)
        }
        try? modelContext.save()
        return seeded
    }

    // MARK: - Internal helpers

    private static func nextAvailableGridIndex(modelContext: ModelContext) -> Int {
        let descriptor = FetchDescriptor<TodoItem>()
        let active = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { $0.listState == .active }
        let used = Set(active.map(\.gridIndex))
        var index = 0
        while used.contains(index) { index += 1 }
        return index
    }

    private static func fetchOrCreateSettings(modelContext: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let settings = AppSettings()
        modelContext.insert(settings)
        try? modelContext.save()
        return settings
    }
}
