import Foundation
import SwiftData

/// Tado Use bridge — handlers for the six in-process tools the
/// drawer's headless `claude` / `codex` agent calls when it wants to
/// drive Tado's SwiftUI surface (panels the existing tado-mcp +
/// dome-mcp servers can't reach because they live in the Rust
/// binaries, not the Swift app process).
///
/// Wired up: `ControlRequestRouter.handle` switches on `tado_use.*`
/// kinds and dispatches here. The wire format is the same
/// `ControlRequest` envelope every other coordinator surface uses, so
/// the bridge subprocess (`tado-use-bridge`) talks to the running
/// app exactly the way `tado-eternal` etc. already do.
///
/// All handlers run on `@MainActor` because they touch `appState` and
/// `modelContext`. They tag effects with `actor=tado_use` in any
/// downstream audit log so future operators can separate "UI button
/// click" from "Use agent call" — the existing canvas-tile clicks
/// land as `actor=user_ui`.
@MainActor
enum TadoUseBridgeHandlers {
    /// Whitelist of `ControlRequest.kind` values this surface owns.
    /// `ControlRequestRouter.handle` checks this set first; matching
    /// kinds dispatch here, anything else falls through to the
    /// existing eternal / dispatch / bootstrap routing.
    static let kinds: Set<String> = [
        "tado_use.navigate",
        "tado_use.focus_tile",
        "tado_use.open_modal",
        "tado_use.close_modal",
        "tado_use.list_tiles",
        "tado_use.app_state",
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
        case "tado_use.navigate":
            return navigate(
                requestID: requestID,
                payload: payload,
                appState: appState
            )
        case "tado_use.focus_tile":
            return focusTile(
                requestID: requestID,
                payload: payload,
                terminalManager: terminalManager,
                appState: appState
            )
        case "tado_use.open_modal":
            return setModal(
                requestID: requestID,
                payload: payload,
                appState: appState,
                opening: true
            )
        case "tado_use.close_modal":
            return setModal(
                requestID: requestID,
                payload: payload,
                appState: appState,
                opening: false
            )
        case "tado_use.list_tiles":
            return listTiles(
                requestID: requestID,
                payload: payload,
                terminalManager: terminalManager,
                modelContext: modelContext
            )
        case "tado_use.app_state":
            return appStateSnapshot(
                requestID: requestID,
                terminalManager: terminalManager,
                appState: appState
            )
        default:
            return ControlRequestRouter.error(
                requestID,
                code: "unknown_kind",
                message: "tado_use bridge does not handle \(kind)"
            )
        }
    }

    // MARK: - Handlers

    private static func navigate(
        requestID: String,
        payload: ControlPayload,
        appState: AppState
    ) -> ControlResponseEnvelope {
        guard let viewRaw = payload.string("view") else {
            return ControlRequestRouter.error(
                requestID,
                code: "missing_param",
                message: "view required (one of: details, canvas, projects, todos, extensions)"
            )
        }
        guard let view = ViewMode(rawValue: viewRaw) else {
            return ControlRequestRouter.error(
                requestID,
                code: "invalid_view",
                message: "unknown view '\(viewRaw)'; valid: details, canvas, projects, todos, extensions"
            )
        }
        appState.currentView = view
        return ControlRequestRouter.ok(
            requestID,
            data: AnyCodable([
                "ok": AnyCodable(true),
                "current_view": AnyCodable(view.rawValue),
            ])
        )
    }

    private static func focusTile(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> ControlResponseEnvelope {
        // Two ways to identify the tile: by todo UUID (canonical) or
        // by grid coords (`"row,col"` — same parse rule the
        // tado-send / tado-read CLIs use). Pick whichever the caller
        // supplied.
        let todoID: UUID? = {
            if let raw = payload.string("todo_id"), let uuid = UUID(uuidString: raw) {
                return uuid
            }
            if let grid = payload.string("grid"), let idx = parseGrid(grid) {
                return terminalManager.sessions.first { $0.gridIndex == idx }?.todoID
            }
            return nil
        }()
        guard let id = todoID else {
            return ControlRequestRouter.error(
                requestID,
                code: "not_found",
                message: "no tile matched todo_id or grid"
            )
        }
        guard let session = terminalManager.session(forTodoID: id) else {
            return ControlRequestRouter.error(
                requestID,
                code: "not_found",
                message: "no live session for todo \(id.uuidString)"
            )
        }
        appState.currentView = .canvas
        appState.focusedTileTodoID = id
        appState.pendingNavigationID = id
        return ControlRequestRouter.ok(
            requestID,
            data: AnyCodable([
                "ok": AnyCodable(true),
                "todo_id": AnyCodable(id.uuidString),
                "grid_index": AnyCodable(session.gridIndex),
                "grid_label": AnyCodable(CanvasLayout.gridLabel(forIndex: session.gridIndex)),
            ])
        )
    }

    private static func setModal(
        requestID: String,
        payload: ControlPayload,
        appState: AppState,
        opening: Bool
    ) -> ControlResponseEnvelope {
        guard let kind = payload.string("kind") else {
            return ControlRequestRouter.error(
                requestID,
                code: "missing_param",
                message: "kind required (settings, new_project, done_list, trash_list, sidebar)"
            )
        }
        switch kind {
        case "settings":      appState.showSettings = opening
        case "new_project":   appState.showNewProjectSheet = opening
        case "done_list":     appState.showDoneList = opening
        case "trash_list":    appState.showTrashList = opening
        case "sidebar":       appState.showSidebar = opening
        case "tado_use":      appState.showTadoUse = opening
        default:
            return ControlRequestRouter.error(
                requestID,
                code: "invalid_kind",
                message: "unknown modal kind '\(kind)'"
            )
        }
        return ControlRequestRouter.ok(
            requestID,
            data: AnyCodable([
                "ok": AnyCodable(true),
                "kind": AnyCodable(kind),
                "opening": AnyCodable(opening),
            ])
        )
    }

    private static func listTiles(
        requestID: String,
        payload: ControlPayload,
        terminalManager: TerminalManager,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        let projectFilter = payload.string("project_id").flatMap(UUID.init(uuidString:))
        let statusFilter = payload.string("status")
        let sessions = terminalManager.sessions.filter { session in
            if let pid = projectFilter {
                // Resolve project on the SwiftData side; sessions
                // hold projectName, not project id, so look up the
                // project by name on demand.
                if let resolved = resolveProjectID(name: session.projectName, modelContext: modelContext),
                   resolved != pid {
                    return false
                }
                if session.projectName == nil { return false }
            }
            if let want = statusFilter, !want.isEmpty,
               session.status.rawValue != want {
                return false
            }
            return true
        }
        let entries = sessions.map { session -> AnyCodable in
            AnyCodable([
                "todo_id": AnyCodable(session.todoID.uuidString),
                "session_id": AnyCodable(session.id.uuidString),
                "title": AnyCodable(session.title),
                "todo_text": AnyCodable(session.todoText),
                "status": AnyCodable(session.status.rawValue),
                "engine": AnyCodable(session.engine?.rawValue ?? "claude"),
                "grid_index": AnyCodable(session.gridIndex),
                "grid_label": AnyCodable(CanvasLayout.gridLabel(forIndex: session.gridIndex)),
                "project": AnyCodable(session.projectName ?? ""),
                "team": AnyCodable(session.teamName ?? ""),
                "agent": AnyCodable(session.agentName ?? ""),
                "started_at": AnyCodable(ISO8601DateFormatter().string(from: session.startedAt)),
                "turn_count": AnyCodable(session.turnCount),
            ])
        }
        return ControlRequestRouter.ok(
            requestID,
            data: AnyCodable([
                "tiles": AnyCodable(entries),
                "count": AnyCodable(entries.count),
            ])
        )
    }

    private static func appStateSnapshot(
        requestID: String,
        terminalManager: TerminalManager,
        appState: AppState
    ) -> ControlResponseEnvelope {
        var modal: String? = nil
        if appState.showSettings { modal = "settings" }
        else if appState.showNewProjectSheet { modal = "new_project" }
        else if appState.showDoneList { modal = "done_list" }
        else if appState.showTrashList { modal = "trash_list" }
        else if appState.eternalModalRunID != nil { modal = "eternal" }
        else if appState.dispatchModalRunID != nil { modal = "dispatch" }
        else if appState.eternalInterveneRunID != nil { modal = "eternal_intervene" }
        else if appState.craftedReviewRunID != nil { modal = "crafted_review" }

        var data: [String: AnyCodable] = [
            "current_view": AnyCodable(appState.currentView.rawValue),
            "sidebar_open": AnyCodable(appState.showSidebar),
            "tado_use_open": AnyCodable(appState.showTadoUse),
            "settings_open": AnyCodable(appState.showSettings),
            "active_project_id": AnyCodable(appState.activeProjectID?.uuidString ?? ""),
            "focused_tile_todo_id": AnyCodable(appState.focusedTileTodoID?.uuidString ?? ""),
            "session_count": AnyCodable(terminalManager.sessions.count),
            "running_count": AnyCodable(terminalManager.sessions.filter { $0.status == .running }.count),
            "needs_input_count": AnyCodable(terminalManager.sessions.filter { $0.status == .needsInput }.count),
            "awaiting_response_count": AnyCodable(terminalManager.sessions.filter { $0.status == .awaitingResponse }.count),
        ]
        if let modal { data["modal"] = AnyCodable(modal) }
        return ControlRequestRouter.ok(requestID, data: AnyCodable(data))
    }

    // MARK: - Helpers

    /// Parse a grid coordinate spec — same rule `tado-send` /
    /// `tado-read` use. Accepts `"col,row"`, `"col:row"`, `"[col,row]"`,
    /// `"col, row"` (CanvasLayout's gridLabel is `[col, row]`,
    /// 1-indexed). Returns the 0-indexed `gridIndex` used by
    /// `CanvasLayout.position(forIndex:)`.
    private static func parseGrid(_ raw: String) -> Int? {
        let gridColumns = 3
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let parts = cleaned
            .split(whereSeparator: { $0 == "," || $0 == ":" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let col = Int(parts[0]), let row = Int(parts[1]),
              row >= 1, col >= 1
        else { return nil }
        return (row - 1) * gridColumns + (col - 1)
    }

    private static func resolveProjectID(name: String?, modelContext: ModelContext) -> UUID? {
        guard let name, !name.isEmpty else { return nil }
        let descriptor = FetchDescriptor<Project>()
        let projects = (try? modelContext.fetch(descriptor)) ?? []
        return projects.first { $0.name == name }?.id
    }
}
