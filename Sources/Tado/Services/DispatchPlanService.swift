import Foundation
import SwiftData

struct PhaseJSON: Codable {
    let id: String
    let order: Int
    let title: String
    let skill: String?
    let agent: String?
    let engine: String?
    let prompt: String
    let nextPhaseFile: String?
    let status: String
}

enum DispatchPlanService {
    // MARK: - Paths (project-scoped — single-run legacy)

    static func dispatchRoot(_ project: Project) -> URL {
        URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".tado")
            .appendingPathComponent("dispatch")
    }

    static func dispatchFileURL(_ project: Project) -> URL {
        dispatchRoot(project).appendingPathComponent("dispatch.md")
    }

    static func planFileURL(_ project: Project) -> URL {
        dispatchRoot(project).appendingPathComponent("plan.json")
    }

    static func phasesDirURL(_ project: Project) -> URL {
        dispatchRoot(project).appendingPathComponent("phases")
    }

    static func planExistsOnDisk(_ project: Project) -> Bool {
        FileManager.default.fileExists(atPath: planFileURL(project).path)
    }

    // MARK: - Paths (run-scoped — multi-run)

    /// Parent dir holding every dispatch run's on-disk state for a project:
    /// `<project>/.tado/dispatch/runs/`. Used only by migration and
    /// orchestration; individual runs build paths via `dispatchRoot(_ run:)`.
    static func runsRootURL(_ project: Project) -> URL {
        URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".tado")
            .appendingPathComponent("dispatch")
            .appendingPathComponent("runs")
    }

    /// On-disk directory for one dispatch run:
    /// `<project>/.tado/dispatch/runs/<uuid>/`.
    static func dispatchRoot(_ run: DispatchRun) -> URL {
        guard let project = run.project else {
            fatalError(
                "DispatchRun \(run.id) has nil project — cascade inverse corrupted."
            )
        }
        return runsRootURL(project).appendingPathComponent(run.id.uuidString)
    }

    static func dispatchFileURL(_ run: DispatchRun) -> URL {
        dispatchRoot(run).appendingPathComponent("dispatch.md")
    }

    static func planFileURL(_ run: DispatchRun) -> URL {
        dispatchRoot(run).appendingPathComponent("plan.json")
    }

    static func phasesDirURL(_ run: DispatchRun) -> URL {
        dispatchRoot(run).appendingPathComponent("phases")
    }

    static func planExistsOnDisk(_ run: DispatchRun) -> Bool {
        FileManager.default.fileExists(atPath: planFileURL(run).path)
    }

    /// Number of phase JSON files in this run's `phases/` dir. Used by the
    /// section's row to show "READY · 7 phases" without parsing plan.json.
    /// Zero when the dir is missing or empty.
    static func phaseFileCount(_ run: DispatchRun) -> Int {
        let fm = FileManager.default
        let dir = phasesDirURL(run)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == "json" }.count
    }

    /// Clear plan.json and all phases/*.json for one run, then write the run's
    /// brief to dispatch.md. Creates the run directory tree if missing.
    static func resetPlan(_ run: DispatchRun) {
        let fm = FileManager.default
        let root = dispatchRoot(run)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        let planURL = planFileURL(run)
        try? fm.removeItem(at: planURL)

        let phasesDir = phasesDirURL(run)
        if fm.fileExists(atPath: phasesDir.path) {
            try? fm.removeItem(at: phasesDir)
        }
        try? fm.createDirectory(at: phasesDir, withIntermediateDirectories: true)

        let dispatchURL = dispatchFileURL(run)
        try? run.brief.write(to: dispatchURL, atomically: true, encoding: .utf8)
    }

    /// Parse every .json in phases/ and return the one with order == 1, or nil.
    static func firstPhase(_ run: DispatchRun) -> PhaseJSON? {
        let fm = FileManager.default
        let phasesDir = phasesDirURL(run)
        guard let files = try? fm.contentsOfDirectory(at: phasesDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let decoder = JSONDecoder()
        let phases: [PhaseJSON] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(PhaseJSON.self, from: data)
            }
        return phases.first { $0.order == 1 }
    }

    // MARK: - Delete

    /// Irreversibly drop a Dispatch run: kill any architect/phase tiles
    /// attached to it, wipe its on-disk `.tado/dispatch/runs/<id>/` dir,
    /// and remove the SwiftData row. Called from the project detail
    /// page's delete action.
    ///
    /// Skill/agent files the architect wrote under
    /// `.claude/skills/dispatch-<project>-<shortid>-*` and
    /// `.claude/agents/dispatch-<project>-<shortid>-*.md` are NOT cleaned
    /// up — those names are scoped by run-short-id so they don't collide
    /// with future runs, and wiping them risks removing files a still-
    /// live phase tile has open. The user can delete them manually if
    /// they want the project root pristine.
    @MainActor
    static func deleteRun(
        _ run: DispatchRun,
        modelContext: ModelContext,
        terminalManager: TerminalManager
    ) {
        let runDir = dispatchRoot(run)

        let linked = terminalManager.sessions.filter { $0.dispatchRunID == run.id }
        for session in linked {
            terminalManager.terminateSession(session.id)
        }

        do {
            try FileManager.default.removeItem(at: runDir)
        } catch {
            NSLog("DispatchPlanService: deleteRun failed to remove \(runDir.path): \(error.localizedDescription)")
        }

        modelContext.delete(run)
        try? modelContext.save()
    }

    // MARK: - Spawn helpers

    /// Returns the next free grid index across all active todos.
    @MainActor
    private static func nextAvailableGridIndex(modelContext: ModelContext) -> Int {
        let descriptor = FetchDescriptor<TodoItem>()
        let allTodos = (try? modelContext.fetch(descriptor)) ?? []
        let usedIndices = Set(allTodos.filter { $0.listState == .active }.map(\.gridIndex))
        var index = 0
        while usedIndices.contains(index) { index += 1 }
        return index
    }

    /// Fetches existing AppSettings or creates a default one.
    @MainActor
    private static func fetchOrCreateSettings(modelContext: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? modelContext.fetch(descriptor).first { return existing }
        let settings = AppSettings()
        modelContext.insert(settings)
        try? modelContext.save()
        return settings
    }

    /// Spawn the dispatch architect terminal for one run. Writes dispatch.md
    /// from `run.brief`, clears any existing plan under the run dir, transitions
    /// the run state to "planning", and navigates to the canvas.
    @MainActor
    static func spawnArchitect(
        run: DispatchRun,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        guard let project = run.project else { return }

        resetPlan(run)

        let settings = fetchOrCreateSettings(modelContext: modelContext)
        // The architect receives the project name PLUS the run's short-id
        // suffix so every skill/agent file it authors is scoped to this run
        // and two concurrent dispatches can't clobber each other under
        // `.claude/skills/dispatch-<project>-<shortid>-<phase-id>/`.
        let prompt = ProcessSpawner.dispatchArchitectPrompt(
            projectName: project.name,
            projectRoot: project.rootPath,
            runID: run.id
        )
        let index = nextAvailableGridIndex(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        modelContext.insert(todo)

        terminalManager.spawnAndWire(
            todo: todo,
            engine: settings.engine,
            cwd: project.rootPath,
            projectName: project.name,
            dispatchRunID: run.id,
            runRole: "architect"
        )

        run.state = "planning"
        run.architectTodoID = todo.id
        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    /// Launch phase 1 using the architect-authored prompt. Returns false if
    /// plan.json is missing or no phase has order == 1 — caller should show a
    /// "still planning" message in that case.
    ///
    /// No in-app supervision: once phase 1 spawns, Tado does nothing to
    /// observe or intervene in the chain. Each phase is responsible for its
    /// own tado-deploy handoff; failures surface as tile-level silence rather
    /// than a UI-level alert. Matches user memory "no dispatch safety systems".
    @MainActor
    @discardableResult
    static func startPhaseOne(
        run: DispatchRun,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> Bool {
        guard let project = run.project else { return false }
        guard planExistsOnDisk(run), let phase = firstPhase(run) else {
            return false
        }

        let settings = fetchOrCreateSettings(modelContext: modelContext)
        let engine: TerminalEngine
        if let phaseEngine = phase.engine, let parsed = TerminalEngine(rawValue: phaseEngine) {
            engine = parsed
        } else if let agentName = phase.agent,
                  let resolved = AgentDiscoveryService.resolveEngine(agentName: agentName, projectRoot: project.rootPath) {
            engine = resolved
        } else {
            engine = settings.engine
        }

        let index = nextAvailableGridIndex(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: phase.prompt, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        todo.agentName = phase.agent
        modelContext.insert(todo)

        terminalManager.spawnAndWire(
            todo: todo,
            engine: engine,
            cwd: project.rootPath,
            agentName: phase.agent,
            projectName: project.name,
            dispatchRunID: run.id,
            runRole: "phase"
        )

        if let agentName = phase.agent, engine == .claude,
           let session = terminalManager.session(forTodoID: todo.id) {
            let override = AgentDiscoveryService.phaseOverride(
                agentName: agentName,
                projectRoot: project.rootPath
            )
            session.modelFlagsOverride = override.modelFlags
            session.effortFlagsOverride = override.effortFlags
        }

        run.state = "dispatching"
        run.currentPhaseTodoID = todo.id
        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
        return true
    }
}
