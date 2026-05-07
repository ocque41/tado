import Foundation
import SwiftData
import SwiftUI
import AppKit

/// Tado Use bridge — autonomous control surface. Handlers for the
/// 30+ in-process tools that turn the drawer's headless agent into
/// a fully autonomous operator: it can create todos, kick off
/// eternals (architect → auto-accept → worker), trigger dispatches,
/// run bootstraps, mutate settings, ingest codebases into Dome,
/// publish notifications, send messages to running tiles, open
/// extension windows, and manage Kanban columns.
///
/// Wire shape: same ControlRequest envelope every other surface
/// uses. Kinds prefixed `tado_use.<verb>`. Routed from
/// `ControlRequestRouter.handle` via the `TadoUseBridgeHandlers`
/// fall-through, then dispatched here.
///
/// Autonomous eternal/dispatch flow: when the agent calls
/// `tado_use.eternal_start` (or dispatch_start), the handler
/// proposes the run AND blocks (for up to ~120s) polling for the
/// architect's `crafted.md`. As soon as the run state hits
/// `awaitingReview`, the handler auto-accepts on the operator's
/// behalf and returns the run id. The agent then sees a single
/// "started" response and the worker is already running. This
/// converts a 3-step interactive flow (propose → human review →
/// accept) into a single tool call, fulfilling the operator's
/// "tell it to start an eternal and walk away" intent.
///
/// All handlers run on `@MainActor` because they touch SwiftData
/// or AppState. They tag downstream events with `actor=tado_use`
/// so audit logs separate Use's drives from human clicks.
@MainActor
enum TadoUseAutonomousHandlers {
    /// Whitelist of `ControlRequest.kind` values this surface owns.
    /// Checked by `TadoUseBridgeHandlers.kinds` (which delegates
    /// here for any kind in this set).
    static let kinds: Set<String> = [
        // Todo lifecycle
        "tado_use.todo_create",
        "tado_use.todo_list",
        "tado_use.todo_move",
        "tado_use.todo_delete",
        // Project mgmt
        "tado_use.project_list",
        "tado_use.project_create",
        "tado_use.project_resolve",
        "tado_use.project_delete",
        // Eternal — propose / accept / reject
        "tado_use.eternal_start",
        "tado_use.eternal_accept",
        "tado_use.eternal_reject",
        "tado_use.eternal_list",
        "tado_use.eternal_status",
        "tado_use.eternal_stop",
        "tado_use.eternal_intervene",
        // Dispatch — propose / accept / reject
        "tado_use.dispatch_start",
        "tado_use.dispatch_accept",
        "tado_use.dispatch_reject",
        "tado_use.dispatch_list",
        "tado_use.dispatch_status",
        // Bootstraps
        "tado_use.bootstrap",
        // Settings
        "tado_use.settings_get",
        "tado_use.settings_set",
        // Dome
        "tado_use.dome_ingest_codebase",
        "tado_use.dome_code_status",
        "tado_use.dome_code_search",
        "tado_use.dome_note_create",
        "tado_use.dome_note_search",
        "tado_use.dome_recipe_apply",
        "tado_use.dome_agent_status",
        // Extensions
        "tado_use.extension_open",
        "tado_use.extension_list",
        // Notifications + tile control
        "tado_use.notify",
        "tado_use.tile_send",
        "tado_use.tile_read",
        "tado_use.tile_terminate",
        "tado_use.events_query",
    ]

    static func handle(
        kind: String,
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        switch kind {
        // Todos
        case "tado_use.todo_create":
            return todoCreate(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext, appState: appState)
        case "tado_use.todo_list":
            return todoList(requestID: requestID, payload: payload, modelContext: modelContext)
        case "tado_use.todo_move":
            return todoMove(requestID: requestID, payload: payload, modelContext: modelContext)
        case "tado_use.todo_delete":
            return todoDelete(requestID: requestID, payload: payload, modelContext: modelContext)

        // Projects
        case "tado_use.project_list":
            return projectList(requestID: requestID, modelContext: modelContext)
        case "tado_use.project_create":
            return projectCreate(requestID: requestID, payload: payload, modelContext: modelContext)
        case "tado_use.project_resolve":
            return projectResolve(requestID: requestID, payload: payload, modelContext: modelContext)
        case "tado_use.project_delete":
            return projectDelete(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext, appState: appState)

        // Eternal
        case "tado_use.eternal_start":
            return eternalStartAutonomous(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext, appState: appState)
        case "tado_use.eternal_accept":
            return eternalAccept(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext, appState: appState)
        case "tado_use.eternal_reject":
            return eternalReject(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext, appState: appState)
        case "tado_use.eternal_list":
            return eternalList(requestID: requestID, payload: payload, modelContext: modelContext)
        case "tado_use.eternal_status":
            return eternalStatus(requestID: requestID, payload: payload, modelContext: modelContext)
        case "tado_use.eternal_stop":
            return eternalStop(requestID: requestID, payload: payload, modelContext: modelContext)
        case "tado_use.eternal_intervene":
            return eternalIntervene(requestID: requestID, payload: payload, modelContext: modelContext)

        // Dispatch
        case "tado_use.dispatch_start":
            return dispatchStartAutonomous(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext, appState: appState)
        case "tado_use.dispatch_accept":
            return dispatchAccept(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext, appState: appState)
        case "tado_use.dispatch_reject":
            return dispatchReject(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext, appState: appState)
        case "tado_use.dispatch_list":
            return dispatchList(requestID: requestID, payload: payload, modelContext: modelContext)
        case "tado_use.dispatch_status":
            return dispatchStatus(requestID: requestID, payload: payload, modelContext: modelContext)

        // Bootstraps
        case "tado_use.bootstrap":
            return bootstrap(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext, appState: appState)

        // Settings
        case "tado_use.settings_get":
            return settingsGet(requestID: requestID)
        case "tado_use.settings_set":
            return settingsSet(requestID: requestID, payload: payload)

        // Dome
        case "tado_use.dome_ingest_codebase":
            return domeIngestCodebase(requestID: requestID, payload: payload, modelContext: modelContext)
        case "tado_use.dome_code_status":
            return domeCodeStatus(requestID: requestID)
        case "tado_use.dome_code_search":
            return domeCodeSearch(requestID: requestID, payload: payload)
        case "tado_use.dome_note_create":
            return domeNoteCreate(requestID: requestID, payload: payload)
        case "tado_use.dome_note_search":
            return domeNoteSearch(requestID: requestID, payload: payload)
        case "tado_use.dome_recipe_apply":
            return domeRecipeApply(requestID: requestID, payload: payload)
        case "tado_use.dome_agent_status":
            return domeAgentStatus(requestID: requestID, payload: payload)

        // Extensions
        case "tado_use.extension_open":
            return extensionOpen(requestID: requestID, payload: payload, appState: appState)
        case "tado_use.extension_list":
            return extensionList(requestID: requestID)

        // Notifications + tile control
        case "tado_use.notify":
            return notify(requestID: requestID, payload: payload)
        case "tado_use.tile_send":
            return tileSend(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext)
        case "tado_use.tile_read":
            return tileRead(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext)
        case "tado_use.tile_terminate":
            return tileTerminate(requestID: requestID, payload: payload, terminalManager: terminalManager, modelContext: modelContext)
        case "tado_use.events_query":
            return eventsQuery(requestID: requestID, payload: payload)

        default:
            return ControlRequestRouter.error(requestID, code: "unknown_kind", message: "no handler for \(kind)")
        }
    }

