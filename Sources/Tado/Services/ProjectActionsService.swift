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
        modelContext.delete(project)
        try? modelContext.save()
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
