import Foundation
import SwiftData

/// Dispatches `ControlRequest` envelopes from the Unix domain
/// socket to the right Tado service. Stateless — the router
/// receives every dependency it needs as arguments to `handle`,
/// matching the existing `ContentView.handleSpawnRequest` shape.
///
/// Kinds (v1):
///
///   - `system.status`        — app version + vault health snapshot
///   - `projects.list`        — sorted project index (also readable
///                              from disk; this is the synchronous
///                              fallback for clients that want a
///                              guaranteed-fresh view)
///   - `eternal.propose`      — create EternalRun, spawn architect
///   - `eternal.status`       — read run.state + on-disk state.json
///   - `eternal.crafted`      — read crafted.md
///   - `eternal.accept`       — optimistic-concurrency accept
///   - `eternal.reject`       — archive crafted, optionally rebrief
///   - `eternal.stop`         — request stop
///   - `eternal.list`         — list runs (filter by project / state)
///   - `dispatch.*`           — same surface against DispatchPlanService
///   - `bootstrap.{a2a,team,auto-mode,knowledge}` — drive the four
///                              bootstrap actions
///
/// Errors come back as `{ok: false, error: "<code>"}` plus an
/// optional human note in `data.message`. Codes are stable —
/// CLI clients pattern-match on them.
@MainActor
enum ControlRequestRouter {
    static func handle(
        request: ControlRequest,
        terminalManager: TerminalManager,
        modelContext: ModelContext,
        appState: AppState
    ) -> ControlResponseEnvelope {
        let payload = request.payload ?? ControlPayload(empty: ())

        switch request.kind {
        case "system.status":
            return ok(request.requestID, data: systemStatus())

        case "projects.list":
            return ok(request.requestID, data: projectsList(modelContext: modelContext))

        case "projects.resolve":
            return projectsResolve(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext
            )

        case "eternal.propose":
            return CoordinatorEternal.propose(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )

        case "eternal.status":
            return CoordinatorEternal.status(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext
            )

        case "eternal.crafted":
            return CoordinatorEternal.crafted(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext
            )

        case "eternal.accept":
            return CoordinatorEternal.accept(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )

        case "eternal.reject":
            return CoordinatorEternal.reject(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )

        case "eternal.stop":
            return CoordinatorEternal.stop(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext
            )

        case "eternal.list":
            return CoordinatorEternal.list(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext
            )

        case "dispatch.propose":
            return CoordinatorDispatch.propose(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )

        case "dispatch.status":
            return CoordinatorDispatch.status(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext
            )

        case "dispatch.crafted":
            return CoordinatorDispatch.crafted(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext
            )

        case "dispatch.accept":
            return CoordinatorDispatch.accept(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )

        case "dispatch.reject":
            return CoordinatorDispatch.reject(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )

        case "dispatch.list":
            return CoordinatorDispatch.list(
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext
            )

        case "bootstrap.a2a", "bootstrap.team", "bootstrap.auto-mode", "bootstrap.knowledge":
            return CoordinatorBootstrap.run(
                kind: request.kind,
                requestID: request.requestID,
                payload: payload,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )

        default:
            // Tado Use bridge — six core tools the drawer's headless
            // agent calls to drive Tado's SwiftUI surface.
            if TadoUseBridgeHandlers.kinds.contains(request.kind) {
                return TadoUseBridgeHandlers.handle(
                    kind: request.kind,
                    requestID: request.requestID,
                    payload: payload,
                    terminalManager: terminalManager,
                    modelContext: modelContext,
                    appState: appState
                )
            }
            // Tado Use autonomous tools — todos, eternals (with
            // auto-accept), dispatches, bootstraps, settings, Dome
            // ingestion, kanban, extensions, notifications, tile
            // control. Same fall-through pattern, separate handler
            // file so the surface can grow without bloating the
            // router.
            if TadoUseAutonomousHandlers.kinds.contains(request.kind) {
                return TadoUseAutonomousHandlers.handle(
                    kind: request.kind,
                    requestID: request.requestID,
                    payload: payload,
                    terminalManager: terminalManager,
                    modelContext: modelContext,
                    appState: appState
                )
            }
            return error(request.requestID, code: "unknown_kind", message: "Unknown kind: \(request.kind)")
        }
    }