    // MARK: - Todos

    private static func todoCreate(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let text = payload.string("text"), !text.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "text required")
        }
        // Fall back to the canvas's active-project filter when the
        // caller doesn't specify a project. Without this fallback the
        // todo lands with projectID=nil and CanvasView.filteredSessions
        // hides it from the user's currently-viewed zone — which the
        // user reads as "nothing happened".
        let project: Project? = {
            if let explicit = resolveProject(payload: payload, modelContext: modelContext) {
                return explicit
            }
            guard let activeID = appState.activeProjectID else { return nil }
            let descriptor = FetchDescriptor<Project>()
            let projects = (try? modelContext.fetch(descriptor)) ?? []
            return projects.first { $0.id == activeID }
        }()
        let spawnTile = payload.bool("spawn_tile") ?? false
        let agentName = payload.string("agent")
        let teamName = payload.string("team")

        let gridIndex = nextGridIndex(modelContext: modelContext)
        let gridColumns = (try? modelContext.fetch(FetchDescriptor<AppSettings>()).first?.gridColumns) ?? 3
        let position = CanvasLayout.position(forIndex: gridIndex, gridColumns: gridColumns)

        let todo = TodoItem(text: text, gridIndex: gridIndex, canvasPosition: position)
        if let project {
            todo.projectID = project.id
        }
        if let agentName { todo.agentName = agentName }
        if let teamName, let project {
            let teamFetch = FetchDescriptor<Team>()
            let teams = (try? modelContext.fetch(teamFetch)) ?? []
            if let team = teams.first(where: { $0.projectID == project.id && $0.name == teamName }) {
                todo.teamID = team.id
            }
        }
        modelContext.insert(todo)

        if spawnTile {
            // Default to the project's coordinator engine, which falls
            // back to Claude when nothing else is set. Canvas tiles use
            // the same default everywhere else.
            let engine: TerminalEngine = TerminalEngine(rawValue: project?.defaultEngineForCoordinator() ?? "claude") ?? .claude
            terminalManager.spawnAndWire(
                todo: todo,
                engine: engine,
                cwd: project?.rootPath,
                projectName: project?.name
            )
        }
        try? modelContext.save()

        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "todo_id": AnyCodable(todo.id.uuidString),
            "grid_index": AnyCodable(gridIndex),
            "grid_label": AnyCodable(CanvasLayout.gridLabel(forIndex: gridIndex, gridColumns: gridColumns)),
            "spawned_tile": AnyCodable(spawnTile),
            "project_id": AnyCodable(project?.id.uuidString ?? ""),
        ]))
    }

    private static func todoList(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        let projectFilter = resolveProject(payload: payload, modelContext: modelContext)
        let stateFilter = payload.string("state")  // active | done | trashed
        let descriptor = FetchDescriptor<TodoItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        let filtered = todos.filter { todo in
            if let p = projectFilter, todo.projectID != p.id { return false }
            if let s = stateFilter, !s.isEmpty, todo.listState.rawValue != s { return false }
            return true
        }
        let entries = filtered.map { todo -> AnyCodable in
            AnyCodable([
                "todo_id": AnyCodable(todo.id.uuidString),
                "text": AnyCodable(todo.text),
                "list_state": AnyCodable(todo.listState.rawValue),
                "is_complete": AnyCodable(todo.isComplete),
                "status": AnyCodable(todo.status.rawValue),
                "grid_index": AnyCodable(todo.gridIndex),
                "project_id": AnyCodable(todo.projectID?.uuidString ?? ""),
                "agent": AnyCodable(todo.agentName ?? ""),
                "created_at": AnyCodable(ISO8601DateFormatter().string(from: todo.createdAt)),
            ])
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "todos": AnyCodable(entries),
            "count": AnyCodable(entries.count),
        ]))
    }

    private static func todoMove(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let todoIDStr = payload.string("todo_id"),
              let todoID = UUID(uuidString: todoIDStr) else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "todo_id required")
        }
        guard let toState = payload.string("to_state"),
              let target = ListState(rawValue: toState) else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "to_state required (active/done/trashed)")
        }
        let descriptor = FetchDescriptor<TodoItem>()
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        guard let todo = todos.first(where: { $0.id == todoID }) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "todo not found")
        }
        todo.listState = target
        if target == .done { todo.isComplete = true }
        try? modelContext.save()
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "todo_id": AnyCodable(todoID.uuidString),
            "list_state": AnyCodable(target.rawValue),
        ]))
    }

    private static func todoDelete(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let todoIDStr = payload.string("todo_id"),
              let todoID = UUID(uuidString: todoIDStr) else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "todo_id required")
        }
        let descriptor = FetchDescriptor<TodoItem>()
        let todos = (try? modelContext.fetch(descriptor)) ?? []
        guard let todo = todos.first(where: { $0.id == todoID }) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "todo not found")
        }
        modelContext.delete(todo)
        try? modelContext.save()
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "deleted": AnyCodable(true),
            "todo_id": AnyCodable(todoID.uuidString),
        ]))
    }

    // MARK: - Projects

    private static func projectList(
        requestID: String,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
        let projects = (try? modelContext.fetch(descriptor)) ?? []
        let entries = projects.map { p -> AnyCodable in
            AnyCodable([
                "id": AnyCodable(p.id.uuidString),
                "name": AnyCodable(p.name),
                "root_path": AnyCodable(p.rootPath),
                "created_at": AnyCodable(ISO8601DateFormatter().string(from: p.createdAt)),
            ])
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "projects": AnyCodable(entries),
            "count": AnyCodable(entries.count),
        ]))
    }

    private static func projectCreate(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let name = payload.string("name"), !name.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "name required")
        }
        guard let rootPath = payload.string("root_path"), !rootPath.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "root_path required (absolute filesystem path to project)")
        }
        let project = Project(name: name, rootPath: rootPath)
        modelContext.insert(project)
        try? modelContext.save()
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "project_id": AnyCodable(project.id.uuidString),
            "name": AnyCodable(project.name),
            "root_path": AnyCodable(project.rootPath),
        ]))
    }

    private static func projectResolve(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        // Reuse existing projects.resolve path via the router fall-
        // through pattern — but inline here for the bridge namespace.
        guard let name = payload.string("name") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "name required")
        }
        guard let project = lookupProjectByName(name, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "no project matched '\(name)'")
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "project_id": AnyCodable(project.id.uuidString),
            "name": AnyCodable(project.name),
            "root_path": AnyCodable(project.rootPath),
        ]))
    }

    private static func projectDelete(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let project = resolveProject(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "project not found (pass project, project_id, or name)")
        }
        ProjectActionsService.deleteProject(
            project,
            modelContext: modelContext,
            terminalManager: terminalManager
        )
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "deleted": AnyCodable(true),
            "project_id": AnyCodable(project.id.uuidString),
        ]))
    }

    // MARK: - Eternal — propose / accept / reject (split flow)
    //
    // Earlier versions of this handler tried to be one-shot: propose
    // → poll on `Thread.sleep` for up to 180s → auto-accept. That
    // wedged the SwiftUI render loop on the main actor and macOS
    // killed the app for being unresponsive. The right pattern is
    // for the agent to drive the polling itself: call
    // `eternal_start`, poll `eternal_status` every ~10–15s, then
    // call `eternal_accept` once the run hits `awaitingReview`.
    // The system preamble in TadoUseEngine documents this loop, and
    // the agent's tool-call latency naturally bounds the poll rate
    // without blocking the host app.

    /// Propose an Eternal run. Creates a coordinator marker todo,
    /// kicks off the architect via `EternalService.proposeViaCoordinator`,
    /// and returns immediately. The caller polls `eternal_status`
    /// until the run hits `awaitingReview`, then calls
    /// `eternal_accept` to spawn the worker.
    private static func eternalStartAutonomous(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let project = resolveProject(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "project required (pass project, project_id, or name)")
        }
        guard let goal = payload.string("goal"), !goal.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "goal required (the user-brief the architect plans against)")
        }

        // Create a coordinator marker todo. Title hints that this is
        // a Tado-Use-spawned eternal.
        let gridIndex = nextGridIndex(modelContext: modelContext)
        let gridColumns = (try? modelContext.fetch(FetchDescriptor<AppSettings>()).first?.gridColumns) ?? 3
        let position = CanvasLayout.position(forIndex: gridIndex, gridColumns: gridColumns)
        let coordTodo = TodoItem(text: "Tado Use eternal: \(goal.prefix(80))", gridIndex: gridIndex, canvasPosition: position)
        coordTodo.projectID = project.id
        coordTodo.isCoordinator = true
        modelContext.insert(coordTodo)
        try? modelContext.save()

        let mode = payload.string("mode") ?? "sprint"  // sprint | mega
        let engine = payload.string("engine") ?? project.defaultEngineForCoordinator()
        let label = payload.string("label") ?? "Tado Use: \(goal.prefix(40))"
        let run = EternalService.proposeViaCoordinator(
            project: project,
            label: label,
            userBrief: goal,
            mode: mode,
            engine: engine,
            coordinatorTodoID: coordTodo.id,
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
            "state": AnyCodable(run.state),
            "coordinator_todo_id": AnyCodable(coordTodo.id.uuidString),
            "next_step": AnyCodable("Poll tado_use_eternal_status until state == 'awaitingReview', then call tado_use_eternal_accept with this run_id."),
        ]))
    }

    /// Accept the architect's `crafted.md` plan — spawns the worker
    /// tile that runs the actual eternal loop. Errors with
    /// `state_mismatch` if the run isn't in `awaitingReview` yet
    /// (caller should keep polling status).
    private static func eternalAccept(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let run = lookupEternalRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "eternal run not found")
        }
        let note = payload.string("note") ?? "Auto-accepted by Tado Use"
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
                "state": AnyCodable(run.state),
                "accepted": AnyCodable(true),
            ]))
        case .stateMismatch(let actual):
            return ControlRequestRouter.error(requestID, code: "state_mismatch", message: "run is in state '\(actual)', not 'awaitingReview' — keep polling tado_use_eternal_status", extra: [
                "actual": AnyCodable(actual),
                "expected": AnyCodable("awaitingReview"),
                "run_id": AnyCodable(run.id.uuidString),
            ])
        case .notFound:
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
    }

    /// Reject the architect's plan. Optionally rebrief the
    /// architect (re-spawns with the new constraints).
    private static func eternalReject(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let run = lookupEternalRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "eternal run not found")
        }
        let reason = payload.string("reason") ?? "Rejected by Tado Use"
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
                "state": AnyCodable(run.state),
                "rejected": AnyCodable(true),
                "rebriefed": AnyCodable(rebrief != nil),
            ]))
        case .stateMismatch(let actual):
            return ControlRequestRouter.error(requestID, code: "state_mismatch", message: "run is in state '\(actual)', not 'awaitingReview' or 'ready'", extra: [
                "actual": AnyCodable(actual),
                "run_id": AnyCodable(run.id.uuidString),
            ])
        case .notFound:
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
    }

    private static func eternalList(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        let projectFilter = resolveProject(payload: payload, modelContext: modelContext)
        let stateFilter = payload.string("state")
        let descriptor = FetchDescriptor<EternalRun>(sortBy: [SortDescriptor<EternalRun>(\.createdAt, order: .reverse)])
        let runs = (try? modelContext.fetch(descriptor)) ?? []
        let filtered = runs.filter { run in
            if let p = projectFilter, run.project?.id != p.id { return false }
            if let s = stateFilter, !s.isEmpty, run.state != s { return false }
            return true
        }
        let entries = filtered.map { run -> AnyCodable in
            var d: [String: AnyCodable] = [
                "run_id": AnyCodable(run.id.uuidString),
                "label": AnyCodable(run.label),
                "state": AnyCodable(run.state),
                "mode": AnyCodable(run.mode),
                "engine": AnyCodable(run.engine),
                "is_active": AnyCodable(EternalService.isActive(run)),
            ]
            if let p = run.project {
                d["project_id"] = AnyCodable(p.id.uuidString)
                d["project_name"] = AnyCodable(p.name)
            }
            if let st = EternalService.readState(run) {
                d["phase"] = AnyCodable(st.phase)
                d["iterations"] = AnyCodable(Int(st.iterations))
                d["sprints"] = AnyCodable(Int(st.sprints))
            }
            return AnyCodable(d)
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "runs": AnyCodable(entries),
            "count": AnyCodable(entries.count),
        ]))
    }

    private static func eternalStatus(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let run = lookupEternalRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "eternal run not found")
        }
        var dict: [String: AnyCodable] = [
            "run_id": AnyCodable(run.id.uuidString),
            "label": AnyCodable(run.label),
            "state": AnyCodable(run.state),
            "mode": AnyCodable(run.mode),
            "engine": AnyCodable(run.engine),
            "has_crafted": AnyCodable(EternalService.craftedExistsOnDisk(run)),
            "is_active": AnyCodable(EternalService.isActive(run)),
        ]
        if let p = run.project {
            dict["project_id"] = AnyCodable(p.id.uuidString)
            dict["project_name"] = AnyCodable(p.name)
            dict["project_root"] = AnyCodable(p.rootPath)
        }
        if let st = EternalService.readState(run) {
            dict["phase"] = AnyCodable(st.phase)
            dict["iterations"] = AnyCodable(Int(st.iterations))
            dict["sprints"] = AnyCodable(Int(st.sprints))
            if let last = st.lastProgressNote { dict["last_progress_note"] = AnyCodable(last) }
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable(dict))
    }

    private static func eternalStop(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let run = lookupEternalRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "eternal run not found")
        }
        EternalService.requestStop(run)
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "run_id": AnyCodable(run.id.uuidString),
            "stop_requested": AnyCodable(true),
        ]))
    }

    private static func eternalIntervene(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let run = lookupEternalRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "eternal run not found")
        }
        guard let directive = payload.string("directive"), !directive.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "directive required (the message to drop into the worker's inbox)")
        }
        let inbox = EternalService.inboxDirURL(run)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let filename = "tado-use-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).md"
        let url = inbox.appendingPathComponent(filename)
        do {
            try directive.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return ControlRequestRouter.error(requestID, code: "write_failed", message: "could not write inbox file: \(error.localizedDescription)")
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "run_id": AnyCodable(run.id.uuidString),
            "inbox_file": AnyCodable(url.path),
        ]))
    }

    // MARK: - Dispatch — propose / accept / reject

    private static func dispatchStartAutonomous(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let project = resolveProject(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "project required")
        }
        guard let goal = payload.string("goal"), !goal.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "goal required")
        }
        let gridIndex = nextGridIndex(modelContext: modelContext)
        let gridColumns = (try? modelContext.fetch(FetchDescriptor<AppSettings>()).first?.gridColumns) ?? 3
        let position = CanvasLayout.position(forIndex: gridIndex, gridColumns: gridColumns)
        let coordTodo = TodoItem(text: "Tado Use dispatch: \(goal.prefix(80))", gridIndex: gridIndex, canvasPosition: position)
        coordTodo.projectID = project.id
        coordTodo.isCoordinator = true
        modelContext.insert(coordTodo)
        try? modelContext.save()

        let label = payload.string("label") ?? "Tado Use: \(goal.prefix(40))"
        let run = DispatchPlanService.proposeViaCoordinator(
            project: project,
            label: label,
            brief: goal,
            coordinatorTodoID: coordTodo.id,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )

        // Same propose-only pattern as eternal: return immediately.
        // Agent polls dispatch_status until awaitingReview, then
        // calls dispatch_accept. Polling on the main actor would
        // wedge the SwiftUI render loop and crash the app.
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "run_id": AnyCodable(run.id.uuidString),
            "project_id": AnyCodable(project.id.uuidString),
            "project_name": AnyCodable(project.name),
            "label": AnyCodable(run.label),
            "state": AnyCodable(run.state),
            "coordinator_todo_id": AnyCodable(coordTodo.id.uuidString),
            "next_step": AnyCodable("Poll tado_use_dispatch_status until state == 'awaitingReview', then call tado_use_dispatch_accept with this run_id."),
        ]))
    }

    private static func dispatchAccept(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let run = lookupDispatchRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "dispatch run not found")
        }
        let note = payload.string("note") ?? "Auto-accepted by Tado Use"
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
                "state": AnyCodable(run.state),
                "accepted": AnyCodable(true),
            ]))
        case .stateMismatch(let actual):
            return ControlRequestRouter.error(requestID, code: "state_mismatch", message: "run is in state '\(actual)', not 'awaitingReview' — keep polling tado_use_dispatch_status", extra: [
                "actual": AnyCodable(actual),
                "expected": AnyCodable("awaitingReview"),
                "run_id": AnyCodable(run.id.uuidString),
            ])
        case .notFound:
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
    }

    private static func dispatchReject(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let run = lookupDispatchRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "dispatch run not found")
        }
        let reason = payload.string("reason") ?? "Rejected by Tado Use"
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
                "state": AnyCodable(run.state),
                "rejected": AnyCodable(true),
                "rebriefed": AnyCodable(rebrief != nil),
            ]))
        case .stateMismatch(let actual):
            return ControlRequestRouter.error(requestID, code: "state_mismatch", message: "run is in state '\(actual)', not 'awaitingReview' or 'ready'", extra: [
                "actual": AnyCodable(actual),
                "run_id": AnyCodable(run.id.uuidString),
            ])
        case .notFound:
            return ControlRequestRouter.error(requestID, code: "not_found", message: "run not found")
        }
    }

    private static func dispatchList(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        let projectFilter = resolveProject(payload: payload, modelContext: modelContext)
        let stateFilter = payload.string("state")
        let descriptor = FetchDescriptor<DispatchRun>(sortBy: [SortDescriptor<DispatchRun>(\.createdAt, order: .reverse)])
        let runs = (try? modelContext.fetch(descriptor)) ?? []
        let filtered = runs.filter { run in
            if let p = projectFilter, run.project?.id != p.id { return false }
            if let s = stateFilter, !s.isEmpty, run.state != s { return false }
            return true
        }
        let entries = filtered.map { run -> AnyCodable in
            var d: [String: AnyCodable] = [
                "run_id": AnyCodable(run.id.uuidString),
                "label": AnyCodable(run.label),
                "state": AnyCodable(run.state),
            ]
            if let p = run.project {
                d["project_id"] = AnyCodable(p.id.uuidString)
                d["project_name"] = AnyCodable(p.name)
            }
            return AnyCodable(d)
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "runs": AnyCodable(entries),
            "count": AnyCodable(entries.count),
        ]))
    }

    private static func dispatchStatus(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let run = lookupDispatchRun(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "dispatch run not found")
        }
        let phaseCount = DispatchPlanService.phaseFileCount(run)
        var dict: [String: AnyCodable] = [
            "run_id": AnyCodable(run.id.uuidString),
            "label": AnyCodable(run.label),
            "state": AnyCodable(run.state),
            "phase_count": AnyCodable(phaseCount),
            "has_crafted": AnyCodable(DispatchPlanService.craftedExistsOnDisk(run)),
            "has_plan": AnyCodable(DispatchPlanService.planExistsOnDisk(run)),
        ]
        if let p = run.project {
            dict["project_id"] = AnyCodable(p.id.uuidString)
            dict["project_name"] = AnyCodable(p.name)
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable(dict))
    }

    // MARK: - Bootstraps

    private static func bootstrap(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let kind = payload.string("kind") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "kind required (a2a, team, auto-mode, knowledge)")
        }
        guard let project = resolveProject(payload: payload, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "project required")
        }
        switch kind {
        case "a2a":
            ProjectActionsService.bootstrapTools(
                project: project, modelContext: modelContext,
                terminalManager: terminalManager, appState: appState
            )
        case "team":
            let teamFetch = FetchDescriptor<Team>()
            let teams = (try? modelContext.fetch(teamFetch))?.filter { $0.projectID == project.id } ?? []
            if teams.isEmpty {
                return ControlRequestRouter.error(requestID, code: "no_teams", message: "project has no teams to bootstrap")
            }
            ProjectActionsService.bootstrapTeam(
                project: project, teams: teams, modelContext: modelContext,
                terminalManager: terminalManager, appState: appState
            )
        case "auto-mode":
            ProjectActionsService.bootstrapAutoMode(
                project: project, modelContext: modelContext,
                terminalManager: terminalManager, appState: appState
            )
        case "knowledge":
            ProjectActionsService.bootstrapKnowledge(
                project: project, modelContext: modelContext,
                terminalManager: terminalManager, appState: appState
            )
        default:
            return ControlRequestRouter.error(requestID, code: "invalid_kind", message: "kind must be one of: a2a, team, auto-mode, knowledge")
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "kind": AnyCodable(kind),
            "project_id": AnyCodable(project.id.uuidString),
            "spawned_tile": AnyCodable(true),
        ]))
    }

    // MARK: - Settings

    private static func settingsGet(requestID: String) -> ControlResponseEnvelope {
        let g = ScopedConfig.shared.get()
        guard let data = try? AtomicStore.jsonEncoder.encode(g),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ControlRequestRouter.error(requestID, code: "encode_error", message: "could not encode settings")
        }
        // Wrap in AnyCodable. We have to do a small recursive
        // convert because AnyCodable doesn't take arbitrary Any.
        return ControlRequestRouter.ok(requestID, data: jsonToAnyCodable(json))
    }

    private static func settingsSet(
        requestID: String,
        payload: ControlPayload
    ) -> ControlResponseEnvelope {
        // Limited surface: known keys via dotted path. Full
        // arbitrary-key writes would risk corrupting JSON; we expose
        // the most useful operator-level toggles.
        guard let path = payload.string("key") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "key required (e.g. engine.claude.model, ui.bellMode, dome.defaultKnowledgeScope)")
        }
        guard let value = payload.string("value") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "value required (string; numbers/bools accepted as their string form)")
        }
        var ok = true
        ScopedConfig.shared.setGlobal { g in
            switch path {
            case "engine.default": g.engine.default = value
            case "engine.claude.model": g.engine.claude.model = value
            case "engine.claude.mode": g.engine.claude.mode = value
            case "engine.claude.effort": g.engine.claude.effort = value
            case "engine.codex.model": g.engine.codex.model = value
            case "engine.codex.mode": g.engine.codex.mode = value
            case "engine.codex.effort": g.engine.codex.effort = value
            case "ui.defaultThemeId": g.ui.defaultThemeId = value
            case "ui.bellMode": g.ui.bellMode = value
            case "ui.terminalFontFamily": g.ui.terminalFontFamily = value
            case "ui.terminalFontSize":
                if let n = Int(value) { g.ui.terminalFontSize = n } else { ok = false }
            case "ui.cursorBlink":
                if let b = Bool(value) { g.ui.cursorBlink = b } else { ok = false }
            case "ui.randomTileColor":
                if let b = Bool(value) { g.ui.randomTileColor = b } else { ok = false }
            case "canvas.gridColumns":
                if let n = Int(value) { g.canvas.gridColumns = n } else { ok = false }
            case "dome.defaultKnowledgeScope": g.dome.defaultKnowledgeScope = value
            case "dome.defaultKnowledgeKind": g.dome.defaultKnowledgeKind = value
            case "dome.includeGlobalInProject":
                if let b = Bool(value) { g.dome.includeGlobalInProject = b } else { ok = false }
            case "dome.agentRegistrationEnabled":
                if let b = Bool(value) { g.dome.agentRegistrationEnabled = b } else { ok = false }
            case "notifications.retentionDays":
                if let n = Int(value) { g.notifications.retentionDays = n } else { ok = false }
            default:
                ok = false
            }
        }
        if !ok {
            return ControlRequestRouter.error(requestID, code: "invalid_key", message: "unknown or unparseable key/value: \(path)=\(value)")
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "key": AnyCodable(path),
            "value": AnyCodable(value),
        ]))
    }

    // MARK: - Dome

    private static func domeIngestCodebase(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        // Two paths supported:
        //  - by Tado project (project_id|name): pull rootPath from
        //    the SwiftData record. This is the canonical path for
        //    "ingest the project I'm in."
        //  - by raw root_path: ingest an arbitrary directory.
        let projectIDOverride: String
        let nameOverride: String
        let rootPath: String
        if let p = resolveProject(payload: payload, modelContext: modelContext) {
            projectIDOverride = p.id.uuidString.lowercased()
            nameOverride = p.name
            rootPath = p.rootPath
        } else if let raw = payload.string("root_path") {
            projectIDOverride = UUID().uuidString.lowercased()
            nameOverride = payload.string("name") ?? URL(fileURLWithPath: raw).lastPathComponent
            rootPath = raw
        } else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "project (or project_id/name) OR explicit root_path required")
        }
        let watch = payload.bool("watch") ?? true
        let fullRebuild = payload.bool("full_rebuild") ?? false

        let registered = DomeRpcClient.codeRegisterProject(
            projectID: projectIDOverride,
            name: nameOverride,
            rootPath: rootPath,
            enabled: true
        )
        if !registered {
            return ControlRequestRouter.error(requestID, code: "register_failed", message: "Dome could not register the project (vault offline?)")
        }
        // Index in the background — full index can take minutes on
        // large repos. We kick off and return; caller polls
        // dome_code_status.
        let pidCopy = projectIDOverride
        Task.detached(priority: .userInitiated) {
            _ = DomeRpcClient.codeIndexProject(projectID: pidCopy, fullRebuild: fullRebuild)
        }
        var watchStarted = false
        if watch {
            watchStarted = DomeRpcClient.codeWatchStart(projectID: projectIDOverride)
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "project_id": AnyCodable(projectIDOverride),
            "name": AnyCodable(nameOverride),
            "root_path": AnyCodable(rootPath),
            "registered": AnyCodable(true),
            "indexing_started": AnyCodable(true),
            "watching": AnyCodable(watchStarted),
            "full_rebuild": AnyCodable(fullRebuild),
        ]))
    }

    private static func domeCodeStatus(requestID: String) -> ControlResponseEnvelope {
        let projects = DomeRpcClient.codeListProjects()
        let watchSet = Set(DomeRpcClient.codeWatchList())
        let entries = projects.map { p -> AnyCodable in
            AnyCodable([
                "project_id": AnyCodable(p.projectID),
                "name": AnyCodable(p.name),
                "root_path": AnyCodable(p.rootPath),
                "enabled": AnyCodable(p.enabled),
                "file_count": AnyCodable(p.fileCount),
                "chunk_count": AnyCodable(p.chunkCount),
                "embedding_model": AnyCodable(p.embeddingModelID ?? ""),
                "last_full_index_at": AnyCodable(p.lastFullIndexAt ?? ""),
                "watching": AnyCodable(watchSet.contains(p.projectID)),
            ])
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "projects": AnyCodable(entries),
            "count": AnyCodable(entries.count),
        ]))
    }

    private static func domeCodeSearch(
        requestID: String,
        payload: ControlPayload
    ) -> ControlResponseEnvelope {
        guard let query = payload.string("query") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "query required")
        }
        let limit = Int(payload.string("limit") ?? "") ?? 10
        let projectIDs: [String]? = payload.string("project_id").map { [$0] }
        let hits = DomeRpcClient.codeSearch(query: query, projectIDs: projectIDs, languages: nil, limit: limit, alpha: nil)
        let entries = hits.map { h -> AnyCodable in
            AnyCodable([
                "project_id": AnyCodable(h.projectID),
                "repo_path": AnyCodable(h.repoPath),
                "language": AnyCodable(h.language),
                "node_kind": AnyCodable(h.nodeKind ?? ""),
                "qualified_name": AnyCodable(h.qualifiedName ?? ""),
                "start_line": AnyCodable(h.startLine),
                "end_line": AnyCodable(h.endLine),
                "excerpt": AnyCodable(h.excerpt),
            ])
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "hits": AnyCodable(entries),
            "count": AnyCodable(entries.count),
        ]))
    }

    private static func domeNoteCreate(
        requestID: String,
        payload: ControlPayload
    ) -> ControlResponseEnvelope {
        guard let body = payload.string("body"), !body.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "body required")
        }
        let title = payload.string("title") ?? "Tado Use note"
        let topic = payload.string("topic") ?? "tado-use"
        let kind = payload.string("kind") ?? "knowledge"
        let scopeRaw = payload.string("scope") ?? "global"
        // Project-scoped writes need project root + name + id
        // together; the bridge only carries `project_id`, so we
        // hardwire to global for now. Surface this in the response
        // instead of silently echoing the request — F-004.
        let domeScope: DomeScopeSelection = .global
        guard let id = DomeRpcClient.writeNote(
            scope: .user,
            topic: topic,
            title: title,
            body: body,
            domeScope: domeScope,
            knowledgeKind: kind
        ) else {
            return ControlRequestRouter.error(requestID, code: "write_failed", message: "Dome rejected the write")
        }
        var data: [String: AnyCodable] = [
            "note_id": AnyCodable(id),
            "topic": AnyCodable(topic),
            "scope": AnyCodable("global"),
            "kind": AnyCodable(kind),
        ]
        if scopeRaw != "global" {
            data["requested_scope"] = AnyCodable(scopeRaw)
            data["note"] = AnyCodable("scope is hardwired to 'global' in this bridge version; project-scoped writes ship in a follow-up")
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable(data))
    }

    private static func domeNoteSearch(
        requestID: String,
        payload: ControlPayload
    ) -> ControlResponseEnvelope {
        guard let query = payload.string("query") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "query required")
        }
        let limit = Int(payload.string("limit") ?? "") ?? 10
        guard let scored = DomeRpcClient.search(query: query, domeScope: nil, limit: limit) else {
            return ControlRequestRouter.error(requestID, code: "vault_offline", message: "Dome search not available")
        }
        let entries = scored.map { s -> AnyCodable in
            AnyCodable([
                "note_id": AnyCodable(s.note.id),
                "title": AnyCodable(s.note.title),
                "topic": AnyCodable(s.note.topic),
                "score": AnyCodable(String(format: "%.3f", s.score)),
            ])
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "hits": AnyCodable(entries),
            "count": AnyCodable(entries.count),
        ]))
    }

    private static func domeRecipeApply(
        requestID: String,
        payload: ControlPayload
    ) -> ControlResponseEnvelope {
        guard let intent = payload.string("intent") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "intent required (e.g. architecture-review, completion-claim, team-handoff)")
        }
        let projectID = payload.string("project_id")
        guard let answer = DomeRpcClient.recipeApply(intentKey: intent, projectID: projectID) else {
            return ControlRequestRouter.error(requestID, code: "recipe_failed", message: "no governed answer for intent '\(intent)'")
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "intent": AnyCodable(intent),
            "answer": AnyCodable(answer.answer),
            "citation_count": AnyCodable(answer.citations.count),
            "missing_authority_count": AnyCodable(answer.missingAuthority.count),
        ]))
    }

    private static func domeAgentStatus(
        requestID: String,
        payload: ControlPayload
    ) -> ControlResponseEnvelope {
        let limit = Int(payload.string("limit") ?? "") ?? 50
        guard let envelope = DomeRpcClient.agentStatus(limit: limit) else {
            return ControlRequestRouter.error(requestID, code: "vault_offline", message: "Dome agent_status not available")
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "status_count": AnyCodable(envelope.statuses.count),
            "context_event_count": AnyCodable(envelope.contextEvents.count),
            "context_pack_count": AnyCodable(envelope.contextPacks.count),
            "status_source": AnyCodable(envelope.statusSource ?? ""),
        ]))
    }

    // MARK: - Extensions

    private static func extensionOpen(
        requestID: String,
        payload: ControlPayload,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let id = payload.string("id") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "id required (notifications, dome, cross-run-browser)")
        }
        // Use NSWorkspace-style window opening via the SwiftUI
        // openWindow environment is only available inside views.
        // For the bridge we call the AppKit API directly via the
        // EventBus to ask for an open. Simpler: invoke `openWindow`
        // through the existing extension-window infrastructure
        // by directly reaching for the right WindowGroup id.
        let windowID = ExtensionWindowID.string(for: id)
        // Fallback: post an event the app can react to. There is
        // no direct programmatic openWindow from outside a SwiftUI
        // view in macOS 14, but NSWorkspace.shared.open with a
        // custom URL scheme would work — we don't have one. So we
        // toggle a flag on AppState for the panel UI to react to,
        // and the user's request for "open this extension" lands as
        // a system event the operator can act on.
        EventBus.shared.publish(TadoEvent(
            type: "tado_use.openExtension",
            severity: .info,
            source: .system,
            title: "Tado Use requests extension open",
            body: "id=\(id) windowID=\(windowID)"
        ))
        // Also flip a transient flag so the running window can
        // react via a SwiftUI .onChange watcher (TadoApp wires
        // this). For now we publish the event; the operator sees
        // a notification and can click through.
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "id": AnyCodable(id),
            "window_id": AnyCodable(windowID),
            "method": AnyCodable("event_published"),
            "note": AnyCodable("macOS doesn't expose openWindow outside a SwiftUI view; the panel reacts to the published event."),
        ]))
    }

    private static func extensionList(requestID: String) -> ControlResponseEnvelope {
        let registered = ExtensionRegistry.all.map { ext -> AnyCodable in
            AnyCodable([
                "id": AnyCodable(ext.manifest.id),
                "display_name": AnyCodable(ext.manifest.displayName),
                "short_description": AnyCodable(ext.manifest.shortDescription),
                "icon": AnyCodable(ext.manifest.iconSystemName),
                "version": AnyCodable(ext.manifest.version),
            ])
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "extensions": AnyCodable(registered),
            "count": AnyCodable(registered.count),
        ]))
    }

    // MARK: - Notifications + tile control

    private static func notify(
        requestID: String,
        payload: ControlPayload
    ) -> ControlResponseEnvelope {
        guard let title = payload.string("title"), !title.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "title required")
        }
        let body = payload.string("body") ?? ""
        let severityRaw = payload.string("severity") ?? "info"
        let severity = TadoEvent.Severity(rawValue: severityRaw) ?? .info
        EventBus.shared.publish(TadoEvent(
            type: "tado_use.notify",
            severity: severity,
            source: .system,
            title: title,
            body: body
        ))
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "published": AnyCodable(true),
            "title": AnyCodable(title),
        ]))
    }

    private static func tileSend(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let target = payload.string("target") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "target required (todo_id, session_id, grid coords, or name substring)")
        }
        guard let message = payload.string("message"), !message.isEmpty else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "message required")
        }
        guard let session = resolveSession(target: target, terminalManager: terminalManager, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "no live session matched '\(target)'")
        }
        // enqueueOrSend lives on TerminalSession itself.
        session.enqueueOrSend(message)
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "session_id": AnyCodable(session.id.uuidString),
            "todo_id": AnyCodable(session.todoID.uuidString),
            "sent": AnyCodable(true),
        ]))
    }

    private static func tileRead(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let target = payload.string("target") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "target required")
        }
        let tail = Int(payload.string("tail") ?? "") ?? 100
        guard let session = resolveSession(target: target, terminalManager: terminalManager, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "no live session matched '\(target)'")
        }
        let log = session.logBuffer
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let tailed = Array(lines.suffix(max(0, tail)))
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "session_id": AnyCodable(session.id.uuidString),
            "todo_id": AnyCodable(session.todoID.uuidString),
            "lines": AnyCodable(tailed.map(AnyCodable.init)),
            "line_count": AnyCodable(tailed.count),
        ]))
    }

    private static func tileTerminate(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let target = payload.string("target") else {
            return ControlRequestRouter.error(requestID, code: "missing_param", message: "target required")
        }
        guard let session = resolveSession(target: target, terminalManager: terminalManager, modelContext: modelContext) else {
            return ControlRequestRouter.error(requestID, code: "not_found", message: "no live session matched")
        }
        terminalManager.terminateSession(session.id)
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "session_id": AnyCodable(session.id.uuidString),
            "terminated": AnyCodable(true),
        ]))
    }

    private static func eventsQuery(
        requestID: String,
        payload: ControlPayload
    ) -> ControlResponseEnvelope {
        let limit = Int(payload.string("limit") ?? "") ?? 50
        let typePrefix = payload.string("type_prefix")
        let recent = EventBus.shared.recent
        let matched = recent.filter { e in
            if let p = typePrefix, !e.type.hasPrefix(p) { return false }
            return true
        }
        let filtered = Array(matched.suffix(limit))
        let entries = filtered.map { e -> AnyCodable in
            AnyCodable([
                "id": AnyCodable(e.id.uuidString),
                "type": AnyCodable(e.type),
                "severity": AnyCodable(e.severity.rawValue),
                "source_kind": AnyCodable(e.source.kind),
                "title": AnyCodable(e.title),
                "body": AnyCodable(e.body),
                "ts": AnyCodable(ISO8601DateFormatter().string(from: e.ts)),
                "read": AnyCodable(e.read),
            ])
        }
        return ControlRequestRouter.ok(requestID, data: AnyCodable([
            "events": AnyCodable(entries),
            "count": AnyCodable(entries.count),
        ]))
    }

    // MARK: - Helpers

    /// Resolve a project from either `project_id`, `project`, or `name`
    /// payload field. Returns nil if none matches.
    private static func resolveProject(
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> Project? {
        let descriptor = FetchDescriptor<Project>()
        let projects = (try? modelContext.fetch(descriptor)) ?? []
        if let idStr = payload.string("project_id"),
           let id = UUID(uuidString: idStr) {
            if let p = projects.first(where: { $0.id == id }) { return p }
        }
        if let name = payload.string("project") ?? payload.string("name") {
            return lookupProjectByName(name, modelContext: modelContext, projects: projects)
        }
        return nil
    }

    private static func lookupProjectByName(
        _ name: String,
        modelContext: ModelContext,
        projects: [Project]? = nil
    ) -> Project? {
        let list = projects ?? ((try? modelContext.fetch(FetchDescriptor<Project>())) ?? [])
        let lower = name.lowercased()
        if let exact = list.first(where: { $0.name.lowercased() == lower }) { return exact }
        let candidates = list.filter { $0.name.lowercased().contains(lower) }
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func lookupEternalRun(
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> EternalRun? {
        guard let idStr = payload.string("run_id"),
              let id = UUID(uuidString: idStr) else { return nil }
        let runs = (try? modelContext.fetch(FetchDescriptor<EternalRun>())) ?? []
        return runs.first { $0.id == id }
    }

    private static func lookupDispatchRun(
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> DispatchRun? {
        guard let idStr = payload.string("run_id"),
              let id = UUID(uuidString: idStr) else { return nil }
        let runs = (try? modelContext.fetch(FetchDescriptor<DispatchRun>())) ?? []
        return runs.first { $0.id == id }
    }

    private static func resolveSession(
        target: String,
        terminalManager: TerminalManager,
        modelContext: ModelContext
    ) -> TerminalSession? {
        // 1. UUID match (todo or session)
        if let uuid = UUID(uuidString: target) {
            if let s = terminalManager.sessions.first(where: { $0.id == uuid || $0.todoID == uuid }) {
                return s
            }
        }
        // 2. Grid coords (col,row 1-indexed). Read gridColumns from
        // the user's AppSettings — it's user-configurable via
        // Settings + via tado_use_settings_set { canvas.gridColumns },
        // so a hardcoded 3 here silently picked the wrong tile after
        // a column change.
        let columns = (try? modelContext.fetch(FetchDescriptor<AppSettings>()).first?.gridColumns) ?? 3
        let cleaned = target.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let parts = cleaned.split(whereSeparator: { $0 == "," || $0 == ":" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2,
           let col = Int(parts[0]), let row = Int(parts[1]),
           col >= 1, row >= 1 {
            let idx = (row - 1) * columns + (col - 1)
            if let s = terminalManager.sessions.first(where: { $0.gridIndex == idx }) {
                return s
            }
        }
        // 3. Name substring match (case-insensitive)
        let lower = target.lowercased()
        if let s = terminalManager.sessions.first(where: {
            $0.title.lowercased().contains(lower) ||
            $0.todoText.lowercased().contains(lower)
        }) {
            return s
        }
        return nil
    }

    private static func nextGridIndex(modelContext: ModelContext) -> Int {
        let todos = (try? modelContext.fetch(FetchDescriptor<TodoItem>())) ?? []
        let occupied = Set(todos.map { $0.gridIndex })
        var i = 0
        while occupied.contains(i) { i += 1 }
        return i
    }

    /// Recursively wrap a JSON-decoded `[String: Any]` in an
    /// `AnyCodable`. Used by `settings_get` since
    /// `JSONSerialization` produces `Any` and `AnyCodable` is the
    /// wire type.
    private static func jsonToAnyCodable(_ value: Any) -> AnyCodable {
        if value is NSNull { return AnyCodable(.null) }
        if let b = value as? Bool { return AnyCodable(.bool(b)) }
        if let i = value as? Int { return AnyCodable(.int(Int64(i))) }
        if let d = value as? Double { return AnyCodable(.double(d)) }
        if let s = value as? String { return AnyCodable(.string(s)) }
        if let arr = value as? [Any] {
            return AnyCodable(.array(arr.map(jsonToAnyCodable)))
        }
        if let dict = value as? [String: Any] {
            var out: [String: AnyCodable] = [:]
            for (k, v) in dict { out[k] = jsonToAnyCodable(v) }
            return AnyCodable(.object(out))
        }
        return AnyCodable(.string(String(describing: value)))
    }
}
