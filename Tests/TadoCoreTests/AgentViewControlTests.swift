import CoreGraphics
import SwiftData
import XCTest
@testable import Tado

final class AgentViewControlTests: XCTestCase {
    func testAgentWorkSorterPrioritizesNeedsInputThenRunningThenQueued() {
        let base = Date(timeIntervalSince1970: 100)
        let rows = AgentWorkSorter.sorted([
            AgentWorkRow(
                id: "todo",
                kind: .todo,
                title: "Queued",
                subtitle: "",
                status: "pending",
                projectName: nil,
                createdAt: base.addingTimeInterval(30),
                todoID: nil,
                sessionID: nil,
                runID: nil,
                promptable: false
            ),
            AgentWorkRow(
                id: "running",
                kind: .liveTile,
                title: "Running",
                subtitle: "",
                status: "running",
                projectName: nil,
                createdAt: base.addingTimeInterval(20),
                todoID: nil,
                sessionID: nil,
                runID: nil,
                promptable: true
            ),
            AgentWorkRow(
                id: "needs",
                kind: .liveTile,
                title: "Needs",
                subtitle: "",
                status: "needsInput",
                projectName: nil,
                createdAt: base.addingTimeInterval(10),
                todoID: nil,
                sessionID: nil,
                runID: nil,
                promptable: true
            ),
        ])

        XCTAssertEqual(rows.map(\.id), ["needs", "running", "todo"])
    }

    @MainActor
    func testTodoCreateHonorsExplicitCodexEngine() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let manager = TerminalManager()
        let appState = AppState()
        let request = try makeRequest(
            kind: "tado_use.todo_create",
            payload: [
                "text": "Use Codex for this",
                "spawn_tile": true,
                "engine": "codex",
            ]
        )

        let response = ControlRequestRouter.handle(
            request: request,
            terminalManager: manager,
            modelContext: context,
            appState: appState
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.engine, .codex)
        XCTAssertEqual(stringValue(response.data, key: "engine"), "codex")
    }

    @MainActor
    func testDispatchInterveneQueuesPromptOnCurrentPhaseTile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let manager = TerminalManager()
        let todoID = UUID()
        let session = manager.spawnSession(
            todoID: todoID,
            todoText: "Dispatch phase",
            canvasPosition: .zero,
            gridIndex: 1,
            engine: .claude
        )
        let run = DispatchRun(
            project: nil,
            label: "Dispatch",
            state: "dispatching",
            brief: "Ship it",
            architectTodoID: nil,
            currentPhaseTodoID: todoID
        )
        context.insert(run)
        try context.save()

        let response = ControlRequestRouter.handle(
            request: try makeRequest(
                kind: "tado_use.dispatch_intervene",
                payload: [
                    "run_id": run.id.uuidString,
                    "directive": "Please tighten the tests.",
                ]
            ),
            terminalManager: manager,
            modelContext: context,
            appState: AppState()
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(session.promptQueue.count, 1)
        XCTAssertTrue(session.promptQueue.first?.contains("Please tighten the tests.") == true)
    }

    @MainActor
    func testDispatchInterveneFailsWhenTargetTileIsNotLive() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let run = DispatchRun(
            project: nil,
            label: "Dispatch",
            state: "dispatching",
            brief: "Ship it",
            architectTodoID: nil,
            currentPhaseTodoID: UUID()
        )
        context.insert(run)
        try context.save()

        let response = ControlRequestRouter.handle(
            request: try makeRequest(
                kind: "tado_use.dispatch_intervene",
                payload: [
                    "run_id": run.id.uuidString,
                    "directive": "Where are we?",
                ]
            ),
            terminalManager: TerminalManager(),
            modelContext: context,
            appState: AppState()
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no_active_tile")
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

    private func makeRequest(kind: String, payload: [String: Any]) throws -> ControlRequest {
        let raw: [String: Any] = [
            "request_id": UUID().uuidString,
            "kind": kind,
            "payload": payload,
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(ControlRequest.self, from: data)
    }

    private func stringValue(_ data: AnyCodable?, key: String) -> String? {
        guard case .object(let object)? = data?.value,
              case .string(let value)? = object[key]?.value else {
            return nil
        }
        return value
    }
}