    // MARK: - Read-only handlers

    private static func systemStatus() -> AnyCodable {
        let pid = ProcessInfo.processInfo.processIdentifier
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let storageRoot = StorePaths.root.path
        let vaultPath = StorePaths.domeVaultRoot.path
        let vaultExists = FileManager.default.fileExists(atPath: vaultPath)
        return AnyCodable([
            "pid": AnyCodable(Int(pid)),
            "version": AnyCodable(version),
            "storage_root": AnyCodable(storageRoot),
            "vault_path": AnyCodable(vaultPath),
            "vault_exists": AnyCodable(vaultExists)
        ])
    }

    private static func projectsList(modelContext: ModelContext) -> AnyCodable {
        let descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])
        let projects = (try? modelContext.fetch(descriptor)) ?? []
        let entries = projects.map { project -> AnyCodable in
            AnyCodable([
                "id": AnyCodable(project.id.uuidString),
                "name": AnyCodable(project.name),
                "rootPath": AnyCodable(project.rootPath),
                "createdAt": AnyCodable(ISO8601DateFormatter().string(from: project.createdAt))
            ])
        }
        return AnyCodable(entries)
    }

    private static func projectsResolve(
        requestID: String,
        payload: ControlPayload,
        modelContext: ModelContext
    ) -> ControlResponseEnvelope {
        guard let name = payload.string("name") else {
            return error(requestID, code: "missing_param", message: "name required")
        }
        let descriptor = FetchDescriptor<Project>()
        let projects = (try? modelContext.fetch(descriptor)) ?? []
        let lower = name.lowercased()

        // Exact match wins.
        if let exact = projects.first(where: { $0.name.lowercased() == lower }) {
            return ok(requestID, data: AnyCodable([
                "id": AnyCodable(exact.id.uuidString),
                "name": AnyCodable(exact.name),
                "rootPath": AnyCodable(exact.rootPath),
                "match_quality": AnyCodable("exact")
            ]))
        }

        // Substring/prefix candidates ranked by match position.
        let candidates = projects
            .filter { $0.name.lowercased().contains(lower) }
            .sorted { lhs, rhs in
                let li = lhs.name.lowercased().distance(
                    from: lhs.name.lowercased().startIndex,
                    to: lhs.name.lowercased().range(of: lower)?.lowerBound ?? lhs.name.lowercased().startIndex
                )
                let ri = rhs.name.lowercased().distance(
                    from: rhs.name.lowercased().startIndex,
                    to: rhs.name.lowercased().range(of: lower)?.lowerBound ?? rhs.name.lowercased().startIndex
                )
                return li < ri
            }

        if candidates.count == 1, let only = candidates.first {
            return ok(requestID, data: AnyCodable([
                "id": AnyCodable(only.id.uuidString),
                "name": AnyCodable(only.name),
                "rootPath": AnyCodable(only.rootPath),
                "match_quality": AnyCodable("substring")
            ]))
        }
        if candidates.isEmpty {
            return error(
                requestID,
                code: "no_match",
                message: "no project named or containing '\(name)'",
                extra: [
                    "candidates": AnyCodable(projects.prefix(20).map { AnyCodable($0.name) })
                ]
            )
        }
        return error(
            requestID,
            code: "ambiguous",
            message: "multiple projects match '\(name)'",
            extra: [
                "candidates": AnyCodable(candidates.map { AnyCodable($0.name) })
            ]
        )
    }

    // MARK: - Helpers

    static func ok(_ requestID: String, data: AnyCodable?) -> ControlResponseEnvelope {
        ControlResponseEnvelope(requestID: requestID, ok: true, data: data, error: nil)
    }

    static func error(
        _ requestID: String,
        code: String,
        message: String,
        extra: [String: AnyCodable] = [:]
    ) -> ControlResponseEnvelope {
        var dict: [String: AnyCodable] = ["message": AnyCodable(message)]
        for (k, v) in extra { dict[k] = v }
        return ControlResponseEnvelope(
            requestID: requestID,
            ok: false,
            data: AnyCodable(dict),
            error: code
        )
    }
}

extension ControlPayload {
    /// Empty payload sentinel. Used when the request has no
    /// payload field at all.
    init(empty: Void) {
        self.raw = [:]
    }
}
