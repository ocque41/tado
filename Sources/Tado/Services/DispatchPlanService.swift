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

    /// Human-reviewable plan summary written by the architect alongside
    /// `plan.json`. Source of truth for the Plan Review modal.
    static func craftedFileURL(_ run: DispatchRun) -> URL {
        dispatchRoot(run).appendingPathComponent("crafted.md")
    }

    static func planExistsOnDisk(_ run: DispatchRun) -> Bool {
        FileManager.default.fileExists(atPath: planFileURL(run).path)
    }

    /// Has the architect finished writing the human-reviewable plan?
    /// The display state machine flips a run from `planning` → `awaitingReview`
    /// only when BOTH `plan.json` (runtime source of truth) AND `crafted.md`
    /// (human source of truth) are on disk. They are written in the same
    /// architect step so this is a tight window — but checking both prevents
    /// us from showing the review modal against a half-written file.
    static func craftedExistsOnDisk(_ run: DispatchRun) -> Bool {
        FileManager.default.fileExists(atPath: craftedFileURL(run).path)
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
    /// Synchronous form — kept for non-spawn callers (tests, migrations,
    /// deletion paths) where blocking is fine.
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

    /// Off-main reset+brief-write for the architect spawn path. Mirrors
    /// `EternalService.resetAndWriteBriefOffMain`. Snapshots all paths +
    /// the brief on @MainActor, runs the FS work in a detached task at
    /// `.userInitiated`. The architect process reads `dispatch.md`
    /// after boot — a tens-of-ms late arrival is fine.
    static func resetPlanOffMain(
        rootPath: String,
        planPath: String,
        phasesDirPath: String,
        dispatchPath: String,
        brief: String
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                try? fm.createDirectory(
                    atPath: rootPath,
                    withIntermediateDirectories: true
                )
                try? fm.removeItem(atPath: planPath)
                if fm.fileExists(atPath: phasesDirPath) {
                    try? fm.removeItem(atPath: phasesDirPath)
                }
                try? fm.createDirectory(
                    atPath: phasesDirPath,
                    withIntermediateDirectories: true
                )
                try? brief.write(
                    toFile: dispatchPath,
                    atomically: true,
                    encoding: .utf8
                )
                cont.resume()
            }
        }
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

        // SIGKILL: we're removing the dir; any open fds from linked
        // architect/phase tiles must release before `removeItem`
        // runs. See `EternalService.deleteRun` for the full rationale.
        let linked = terminalManager.sessions.filter { $0.dispatchRunID == run.id }
        for session in linked {
            terminalManager.terminateSession(session.id, hard: true)
        }

        modelContext.delete(run)
        try? modelContext.save()

        // Async removal with retry — kernel needs a moment to reap
        // SIGKILL'd processes before their file descriptors close.
        Task { @MainActor in
            await Self.removeRunDirWithRetry(runDir, label: "DispatchPlanService")
        }
    }

    private static func removeRunDirWithRetry(_ runDir: URL, label: String) async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runDir.path) else { return }

        try? await Task.sleep(nanoseconds: 200_000_000)
        do {
            try fm.removeItem(at: runDir)
            return
        } catch {
            NSLog("\(label): first removeItem attempt on \(runDir.path) failed: \(error). Retrying after 1s.")
        }

        try? await Task.sleep(nanoseconds: 1_000_000_000)
        do {
            try fm.removeItem(at: runDir)
        } catch let error as NSError {
            NSLog("\(label): deleteRun failed to remove \(runDir.path) after retry. code=\(error.code) domain=\(error.domain) userInfo=\(error.userInfo)")
        } catch {
            NSLog("\(label): deleteRun failed to remove \(runDir.path) after retry: \(error)")
        }
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

        // Off-main reset: snapshot every path + the brief on @MainActor,
        // run the FS work (3 removeItem syscalls + 2 createDirectory +
        // a `dispatch.md` write) in a detached task. Mirrors the
        // architect/worker fix in EternalService.
        let dispatchRootPath = dispatchRoot(run).path
        let planPath = planFileURL(run).path
        let phasesDirPath = phasesDirURL(run).path
        let dispatchPath = dispatchFileURL(run).path
        let dispatchBrief = run.brief
        Task.detached(priority: .userInitiated) {
            await DispatchPlanService.resetPlanOffMain(
                rootPath: dispatchRootPath,
                planPath: planPath,
                phasesDirPath: phasesDirPath,
                dispatchPath: dispatchPath,
                brief: dispatchBrief
            )
        }

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
        // Kanban-mode runs park the architect in column 0 of the run's
        // lane. Grid-mode falls back to the historical behavior — flat
        // grid via `position(forIndex:)`. Persisting the kanban
        // coordinates onto the TodoItem means the canvas renderer (which
        // reads `session.canvasPosition`) snaps the tile into place
        // automatically; no per-frame mode branch needed.
        let position = (run.dispatchMode == "kanban")
            ? CanvasLayout.kanbanPosition(columnIndex: 0, rowInColumn: 0)
            : CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

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
        // Kanban-mode: phase 1 lives in column 1 (column 0 is the
        // architect). Grid-mode falls back to the flat-grid placement
        // that's been the dispatch default since v0.6.
        let position = (run.dispatchMode == "kanban")
            ? CanvasLayout.kanbanPosition(columnIndex: phase.order, rowInColumn: 0)
            : CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

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

    /// Called from the Plan Review modal's Accept button. Architect has
    /// finished, the user has read crafted.md, and approved the plan —
    /// kick off phase 1 immediately. No intermediate `ready` state, no
    /// second-click required: review IS the gate, accept IS the launch.
    /// Returns false if plan.json or phase 1 is somehow missing (race
    /// against architect cleanup); the modal surfaces that as a
    /// "still planning" hint via its caller.
    @MainActor
    @discardableResult
    static func acceptReview(
        run: DispatchRun,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> Bool {
        return startPhaseOne(
            run: run,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
    }

    // MARK: - Kanban materialization

    /// Decode every `phases/*.json` for one run and return the parsed
    /// list, sorted ascending by `order`. Used by the kanban
    /// materializer (and the test harness) to turn the on-disk plan
    /// into something we can iterate without the SwiftUI runtime in
    /// the loop.
    static func allPhases(_ run: DispatchRun) -> [PhaseJSON] {
        let fm = FileManager.default
        let phasesDir = phasesDirURL(run)
        guard let files = try? fm.contentsOfDirectory(at: phasesDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        let phases: [PhaseJSON] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(PhaseJSON.self, from: data)
            }
        return phases.sorted { $0.order < $1.order }
    }

    /// Reconcile `KanbanColumn` rows for a kanban-mode dispatch run with
    /// the architect's plan on disk. Idempotent — safe to call on every
    /// `plan.json` write event. Always seeds an "Architect" column at
    /// orderIndex 0 so the architect tile has a labeled lane even before
    /// the architect finishes planning. For each phase: upsert by
    /// `columnKey = "<run.shortID>-<order>"` so re-plans that keep the
    /// same phase order can update the title without churning the row.
    /// Phases removed by a re-plan get their KanbanColumn rows deleted
    /// so the canvas doesn't show empty zombie lanes; tile data on those
    /// rows is unaffected (tiles are owned by TodoItem / TerminalSession,
    /// not by KanbanColumn).
    @MainActor
    static func materializeKanbanColumns(run: DispatchRun, modelContext: ModelContext) {
        guard run.dispatchMode == "kanban" else { return }
        guard let project = run.project else { return }

        let runID = run.id
        let descriptor = FetchDescriptor<KanbanColumn>(
            predicate: #Predicate<KanbanColumn> { col in
                col.kind == "dispatch-phase" && col.dispatchRunID == runID
            }
        )
        var existing: [String: KanbanColumn] = [:]
        for col in (try? modelContext.fetch(descriptor)) ?? [] {
            existing[col.columnKey] = col
        }

        // Architect lane lives at orderIndex 0. Always present, even
        // when planning hasn't started.
        let architectKey = KanbanColumn.dispatchPhaseColumnKey(
            runShortID: run.shortID,
            order: 0
        )
        if let arch = existing.removeValue(forKey: architectKey) {
            arch.title = "Architect"
            arch.orderIndex = 0
            arch.project = project
        } else {
            let arch = KanbanColumn(
                project: project,
                kind: "dispatch-phase",
                columnKey: architectKey,
                title: "Architect",
                orderIndex: 0,
                dispatchRunID: run.id
            )
            modelContext.insert(arch)
        }

        // One column per phase. PhaseJSON.order is 1-based per the
        // architect prompt contract; we use it directly as orderIndex
        // so the architect's lane (0) and phase lanes (1..N) sort
        // correctly.
        for phase in allPhases(run) {
            let key = KanbanColumn.dispatchPhaseColumnKey(
                runShortID: run.shortID,
                order: phase.order
            )
            if let col = existing.removeValue(forKey: key) {
                col.title = phase.title
                col.orderIndex = phase.order
                col.project = project
            } else {
                let col = KanbanColumn(
                    project: project,
                    kind: "dispatch-phase",
                    columnKey: key,
                    title: phase.title,
                    orderIndex: phase.order,
                    dispatchRunID: run.id
                )
                modelContext.insert(col)
            }
        }

        // Anything left in `existing` is a column whose phase the
        // re-plan removed. Drop it so the canvas doesn't show stale
        // lanes. Tile data is owned by TodoItem / TerminalSession;
        // deleting the column doesn't affect any spawned tile.
        for orphan in existing.values {
            modelContext.delete(orphan)
        }

        try? modelContext.save()
    }
}
