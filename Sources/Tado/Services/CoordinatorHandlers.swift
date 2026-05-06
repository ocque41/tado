import Foundation
import SwiftData

// MARK: - Eternal handlers

/// Eternal-shaped request handlers for the Unix-socket router.
/// One static method per request kind. All run on the main actor
/// (SwiftData mutations) and return a `ControlResponseEnvelope`
/// the router writes back to the CLI client.
@MainActor
enum CoordinatorEternal {

    static func propose(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let projectName = payload.string("project") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "project required")
        }
        guard let task = payload.string("task"), !task.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "task required")
        }
        guard let coordTodoIDString = payload.string("coordinator_todo_id"),
              let coordTodoID = UUID(uuidString: coordTodoIDString) else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "coordinator_todo_id required")
        }

        guard let project = lookupProject(byName: projectName, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "no_project", message: "no project named '\(projectName)'")
        }

        let feature = payload.string("feature") ?? "coordinator-task"
        let mode = payload.string("mode") ?? "sprint"
        let engine = payload.string("engine") ?? project.defaultEngineForCoordinator()
        let label = payload.string("label")
            ?? "Coordinator: \(feature)"
        let brief = payload.string("brief") ?? task

        let run = EternalService.proposeViaCoordinator(
            project: project,
            label: label,
            userBrief: brief,
            mode: mode,
            engine: engine,
            coordinatorTodoID: coordTodoID,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )

        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "run_id": AnyCodable(run.id.uuidString),
            "project_id": AnyCodable(project.id.uuidString),
            "project_name": AnyCodable(project.name),
            "label": AnyCodable(run.label),
            "mode": AnyCodable(run.mode),
            "engine": AnyCodable(run.engine),
            "state": AnyCodable(run.state)
        ]))
    }

    static func status(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let run = lookupRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
        let craftedExists = EternalService.craftedExistsOnDisk(run)
        let isActive = EternalService.isActive(run)

        var dict: [String: AnyCodable] = [
            "run_id": AnyCodable(run.id.uuidString),
            "label": AnyCodable(run.label),
            "state": AnyCodable(run.state),
            "mode": AnyCodable(run.mode),
            "engine": AnyCodable(run.engine),
            "has_crafted": AnyCodable(craftedExists),
            "is_active": AnyCodable(isActive),
            "spawned_by_coordinator": AnyCodable(run.spawnedByCoordinatorTodoID != nil)
        ]
        if let project = run.project {
            dict["project_id"] = AnyCodable(project.id.uuidString)
            dict["project_name"] = AnyCodable(project.name)
            dict["project_root"] = AnyCodable(project.rootPath)
        }
        if craftedExists {
            dict["crafted_path"] = AnyCodable(EternalService.craftedFileURL(run).path)
        }
        if let st = EternalService.readState(run) {
            dict["phase"] = AnyCodable(st.phase)
            dict["iterations"] = AnyCodable(Int(st.iterations))
            dict["sprints"] = AnyCodable(Int(st.sprints))
            if let last = st.lastProgressNote {
                dict["last_progress_note"] = AnyCodable(last)
            }
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable(dict))
    }

    static func crafted(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let run = lookupRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
        guard let body = EternalService.readCrafted(run) else {
            return ControlRequestRouter.error(requestID, code: "not_ready", message: "crafted.md not on disk yet")
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "run_id": AnyCodable(run.id.uuidString),
            "state": AnyCodable(run.state),
            "crafted": AnyCodable(body)
        ]))
    }

    static func accept(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let run = lookupRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
        let note = payload.string("note")
        let result = EternalService.acceptReviewWithGuard(
            run: run,
            expectedState: "awaitingReview",
            reviewNote: note,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
        switch result {
        case .accepted:
            return ControlRequestRouter.ok(requestID, data: AnyCodable([
                "run_id": AnyCodable(run.id.uuidString),
                "state": AnyCodable(run.state)
            ]))
        case .stateMismatch(let actual):
            return ControlRequestRouter.error(
                requestID,
                code: "state_mismatch",
                message: "run is in state '\(actual)', not 'awaitingReview'",
                extra: [
                    "actual": AnyCodable(actual),
                    "expected": AnyCodable("awaitingReview"),
                    "run_id": AnyCodable(run.id.uuidString)
                ]
            )
        case .notFound:
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
    }

    static func reject(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let run = lookupRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
        let reason = payload.string("reason") ?? "rejected by coordinator"
        let rebrief = payload.string("rebrief")
        let result = EternalService.rejectReview(
            run: run,
            reason: reason,
            rebrief: rebrief,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
        switch result {
        case .rejected:
            return ControlRequestRouter.ok(requestID, data: AnyCodable([
                "run_id": AnyCodable(run.id.uuidString),
                "state": AnyCodable(run.state)
            ]))
        case .stateMismatch(let actual):
            return ControlRequestRouter.error(
                requestID,
                code: "state_mismatch",
                message: "run is in state '\(actual)', not 'awaitingReview'",
                extra: [
                    "actual": AnyCodable(actual),
                    "run_id": AnyCodable(run.id.uuidString)
                ]
            )
        case .notFound:
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
    }

    static func stop(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let run = lookupRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
        EternalService.requestStop(run)
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "run_id": AnyCodable(run.id.uuidString),
            "stop_requested": AnyCodable(true)
        ]))
    }

    static func list(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        let descriptor = FetchDescriptor<EternalRun>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let allRuns = (try? modelContext.fetch(descriptor)) ?? []
        let projectFilter = payload.string("project")?.lowercased()
        let stateFilter = payload.string("state")
        let entries = allRuns
            .filter { run in
                if let projectFilter, run.project?.name.lowercased() != projectFilter { return false }
                if let stateFilter, run.state != stateFilter { return false }
                return true
            }
            .map { run -> AnyCodable in
                AnyCodable([
                    "run_id": AnyCodable(run.id.uuidString),
                    "label": AnyCodable(run.label),
                    "state": AnyCodable(run.state),
                    "mode": AnyCodable(run.mode),
                    "engine": AnyCodable(run.engine),
                    "project_name": AnyCodable(run.project?.name ?? ""),
                    "project_root": AnyCodable(run.project?.rootPath ?? ""),
                    "spawned_by_coordinator": AnyCodable(run.spawnedByCoordinatorTodoID != nil),
                    "created_at": AnyCodable(ISO8601DateFormatter().string(from: run.createdAt))
                ])
            }
        return ControlRequestRouter.ok(requestID, data: AnyCodable(entries))
    }

    // MARK: - Helpers

    private static func lookupRun(
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> EternalRun? {
        guard let runIDString = payload.string("run_id"),
              let runID = UUID(uuidString: runIDString) else {
            return nil
        }
        let descriptor = FetchDescriptor<EternalRun>()
        return (try? modelContext.fetch(descriptor))?.first(where: { $0.id == runID })
    }
}

// MARK: - Dispatch handlers

@MainActor
enum CoordinatorDispatch {

    static func propose(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let projectName = payload.string("project") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "project required")
        }
        guard let task = payload.string("task"), !task.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "task required")
        }
        guard let coordTodoIDString = payload.string("coordinator_todo_id"),
              let coordTodoID = UUID(uuidString: coordTodoIDString) else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "coordinator_todo_id required")
        }

        guard let project = lookupProject(byName: projectName, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "no_project", message: "no project named '\(projectName)'")
        }

        let feature = payload.string("feature") ?? "coordinator-task"
        let label = payload.string("label") ?? "Coordinator: \(feature)"
        let brief = payload.string("brief") ?? task

        let run = DispatchPlanService.proposeViaCoordinator(
            project: project,
            label: label,
            brief: brief,
            coordinatorTodoID: coordTodoID,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )

        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "run_id": AnyCodable(run.id.uuidString),
            "project_id": AnyCodable(project.id.uuidString),
            "project_name": AnyCodable(project.name),
            "label": AnyCodable(run.label),
            "state": AnyCodable(run.state)
        ]))
    }

    static func status(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let run = lookupRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
        let craftedExists = DispatchPlanService.craftedExistsOnDisk(run)
        let planExists = DispatchPlanService.planExistsOnDisk(run)
        let phaseCount = DispatchPlanService.phaseFileCount(run)

        var dict: [String: AnyCodable] = [
            "run_id": AnyCodable(run.id.uuidString),
            "label": AnyCodable(run.label),
            "state": AnyCodable(run.state),
            "has_crafted": AnyCodable(craftedExists),
            "has_plan": AnyCodable(planExists),
            "phase_count": AnyCodable(phaseCount),
            "spawned_by_coordinator": AnyCodable(run.spawnedByCoordinatorTodoID != nil)
        ]
        if let project = run.project {
            dict["project_id"] = AnyCodable(project.id.uuidString)
            dict["project_name"] = AnyCodable(project.name)
            dict["project_root"] = AnyCodable(project.rootPath)
        }
        if craftedExists {
            dict["crafted_path"] = AnyCodable(DispatchPlanService.craftedFileURL(run).path)
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable(dict))
    }

    static func crafted(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let run = lookupRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
        let craftedURL = DispatchPlanService.craftedFileURL(run)
        guard let body = try? String(contentsOf: craftedURL, encoding: .utf8) else {
            return ControlRequestRouter.error(requestID, code: "not_ready", message: "crafted.md not on disk yet")
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "run_id": AnyCodable(run.id.uuidString),
            "state": AnyCodable(run.state),
            "crafted": AnyCodable(body)
        ]))
    }

    static func accept(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let run = lookupRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
        let note = payload.string("note")
        let result = DispatchPlanService.acceptReviewWithGuard(
            run: run,
            expectedState: "awaitingReview",
            reviewNote: note,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
        switch result {
        case .accepted:
            return ControlRequestRouter.ok(requestID, data: AnyCodable([
                "run_id": AnyCodable(run.id.uuidString),
                "state": AnyCodable(run.state)
            ]))
        case .stateMismatch(let actual):
            return ControlRequestRouter.error(
                requestID,
                code: "state_mismatch",
                message: "run is in state '\(actual)', not 'awaitingReview'",
                extra: [
                    "actual": AnyCodable(actual),
                    "run_id": AnyCodable(run.id.uuidString)
                ]
            )
        case .notFound:
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
    }

    static func reject(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let run = lookupRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
        let reason = payload.string("reason") ?? "rejected by coordinator"
        let rebrief = payload.string("rebrief")
        let result = DispatchPlanService.rejectReview(
            run: run,
            reason: reason,
            rebrief: rebrief,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )
        switch result {
        case .rejected:
            return ControlRequestRouter.ok(requestID, data: AnyCodable([
                "run_id": AnyCodable(run.id.uuidString),
                "state": AnyCodable(run.state)
            ]))
        case .stateMismatch(let actual):
            return ControlRequestRouter.error(
                requestID,
                code: "state_mismatch",
                message: "run is in state '\(actual)', not 'awaitingReview'",
                extra: [
                    "actual": AnyCodable(actual),
                    "run_id": AnyCodable(run.id.uuidString)
                ]
            )
        case .notFound:
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
    }

    static func list(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        let descriptor = FetchDescriptor<DispatchRun>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let allRuns = (try? modelContext.fetch(descriptor)) ?? []
        let projectFilter = payload.string("project")?.lowercased()
        let stateFilter = payload.string("state")
        let entries = allRuns
            .filter { run in
                if let projectFilter, run.project?.name.lowercased() != projectFilter { return false }
                if let stateFilter, run.state != stateFilter { return false }
                return true
            }
            .map { run -> AnyCodable in
                AnyCodable([
                    "run_id": AnyCodable(run.id.uuidString),
                    "label": AnyCodable(run.label),
                    "state": AnyCodable(run.state),
                    "project_name": AnyCodable(run.project?.name ?? ""),
                    "project_root": AnyCodable(run.project?.rootPath ?? ""),
                    "spawned_by_coordinator": AnyCodable(run.spawnedByCoordinatorTodoID != nil),
                    "created_at": AnyCodable(ISO8601DateFormatter().string(from: run.createdAt))
                ])
            }
        return ControlRequestRouter.ok(requestID, data: AnyCodable(entries))
    }

    private static func lookupRun(
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> DispatchRun? {
        guard let runIDString = payload.string("run_id"),
              let runID = UUID(uuidString: runIDString) else {
            return nil
        }
        let descriptor = FetchDescriptor<DispatchRun>()
        return (try? modelContext.fetch(descriptor))?.first(where: { $0.id == runID })
    }
}

// MARK: - Bootstrap handlers

@MainActor
enum CoordinatorBootstrap {

    static func run(
        kind: String,
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let projectName = payload.string("project") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "project required")
        }
        guard let project = lookupProject(byName: projectName, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "no_project", message: "no project named '\(projectName)'")
        }

        switch kind {
        case "bootstrap.a2a":
            ProjectActionsService.bootstrapTools(
                project: project,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )
        case "bootstrap.team":
            // bootstrapTeam needs the project's teams. Fetch the
            // current set; bootstrap is a no-op when empty (matches
            // the UI menu's disabled state).
            let teamDescriptor = FetchDescriptor<Team>()
            let teams = (try? modelContext.fetch(teamDescriptor))?.filter { $0.projectID == project.id } ?? []
            if teams.isEmpty {
                return ControlRequestRouter.error(requestID, code: "no_teams", message: "project '\(project.name)' has no teams; bootstrap-team is a no-op")
            }
            ProjectActionsService.bootstrapTeam(
                project: project,
                teams: teams,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )
        case "bootstrap.auto-mode":
            ProjectActionsService.bootstrapAutoMode(
                project: project,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )
        case "bootstrap.knowledge":
            ProjectActionsService.bootstrapKnowledge(
                project: project,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )
        default:
            return ControlRequestRouter.error(requestID, code: "unknown_kind", message: "unknown bootstrap kind: \(kind)")
        }

        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "kind": AnyCodable(kind),
            "project_id": AnyCodable(project.id.uuidString),
            "project_name": AnyCodable(project.name)
        ]))
    }
}

// MARK: - Shared helpers

@MainActor
fileprivate func lookupProject(byName name: String, modelContext: ModelContext) -> Project? {
    let descriptor = FetchDescriptor<Project>()
    let projects = (try? modelContext.fetch(descriptor)) ?? []
    let lower = name.lowercased()
    if let exact = projects.first(where: { $0.name.lowercased() == lower }) {
        return exact
    }
    let candidates = projects.filter { $0.name.lowercased().contains(lower) }
    if candidates.count == 1 {
        return candidates.first
    }
    return nil
}

extension Project {
    /// Best-guess engine for a coordinator-driven run when the
    /// brief doesn't pin one. Falls back to claude — Opus 4.7 is
    /// the recommended driver for both architects and workers.
    func defaultEngineForCoordinator() -> String {
        return "claude"
    }
}
