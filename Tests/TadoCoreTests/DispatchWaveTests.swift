import CoreGraphics
import SwiftData
import XCTest
@testable import Tado

final class DispatchWaveTests: XCTestCase {
    func testDispatchRunDefaultsToSequential() {
        let run = DispatchRun(project: nil, label: "Dispatch")
        XCTAssertEqual(run.executionType, "sequential")
        XCTAssertEqual(run.normalizedExecutionType, "sequential")
    }

    func testOldPhaseJSONDecodesWithoutCompletionMetadata() throws {
        let data = #"""
        {
          "id": "phase-one",
          "order": 1,
          "title": "Phase One",
          "skill": "dispatch-demo-12345678-phase-one",
          "agent": null,
          "engine": "claude",
          "prompt": "Do the work",
          "nextPhaseFile": null,
          "status": "pending"
        }
        """#.data(using: .utf8)!
        let phase = try JSONDecoder().decode(PhaseJSON.self, from: data)
        XCTAssertEqual(phase.id, "phase-one")
        XCTAssertNil(phase.completedBySessionID)
        XCTAssertNil(phase.completedAt)
    }

    func testArchitectPromptSwitchesSequentialAndWaveContracts() {
        let runID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let sequential = ProcessSpawner.dispatchArchitectPrompt(
            projectName: "Demo",
            projectRoot: "/tmp/demo",
            runID: runID,
            executionType: "sequential",
            dispatchMode: "grid"
        )
        let wave = ProcessSpawner.dispatchArchitectPrompt(
            projectName: "Demo",
            projectRoot: "/tmp/demo",
            runID: runID,
            executionType: "wave",
            dispatchMode: "kanban"
        )

        XCTAssertTrue(sequential.contains("execution-type:   sequential"))
        XCTAssertTrue(sequential.contains("each phase prompt deploys the next phase"))
        XCTAssertTrue(wave.contains("execution-type:   wave"))
        XCTAssertTrue(wave.contains("wave-completion.lock"))
        XCTAssertTrue(wave.contains("wave-review-sent.marker"))
        XCTAssertTrue(wave.contains("owned-scope and out-of-scope lists"))
    }

    func testCodexAgentFrontmatterMapsToCodexFlags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tado-dispatch-codex-agent-\(UUID().uuidString)")
        try writeCodexAgent(projectRoot: root.path, name: "codex-phase", model: "gpt-5.4-mini", effort: "max")

        let override = AgentDiscoveryService.phaseOverride(
            agentName: "codex-phase",
            projectRoot: root.path,
            engine: .codex
        )

        XCTAssertEqual(override.modelFlags ?? [], ["-c", "model=\"gpt-5.4-mini\""])
        XCTAssertEqual(override.effortFlags ?? [], ["-c", "model_reasoning_effort=\"xhigh\""])
    }

    @MainActor
    func testSequentialAcceptStartsOnlyFirstPhase() throws {
        let fixture = try makeRun(executionType: "sequential", dispatchMode: "grid")
        try writePhaseFiles(fixture.run, phases: [
            phase(id: "one", order: 1, title: "One", engine: "codex", prompt: "first"),
            phase(id: "two", order: 2, title: "Two", engine: "claude", prompt: "second"),
        ])
        let manager = TerminalManager()

        XCTAssertTrue(DispatchPlanService.startPhaseOne(
            run: fixture.run,
            modelContext: fixture.context,
            terminalManager: manager,
            appState: AppState()
        ))

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.todoText, "first")
        XCTAssertEqual(manager.sessions.first?.engine, .codex)
    }

    @MainActor
    func testWaveAcceptStartsAllPhasesWithOverridesAndKanbanPositions() throws {
        let fixture = try makeRun(executionType: "wave", dispatchMode: "kanban")
        try writeAgent(projectRoot: fixture.project.rootPath, name: "phase-one", model: "haiku", effort: "max")
        try writeCodexAgent(projectRoot: fixture.project.rootPath, name: "phase-two", model: "gpt-5.4", effort: "high")
        try writePhaseFiles(fixture.run, phases: [
            phase(id: "one", order: 1, title: "One", engine: nil, agent: "phase-one", prompt: "first"),
            phase(id: "two", order: 2, title: "Two", engine: "codex", agent: "phase-two", prompt: "second"),
        ])
        let manager = TerminalManager()

        XCTAssertTrue(DispatchPlanService.startPhaseOne(
            run: fixture.run,
            modelContext: fixture.context,
            terminalManager: manager,
            appState: AppState()
        ))

        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(manager.sessions.map(\.todoText), ["first", "second"])
        XCTAssertEqual(manager.sessions[0].dispatchRunID, fixture.run.id)
        XCTAssertEqual(manager.sessions[0].runRole, "phase")
        XCTAssertEqual(manager.sessions[0].engine, .claude)
        XCTAssertEqual(manager.sessions[0].modelFlagsOverride ?? [], ["--model", "claude-haiku-4-5"])
        XCTAssertEqual(manager.sessions[0].effortFlagsOverride ?? [], ["--effort", "max"])
        XCTAssertEqual(manager.sessions[0].canvasPosition, CanvasLayout.kanbanPosition(columnIndex: 1, rowInColumn: 0))
        XCTAssertEqual(manager.sessions[1].engine, .codex)
        XCTAssertEqual(manager.sessions[1].modelFlagsOverride ?? [], ["-c", "model=\"gpt-5.4\""])
        XCTAssertEqual(manager.sessions[1].effortFlagsOverride ?? [], ["-c", "model_reasoning_effort=\"high\""])
        XCTAssertEqual(manager.sessions[1].canvasPosition, CanvasLayout.kanbanPosition(columnIndex: 2, rowInColumn: 0))
    }

    @MainActor
    private func makeRun(executionType: String, dispatchMode: String) throws -> (
        container: ModelContainer,
        context: ModelContext,
        project: Project,
        run: DispatchRun
    ) {
        let container = try makeContainer()
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tado-dispatch-wave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = Project(name: "Demo", rootPath: root.path)
        let run = DispatchRun(
            project: project,
            label: "Dispatch",
            state: "awaitingReview",
            brief: "Build it",
            dispatchMode: dispatchMode,
            executionType: executionType
        )
        context.insert(project)
        context.insert(run)
        context.insert(AppSettings())
        try context.save()
        return (container, context, project, run)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            TodoItem.self, AppSettings.self, Project.self,
            Team.self, EternalRun.self, DispatchRun.self,
            KanbanColumn.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func phase(
        id: String,
        order: Int,
        title: String,
        engine: String?,
        agent: String? = nil,
        prompt: String
    ) -> PhaseJSON {
        PhaseJSON(
            id: id,
            order: order,
            title: title,
            skill: "dispatch-demo-12345678-\(id)",
            agent: agent,
            engine: engine,
            prompt: prompt,
            nextPhaseFile: nil,
            status: "pending"
        )
    }

    private func writePhaseFiles(_ run: DispatchRun, phases: [PhaseJSON]) throws {
        let fm = FileManager.default
        let root = DispatchPlanService.dispatchRoot(run)
        let phasesDir = DispatchPlanService.phasesDirURL(run)
        try fm.createDirectory(at: phasesDir, withIntermediateDirectories: true)
        try #"{"status":"ready"}"#.write(to: DispatchPlanService.planFileURL(run), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for phase in phases {
            let url = phasesDir.appendingPathComponent("\(phase.order)-\(phase.id).json")
            try encoder.encode(phase).write(to: url)
        }
        XCTAssertTrue(fm.fileExists(atPath: root.path))
    }

    private func writeAgent(projectRoot: String, name: String, model: String, effort: String) throws {
        let dir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = """
        ---
        name: \(name)
        description: Dispatch phase agent for Demo - test agent.
        model: \(model)
        effort: \(effort)
        tools:
          - Read
          - Bash
        ---
        """
        try body.write(to: dir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }

    private func writeCodexAgent(projectRoot: String, name: String, model: String, effort: String) throws {
        let dir = URL(fileURLWithPath: projectRoot).appendingPathComponent(".codex/agents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = """
        ---
        name: \(name)
        description: Dispatch phase agent for Demo - test agent.
        model: \(model)
        effort: \(effort)
        tools:
          - Read
          - Bash
        ---
        """
        try body.write(to: dir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }
}
