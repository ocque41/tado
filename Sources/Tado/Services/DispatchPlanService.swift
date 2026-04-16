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

    /// Clear plan.json and all phases/*.json, then write the current project.dispatchMarkdown to dispatch.md.
    /// Creates the directory tree if missing.
    static func resetPlan(_ project: Project) {
        let fm = FileManager.default
        let root = dispatchRoot(project)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        let planURL = planFileURL(project)
        try? fm.removeItem(at: planURL)

        let phasesDir = phasesDirURL(project)
        if fm.fileExists(atPath: phasesDir.path) {
            try? fm.removeItem(at: phasesDir)
        }
        try? fm.createDirectory(at: phasesDir, withIntermediateDirectories: true)

        let dispatchURL = dispatchFileURL(project)
        try? project.dispatchMarkdown.write(to: dispatchURL, atomically: true, encoding: .utf8)
    }

    /// Parse every .json in phases/ and return the one with order == 1, or nil.
    static func firstPhase(_ project: Project) -> PhaseJSON? {
        let fm = FileManager.default
        let phasesDir = phasesDirURL(project)
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

    /// Spawn the dispatch architect terminal using the current selected harness.
    /// Writes dispatch.md from project.dispatchMarkdown, clears any existing plan,
    /// transitions the project state to "planning", and navigates to the canvas.
    @MainActor
    static func spawnArchitect(
        project: Project,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        resetPlan(project)

        let settings = fetchOrCreateSettings(modelContext: modelContext)
        let prompt = ProcessSpawner.dispatchArchitectPrompt(
            projectName: project.name,
            projectRoot: project.rootPath
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
            projectName: project.name
        )

        project.dispatchState = "planning"
        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    /// Launch phase 1 using the architect-authored prompt. Returns false if plan.json is missing
    /// or no phase has order == 1 — caller should show a "still planning" message in that case.
    @MainActor
    @discardableResult
    static func startPhaseOne(
        project: Project,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> Bool {
        guard planExistsOnDisk(project), let phase = firstPhase(project) else {
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
            projectName: project.name
        )

        project.dispatchState = "dispatching"
        try? modelContext.save()

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
        return true
    }
}
