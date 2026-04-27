import Foundation
import CTadoCore

/// Swift-side facade over the Dome FFI surface. Calls `tado_dome_*`
/// functions from `tado_core.h` and decodes the JSON returned by
/// bt-core into strongly-typed Swift values.
///
/// Lifecycle notes
/// ---------------
/// The FFI is only valid after `tado_dome_start` has succeeded — i.e.
/// after `DomeExtension.onAppLaunch()` publishes `.domeDaemonStarted`.
/// Callers from Dome surfaces should read EventBus to confirm online
/// state before issuing calls; this facade itself returns nil on any
/// failure (null pointer from the FFI) and surfaces nothing to the
/// user — the view layer decides how to render offline state.
///
/// Threading
/// ---------
/// The FFI holds a Tokio runtime that owns the SQLite handle; calls
/// are short (local IPC-free doc ops) and safe to make from any
/// Swift thread. UI code should still dispatch to the main actor
/// before touching `@Observable` state, but the FFI itself doesn't
/// require main-thread.
enum DomeRpcClient {
    // MARK: - Data models

    /// A single note summary as returned by `tado_dome_notes_list`.
    /// Matches the Rust `doc_list` JSON shape; fields we don't
    /// consume on the Swift side are simply decoded into `.other`
    /// if added later (via JSONDecoder's lenient mode).
    struct NoteSummary: Identifiable, Codable, Equatable, Hashable {
        let id: String
        let title: String
        let topic: String
        let slug: String
        let userPath: String
        let agentPath: String
        let createdAt: Date?
        let updatedAt: Date?
        let agentActive: Bool?
        let ownerScope: String?
        let projectID: String?
        let projectRoot: String?
        let knowledgeKind: String?

        enum CodingKeys: String, CodingKey {
            case id, title, topic, slug
            case userPath = "user_path"
            case agentPath = "agent_path"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case agentActive = "agent_active"
            case ownerScope = "owner_scope"
            case projectID = "project_id"
            case projectRoot = "project_root"
            case knowledgeKind = "knowledge_kind"
        }

        /// Preferred sort timestamp: updated_at fallback to created_at.
        var sortTimestamp: Date { updatedAt ?? createdAt ?? .distantPast }
    }

    /// Full note content as returned by `tado_dome_note_get`.
    struct NoteDetail: Codable, Equatable {
        let id: String
        let title: String
        let topic: String
        let userContent: String?
        let agentContent: String?
        let createdAt: Date?
        let updatedAt: Date?
        let ownerScope: String?
        let projectID: String?
        let projectRoot: String?
        let knowledgeKind: String?

        enum CodingKeys: String, CodingKey {
            case id, title, topic
            case userContent = "user_content"
            case agentContent = "agent_content"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case ownerScope = "owner_scope"
            case projectID = "project_id"
            case projectRoot = "project_root"
            case knowledgeKind = "knowledge_kind"
        }
    }

    struct GraphNode: Identifiable, Codable, Equatable, Hashable {
        let nodeID: String
        let kind: String
        let refID: String
        let label: String
        let secondaryLabel: String?
        let groupKey: String
        let sortTime: Date?

        var id: String { nodeID }

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case kind
            case refID = "ref_id"
            case label
            case secondaryLabel = "secondary_label"
            case groupKey = "group_key"
            case sortTime = "sort_time"
        }
    }

    struct GraphEdge: Identifiable, Codable, Equatable, Hashable {
        let edgeID: String
        let kind: String
        let sourceID: String
        let targetID: String

        var id: String { edgeID }

        enum CodingKeys: String, CodingKey {
            case edgeID = "edge_id"
            case kind
            case sourceID = "source_id"
            case targetID = "target_id"
        }
    }

    struct GraphLayoutPoint: Codable, Equatable {
        let x: Double
        let y: Double
        let rank: Double?
        let cluster: String?
    }

    struct GraphLayoutCluster: Codable, Equatable, Identifiable {
        let groupKey: String
        let x: Double
        let y: Double
        let count: Int

        var id: String { groupKey }

        enum CodingKeys: String, CodingKey {
            case groupKey = "group_key"
            case x, y, count
        }
    }

    struct GraphLayout: Codable, Equatable {
        let engine: String?
        let nodes: [String: GraphLayoutPoint]
        let clusters: [GraphLayoutCluster]
    }

    struct GraphStats: Codable, Equatable {
        let totalNodes: Int
        let totalEdges: Int
        let visibleNodes: Int
        let visibleEdges: Int
        let countsByKind: [String: Int]?
        let visibleCountsByKind: [String: Int]?

        enum CodingKeys: String, CodingKey {
            case totalNodes = "total_nodes"
            case totalEdges = "total_edges"
            case visibleNodes = "visible_nodes"
            case visibleEdges = "visible_edges"
            case countsByKind = "counts_by_kind"
            case visibleCountsByKind = "visible_counts_by_kind"
        }
    }

    struct GraphSnapshot: Codable, Equatable {
        let nodes: [GraphNode]
        let edges: [GraphEdge]
        let layout: GraphLayout?
        let stats: GraphStats
        let availableTypes: [String]?
        let defaultIncludeTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case nodes, edges, layout, stats
            case availableTypes = "available_types"
            case defaultIncludeTypes = "default_include_types"
        }
    }

    struct AgentStatusSnapshot: Identifiable, Codable, Equatable {
        let tadoSessionID: String?
        let claudeSessionID: String?
        let agentName: String?
        let projectName: String?
        let modelDisplayName: String?
        let contextUsedPercent: Double?
        let contextWindowSize: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let costUSD: Double?
        let capturedAt: String?
        let currentDomePack: String?
        let retrievalFreshness: String?

        var id: String {
            [tadoSessionID, claudeSessionID, capturedAt, agentName]
                .compactMap { $0 }
                .joined(separator: ":")
        }

        enum CodingKeys: String, CodingKey {
            case tadoSessionID = "tado_session_id"
            case claudeSessionID = "claude_session_id"
            case agentName = "agent_name"
            case projectName = "project_name"
            case modelDisplayName = "model_display_name"
            case contextUsedPercent = "context_used_percent"
            case contextWindowSize = "context_window_size"
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case costUSD = "cost_usd"
            case capturedAt = "captured_at"
            case currentDomePack = "current_dome_pack"
            case retrievalFreshness = "retrieval_freshness"
        }
    }

    struct AgentContextEvent: Identifiable, Codable, Equatable {
        let eventID: String
        let agentName: String?
        let sessionID: String?
        let eventKind: String
        let contextID: String?
        let nodeID: String?
        let reason: String?
        let createdAt: String?

        var id: String { eventID }

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case agentName = "agent_name"
            case sessionID = "session_id"
            case eventKind = "event_kind"
            case contextID = "context_id"
            case nodeID = "node_id"
            case reason
            case createdAt = "created_at"
        }
    }

    struct ContextPackSummary: Identifiable, Codable, Equatable {
        let contextID: String
        let brand: String
        let sessionID: String?
        let docID: String?
        let status: String
        let tokenEstimate: Int?
        let citationCount: Int?
        let createdAt: Date?

        var id: String { contextID }

        enum CodingKeys: String, CodingKey {
            case contextID = "context_id"
            case brand
            case sessionID = "session_id"
            case docID = "doc_id"
            case status
            case tokenEstimate = "token_estimate"
            case citationCount = "citation_count"
            case createdAt = "created_at"
        }
    }

    struct AgentStatusEnvelope: Codable, Equatable {
        let statuses: [AgentStatusSnapshot]
        let contextEvents: [AgentContextEvent]
        let contextPacks: [ContextPackSummary]
        let statusSource: String?

        enum CodingKeys: String, CodingKey {
            case statuses
            case contextEvents = "context_events"
            case contextPacks = "context_packs"
            case statusSource = "status_source"
        }
    }

    /// Scope of a note write. Determines which side of the doc pair
    /// (user.md vs agent.md) receives the body. bt-core's write
    /// barrier enforces that user UIs like ours can only write to
    /// `.user`; `.agent` is kept available for future hook-driven
    /// scenarios but UI should default to `.user`.
    enum Scope: String { case user, agent }

    // MARK: - Calls

    /// Create a brand-new note. Returns the new note's id on success.
    @discardableResult
    static func writeNote(
        scope: Scope,
        topic: String,
        title: String,
        body: String,
        domeScope: DomeScopeSelection = .global,
        knowledgeKind: String = "knowledge"
    ) -> String? {
        let scopeStr = scope.rawValue
        let ownerScope = domeScope.ownerScope
        let projectID = domeScope.projectIDString
        let projectRoot = domeScope.projectRoot
        let json = scopeStr.withCString { scopeC in
            topic.withCString { topicC in
                title.withCString { titleC in
                    body.withCString { bodyC in
                        ownerScope.withCString { ownerC in
                            knowledgeKind.withCString { kindC in
                                withOptionalCString(projectID) { projectIDC in
                                    withOptionalCString(projectRoot) { projectRootC -> String? in
                                        guard let raw = tado_dome_note_write_scoped(
                                            scopeC,
                                            topicC,
                                            titleC,
                                            bodyC,
                                            ownerC,
                                            projectIDC,
                                            projectRootC,
                                            kindC
                                        ) else {
                                            return nil
                                        }
                                        defer { tado_string_free(raw) }
                                        return String(cString: raw)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let doc = decoded?["doc"] as? [String: Any],
           let id = doc["id"] as? String {
            return id
        }
        return decoded?["id"] as? String
    }

    static func updateUserNote(id: String, body: String) -> Bool {
        let json = id.withCString { idC in
            body.withCString { bodyC -> String? in
                guard let raw = tado_dome_note_update_user(idC, bodyC) else { return nil }
                defer { tado_string_free(raw) }
                return String(cString: raw)
            }
        }
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return decoded["updated"] as? Bool == true
    }

    static func renameNoteTitle(id: String, title: String) -> Bool {
        let json = id.withCString { idC in
            title.withCString { titleC -> String? in
                guard let raw = tado_dome_note_rename_title(idC, titleC) else { return nil }
                defer { tado_string_free(raw) }
                return String(cString: raw)
            }
        }
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return decoded["id"] as? String == id
    }

    /// Wraps `tado_dome_notes_list`. Returns the decoded list on
    /// success, nil on any failure (including daemon-not-started).
    static func listNotes(topic: String? = nil, limit: Int = 200, domeScope: DomeScopeSelection? = nil) -> [NoteSummary]? {
        let topicC = topic ?? ""
        let json = topicC.withCString { topicCstr -> String? in
            let arg: UnsafePointer<CChar>? = topic == nil ? nil : topicCstr
            if let domeScope {
                return domeScope.readKnowledgeScope.withCString { knowledgeScopeC in
                    withOptionalCString(domeScope.projectIDString) { projectIDC -> String? in
                        guard let raw = tado_dome_notes_list_scoped(
                            arg,
                            Int32(limit),
                            knowledgeScopeC,
                            projectIDC,
                            domeScope.includeGlobal
                        ) else {
                            return nil
                        }
                        defer { tado_string_free(raw) }
                        return String(cString: raw)
                    }
                }
            } else {
                guard let raw = tado_dome_notes_list(arg, Int32(limit)) else {
                    return nil
                }
                defer { tado_string_free(raw) }
                return String(cString: raw)
            }
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        struct Envelope: Codable { let docs: [NoteSummary] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let env = try? decoder.decode(Envelope.self, from: data) else {
            return nil
        }
        return env.docs
    }

    /// Free-text search across the active scope. The current
    /// implementation lists notes via `listNotes(domeScope:)` and
    /// ranks them with `SearchEngine` — a small pure-Swift heuristic
    /// ranker that works without a live Dome daemon. When bt-core
    /// exposes a `tado_dome_search` FFI in a future sprint, swap the
    /// internals; the boundary stays.
    ///
    /// Returns `nil` on daemon-down / list failure so the caller can
    /// distinguish "no daemon" from "no hits". Returns `[]` when the
    /// daemon is up but no notes matched.
    static func search(
        query: String,
        domeScope: DomeScopeSelection? = nil,
        limit: Int = 50
    ) -> [SearchEngine.Scored]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let docs = listNotes(topic: nil, limit: 500, domeScope: domeScope) else {
            return nil
        }
        return SearchEngine.rank(query: trimmed, notes: docs, limit: limit)
    }

    /// Resolve the latest context pack for a brand/session/doc tuple
    /// via `tado_dome_context_resolve`. Returns nil when the daemon
    /// isn't booted or the FFI call fails. A successful call returns a
    /// `ContextPackResult` with `resolved=false` when no matching pack
    /// exists (and a `recommendedNextSteps` list pointing the caller
    /// at `compact(...)`).
    static func contextResolve(
        brand: String? = nil,
        sessionID: String? = nil,
        docID: String? = nil,
        mode: String? = nil
    ) -> ContextPackResult? {
        let json = withOptionalCString(brand) { brandC -> String? in
            withOptionalCString(sessionID) { sidC -> String? in
                withOptionalCString(docID) { didC -> String? in
                    withOptionalCString(mode) { modeC -> String? in
                        guard let raw = tado_dome_context_resolve(brandC, sidC, didC, modeC) else {
                            return nil
                        }
                        defer { tado_string_free(raw) }
                        return String(cString: raw)
                    }
                }
            }
        }
        return decode(ContextPackResult.self, from: json)
    }

    /// Compact a brand/session/doc context pack via
    /// `tado_dome_context_compact`. Pass `force: true` to rebuild even
    /// if the source hash hasn't changed. The Rust path requires
    /// either `sessionID` or `docID` — calling with both nil returns
    /// nil from the FFI.
    static func contextCompact(
        brand: String,
        sessionID: String? = nil,
        docID: String? = nil,
        force: Bool = false
    ) -> ContextPackResult? {
        let json = brand.withCString { brandC -> String? in
            withOptionalCString(sessionID) { sidC -> String? in
                withOptionalCString(docID) { didC -> String? in
                    guard let raw = tado_dome_context_compact(brandC, sidC, didC, force) else {
                        return nil
                    }
                    defer { tado_string_free(raw) }
                    return String(cString: raw)
                }
            }
        }
        return decode(ContextPackResult.self, from: json)
    }

    static func createTopic(_ topic: String) -> String? {
        let json = topic.withCString { topicC -> String? in
            guard let raw = tado_dome_topic_create(topicC) else { return nil }
            defer { tado_string_free(raw) }
            return String(cString: raw)
        }
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decoded["topic"] as? String
    }

    static func deleteNote(id: String) -> Bool {
        let json = id.withCString { idC -> String? in
            guard let raw = tado_dome_note_delete(idC) else { return nil }
            defer { tado_string_free(raw) }
            return String(cString: raw)
        }
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return decoded["deleted"] as? Bool == true
    }

    /// Wraps `tado_dome_note_get`. Returns the full note content on
    /// success, nil on any failure.
    static func getNote(id: String) -> NoteDetail? {
        let json = id.withCString { idC -> String? in
            guard let raw = tado_dome_note_get(idC) else { return nil }
            defer { tado_string_free(raw) }
            return String(cString: raw)
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NoteDetail.self, from: data)
    }

    static func graphSnapshot(
        search: String? = nil,
        focusNodeID: String? = nil,
        maxNodes: Int = 400,
        includeTypes: [String]? = nil,
        domeScope: DomeScopeSelection? = nil
    ) -> GraphSnapshot? {
        // bt-core treats nil as "use defaults"; only serialize when the
        // caller actually wants to constrain the kinds returned.
        let includeTypesJSON: String? = {
            guard let includeTypes, !includeTypes.isEmpty else { return nil }
            let data = try? JSONSerialization.data(withJSONObject: includeTypes, options: [])
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }()
        let json: String? = withOptionalCString(focusNodeID) { focusC in
            withOptionalCString(includeTypesJSON) { includeC in
                withOptionalCString(search) { searchC in
                    if let domeScope {
                        return domeScope.readKnowledgeScope.withCString { scopeC in
                            withOptionalCString(domeScope.projectIDString) { projectIDC -> String? in
                                guard let raw = tado_dome_graph_snapshot_scoped(
                                    focusC,
                                    includeC,
                                    searchC,
                                    Int32(maxNodes),
                                    scopeC,
                                    projectIDC,
                                    domeScope.includeGlobal
                                ) else {
                                    return nil
                                }
                                defer { tado_string_free(raw) }
                                return String(cString: raw)
                            }
                        }
                    } else {
                        guard let raw = tado_dome_graph_snapshot(focusC, includeC, searchC, Int32(maxNodes)) else {
                            return nil
                        }
                        defer { tado_string_free(raw) }
                        return String(cString: raw)
                    }
                }
            }
        }
        return decode(GraphSnapshot.self, from: json)
    }

    static func refreshGraph() -> Bool {
        tado_dome_graph_refresh() == 0
    }

    static func graphNode(id: String) -> GraphSnapshot? {
        let json = id.withCString { idC -> String? in
            guard let raw = tado_dome_graph_node_get(idC) else { return nil }
            defer { tado_string_free(raw) }
            return String(cString: raw)
        }
        return decode(GraphSnapshot.self, from: json)
    }

    static func agentStatus(limit: Int = 50, domeScope: DomeScopeSelection? = nil) -> AgentStatusEnvelope? {
        if let domeScope {
            return domeScope.readKnowledgeScope.withCString { scopeC in
                withOptionalCString(domeScope.projectIDString) { projectIDC -> AgentStatusEnvelope? in
                    guard let raw = tado_dome_agent_status_scoped(
                        Int32(limit),
                        scopeC,
                        projectIDC,
                        domeScope.includeGlobal
                    ) else { return nil }
                    defer { tado_string_free(raw) }
                    return decode(AgentStatusEnvelope.self, from: String(cString: raw))
                }
            }
        }
        guard let raw = tado_dome_agent_status(Int32(limit)) else { return nil }
        defer { tado_string_free(raw) }
        return decode(AgentStatusEnvelope.self, from: String(cString: raw))
    }

    // MARK: - Retrieval log (Phase 2 — measurable evaluation)

    /// One row of the retrieval log, surfaced in Knowledge → System for
    /// the "did agents actually use what I served them?" inspector.
    struct RetrievalLogRow: Identifiable, Codable, Equatable {
        let logID: String
        let createdAt: String
        let actorKind: String
        let actorID: String?
        let projectID: String?
        let knowledgeScope: String
        let tool: String
        let query: String?
        let resultIDs: [String]
        let resultScopes: [String]
        let latencyMs: Int
        let packID: String?
        let wasConsumed: Bool

        var id: String { logID }

        enum CodingKeys: String, CodingKey {
            case logID = "log_id"
            case createdAt = "created_at"
            case actorKind = "actor_kind"
            case actorID = "actor_id"
            case projectID = "project_id"
            case knowledgeScope = "knowledge_scope"
            case tool, query
            case resultIDs = "result_ids"
            case resultScopes = "result_scopes"
            case latencyMs = "latency_ms"
            case packID = "pack_id"
            case wasConsumed = "was_consumed"
        }
    }

    /// Envelope returned by `retrievalLogRecent`. Aggregates carried so
    /// the System surface can render a one-line header without a
    /// second pass over `rows`.
    struct RetrievalLogEnvelope: Codable, Equatable {
        let rows: [RetrievalLogRow]
        let n: Int
        let consumptionRate: Double
        let meanLatencyMs: Double

        enum CodingKeys: String, CodingKey {
            case rows, n
            case consumptionRate = "consumption_rate"
            case meanLatencyMs = "mean_latency_ms"
        }
    }

    /// Fetch recent retrieval-log rows. `tool` filters by user-visible
    /// tool name (e.g. `"dome_search"`); pass nil for all tools.
    static func retrievalLogRecent(
        limit: Int = 100,
        projectID: String? = nil,
        tool: String? = nil
    ) -> RetrievalLogEnvelope? {
        let json = withOptionalCString(projectID) { projectIDC -> String? in
            withOptionalCString(tool) { toolC -> String? in
                guard let raw = tado_dome_retrieval_log_recent(
                    Int32(limit),
                    projectIDC,
                    toolC
                ) else { return nil }
                defer { tado_string_free(raw) }
                return String(cString: raw)
            }
        }
        guard let json else { return nil }
        return decode(RetrievalLogEnvelope.self, from: json)
    }

    // MARK: - Lifecycle (Phase 3 — supersede / verify / decay / queue depth)

    /// Result of a supersede operation.
    struct SupersedeResult: Codable, Equatable {
        let oldID: String
        let newID: String
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case oldID = "old_id"
            case newID = "new_id"
            case reason
        }
    }

    /// Result of a verify operation. `confidence` reflects the new value
    /// after the verdict was applied (0.9 floor for confirmed, 0.4
    /// ceiling for disputed).
    struct VerifyResult: Codable, Equatable {
        let nodeID: String
        let verdict: String
        let confidence: Double
        let actorID: String

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case verdict
            case confidence
            case actorID = "actor_id"
        }
    }

    /// Result of a decay operation.
    struct DecayResult: Codable, Equatable {
        let nodeID: String
        let archived: Bool
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case archived
            case reason
        }
    }

    /// Enrichment queue depth — drives the Knowledge → System backfill
    /// chip during migration drain. Mirrors `enrichment::QueueDepth`.
    struct EnrichmentQueueDepth: Codable, Equatable {
        let queued: Int
        let running: Int
        let done: Int
        let failed: Int

        var inFlight: Int { queued + running }
        var idle: Bool { inFlight == 0 }
    }

    /// Mark `oldID` as superseded by `newID`. Returns `nil` on daemon
    /// failure or if either node is missing/archived.
    static func supersede(oldID: String, newID: String, reason: String? = nil) -> SupersedeResult? {
        let json = oldID.withCString { oldC in
            newID.withCString { newC in
                withOptionalCString(reason) { reasonC -> String? in
                    guard let raw = tado_dome_node_supersede(oldC, newC, reasonC) else { return nil }
                    defer { tado_string_free(raw) }
                    return String(cString: raw)
                }
            }
        }
        guard let json else { return nil }
        return decode(SupersedeResult.self, from: json)
    }

    /// Confirm or dispute a graph_node. `verdict` ∈ `{"confirmed", "disputed"}`.
    static func verify(
        nodeID: String,
        verdict: String,
        agentID: String? = nil,
        reason: String? = nil
    ) -> VerifyResult? {
        let json = nodeID.withCString { nodeC in
            verdict.withCString { verdictC in
                withOptionalCString(agentID) { agentC in
                    withOptionalCString(reason) { reasonC -> String? in
                        guard let raw = tado_dome_node_verify(nodeC, verdictC, agentC, reasonC) else {
                            return nil
                        }
                        defer { tado_string_free(raw) }
                        return String(cString: raw)
                    }
                }
            }
        }
        guard let json else { return nil }
        return decode(VerifyResult.self, from: json)
    }

    /// Soft-archive a graph_node.
    static func decayNode(nodeID: String, reason: String? = nil) -> DecayResult? {
        let json = nodeID.withCString { nodeC in
            withOptionalCString(reason) { reasonC -> String? in
                guard let raw = tado_dome_node_decay(nodeC, reasonC) else { return nil }
                defer { tado_string_free(raw) }
                return String(cString: raw)
            }
        }
        guard let json else { return nil }
        return decode(DecayResult.self, from: json)
    }

    /// Read enrichment queue depth. Used by the Knowledge → System
    /// backfill chip and for surfacing pipeline health.
    static func enrichmentQueueDepth() -> EnrichmentQueueDepth? {
        guard let raw = tado_dome_enrichment_queue_depth() else { return nil }
        defer { tado_string_free(raw) }
        return decode(EnrichmentQueueDepth.self, from: String(cString: raw))
    }

    // MARK: - Vault admin (reindex / stats / ingest)

    /// Snapshot of chunk counts by embedding model — used by
    /// KnowledgeSystemSurface's "Embeddings" panel to show how many
    /// chunks are still on legacy `noop@1` embeddings vs. Qwen3.
    struct EmbeddingStats: Codable, Equatable {
        let modelCounts: [String: Int]
        let total: Int

        enum CodingKeys: String, CodingKey {
            case modelCounts = "model_counts"
            case total
        }
    }

    /// Result of `vaultIngestPath`. `capped == true` means the 5000-
    /// file safety cap was hit and the user should narrow the path.
    /// `canceled == true` means the user clicked Cancel mid-walk.
    struct IngestResult: Codable, Equatable {
        let created: Int
        let skipped: Int
        let capped: Bool
        let canceled: Bool?
    }

    /// Live snapshot of the legacy ingest's progress counters. The UI
    /// polls this every ~1 s while ingest is busy so the user can see
    /// "47 / 290 files" instead of an opaque "Ingesting…" forever.
    struct IngestProgress: Codable, Equatable {
        let running: Bool
        let created: Int
        let skipped: Int
        let total: Int
        let canceled: Bool

        /// Fraction in [0, 1]. Returns 0 when total isn't known yet.
        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1.0, Double(created + skipped) / Double(total))
        }
    }

    /// Re-runs every doc through the live embedder. Long-running —
    /// Swift callers should wrap in `Task.detached` and surface a
    /// busy state. Returns `true` on success.
    @discardableResult
    static func vaultReindex() -> Bool {
        guard let raw = tado_dome_vault_reindex() else { return false }
        defer { tado_string_free(raw) }
        return true
    }

    static func embeddingStats() -> EmbeddingStats? {
        guard let raw = tado_dome_vault_embedding_stats() else { return nil }
        defer { tado_string_free(raw) }
        return decode(EmbeddingStats.self, from: String(cString: raw))
    }

    /// Walk `path` and ingest every eligible file as a Dome note.
    /// Scope determines `owner_scope` / `project_id` / `project_root`.
    static func ingestPath(
        _ path: String,
        topic: String? = "codebase",
        domeScope: DomeScopeSelection
    ) -> IngestResult? {
        let ownerScope = domeScope.ownerScope
        let projectID = domeScope.projectIDString
        let projectRoot = domeScope.projectRoot
        let json = path.withCString { pathC in
            ownerScope.withCString { ownerC -> String? in
                withOptionalCString(topic) { topicC in
                    withOptionalCString(projectID) { pidC in
                        withOptionalCString(projectRoot) { rootC -> String? in
                            guard let raw = tado_dome_vault_ingest_path(
                                pathC, topicC, ownerC, pidC, rootC
                            ) else { return nil }
                            defer { tado_string_free(raw) }
                            return String(cString: raw)
                        }
                    }
                }
            }
        }
        return decode(IngestResult.self, from: json)
    }

    /// Read live progress for the legacy `ingestPath` walk. Always
    /// returns a value when the daemon is up — `running == false`
    /// when no ingest is active.
    static func ingestProgress() -> IngestProgress? {
        guard let raw = tado_dome_vault_ingest_progress() else { return nil }
        defer { tado_string_free(raw) }
        return decode(IngestProgress.self, from: String(cString: raw))
    }

    /// Request the in-flight ingest to stop at the next file
    /// boundary. Idempotent. Returns `true` if an ingest was running.
    @discardableResult
    static func ingestCancel() -> Bool {
        return tado_dome_vault_ingest_cancel() == 1
    }

    // MARK: - Embedding model lifecycle

    /// Snapshot of the Qwen3-Embedding-0.6B model fetch + load state.
    /// `ready == true` means future Dome searches go through the real
    /// model; `false` means callers are still seeing FNV-1a stub
    /// vectors and the onboarding panel should keep blocking.
    struct ModelStatus: Codable, Equatable {
        let ready: Bool
        let filesPresent: Bool
        let downloadedBytes: Int64
        let totalBytes: Int64
        let currentFile: String?
        let completed: Bool
        let error: String?

        enum CodingKeys: String, CodingKey {
            case ready
            case filesPresent = "files_present"
            case downloadedBytes = "downloaded_bytes"
            case totalBytes = "total_bytes"
            case currentFile = "current_file"
            case completed
            case error
        }

        var fractionComplete: Double {
            guard totalBytes > 0 else { return ready ? 1.0 : 0.0 }
            return min(1.0, Double(downloadedBytes) / Double(totalBytes))
        }
    }

    /// Read the live model status. Always succeeds — the FFI never
    /// returns null here.
    static func modelStatus() -> ModelStatus? {
        guard let raw = tado_dome_model_status() else { return nil }
        defer { tado_string_free(raw) }
        return decode(ModelStatus.self, from: String(cString: raw))
    }

    /// Kick off the model download. Idempotent. Returns `true` on a
    /// successful spawn (or "already running"), `false` if the daemon
    /// hasn't booted yet.
    @discardableResult
    static func startModelFetch() -> Bool {
        tado_dome_model_fetch_start() == 0
    }

    /// Point Dome at a manually-supplied model directory (for users
    /// behind corporate proxies who pre-downloaded the files). The
    /// directory must contain `config.json`, `tokenizer.json`, and
    /// `model.safetensors`.
    @discardableResult
    static func setModelPath(_ path: String) -> Bool {
        path.withCString { pathC in
            tado_dome_model_set_path(pathC) == 0
        }
    }

    // MARK: - Code indexing (Phase 2)

    /// Result of a full code-index run, mirrored from
    /// `bt_core::code::indexer::IndexResult`.
    struct CodeIndexResult: Codable, Equatable {
        let projectID: String
        let filesIndexed: Int
        let filesSkippedUnchanged: Int
        let filesSkippedSize: Int
        let filesSkippedBinary: Int
        let filesSkippedExtension: Int
        let chunksTotal: Int
        let bytesTotal: Int
        let truncated: Bool

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case filesIndexed = "files_indexed"
            case filesSkippedUnchanged = "files_skipped_unchanged"
            case filesSkippedSize = "files_skipped_size"
            case filesSkippedBinary = "files_skipped_binary"
            case filesSkippedExtension = "files_skipped_extension"
            case chunksTotal = "chunks_total"
            case bytesTotal = "bytes_total"
            case truncated
        }
    }

    /// Live progress snapshot of a running index. Polled via the
    /// `code.index_status` FFI; populated atomically by the indexer.
    struct CodeIndexStatus: Codable, Equatable {
        let projectID: String
        let filesTotal: Int
        let filesDone: Int
        let chunksDone: Int
        let bytesDone: Int
        let running: Bool
        let error: String?
        let startedAt: String?
        let finishedAt: String?

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case filesTotal = "files_total"
            case filesDone = "files_done"
            case chunksDone = "chunks_done"
            case bytesDone = "bytes_done"
            case running
            case error
            case startedAt = "started_at"
            case finishedAt = "finished_at"
        }

        var fractionComplete: Double {
            guard filesTotal > 0 else { return 0 }
            return min(1.0, Double(filesDone) / Double(filesTotal))
        }
    }

    /// Per-project summary returned by `code.list_projects`.
    struct CodeProjectSummary: Identifiable, Codable, Equatable {
        let projectID: String
        let name: String
        let rootPath: String
        let enabled: Bool
        let lastFullIndexAt: String?
        let embeddingModelID: String?
        let embeddingModelVersion: String?
        let fileCount: Int
        let chunkCount: Int

        var id: String { projectID }

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case name
            case rootPath = "root_path"
            case enabled
            case lastFullIndexAt = "last_full_index_at"
            case embeddingModelID = "embedding_model_id"
            case embeddingModelVersion = "embedding_model_version"
            case fileCount = "file_count"
            case chunkCount = "chunk_count"
        }
    }

    private struct CodeProjectsEnvelope: Codable {
        let projects: [CodeProjectSummary]
    }

    /// Register a project for code indexing. Idempotent.
    @discardableResult
    static func codeRegisterProject(
        projectID: String,
        name: String,
        rootPath: String,
        enabled: Bool = true
    ) -> Bool {
        projectID.withCString { idC in
            name.withCString { nameC in
                rootPath.withCString { rootC in
                    guard let raw = tado_dome_code_register_project(idC, nameC, rootC, enabled) else {
                        return false
                    }
                    tado_string_free(raw)
                    return true
                }
            }
        }
    }

    /// Unregister a project. With `purge=true`, deletes every chunk
    /// row for the project too.
    @discardableResult
    static func codeUnregisterProject(projectID: String, purge: Bool = true) -> Bool {
        projectID.withCString { idC in
            guard let raw = tado_dome_code_unregister_project(idC, purge) else {
                return false
            }
            tado_string_free(raw)
            return true
        }
    }

    /// List every registered code project plus per-project file/chunk
    /// counts.
    static func codeListProjects() -> [CodeProjectSummary] {
        guard let raw = tado_dome_code_list_projects() else { return [] }
        defer { tado_string_free(raw) }
        let json = String(cString: raw)
        return decode(CodeProjectsEnvelope.self, from: json)?.projects ?? []
    }

    /// Run a full code index. **Blocks for minutes** on a multi-thousand
    /// file project — invoke from `Task.detached` and poll status from
    /// the main thread for the UI bar.
    static func codeIndexProject(projectID: String, fullRebuild: Bool = false) -> CodeIndexResult? {
        projectID.withCString { idC in
            guard let raw = tado_dome_code_index_project(idC, fullRebuild) else { return nil }
            defer { tado_string_free(raw) }
            return decode(CodeIndexResult.self, from: String(cString: raw))
        }
    }

    /// One ranked code chunk from `dome_code_search`.
    struct CodeSearchHit: Codable, Equatable, Identifiable {
        let projectID: String
        let repoPath: String
        let chunkIndex: Int
        let language: String
        let nodeKind: String?
        let qualifiedName: String?
        let startLine: Int
        let endLine: Int
        let excerpt: String
        let vectorScore: Double?
        let lexicalScore: Double?
        let combinedScore: Double

        var id: String {
            "\(projectID):\(repoPath):\(chunkIndex)"
        }

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case repoPath = "repo_path"
            case chunkIndex = "chunk_index"
            case language
            case nodeKind = "node_kind"
            case qualifiedName = "qualified_name"
            case startLine = "start_line"
            case endLine = "end_line"
            case excerpt
            case vectorScore = "vector_score"
            case lexicalScore = "lexical_score"
            case combinedScore = "combined_score"
        }
    }

    private struct CodeSearchEnvelope: Codable {
        let results: [CodeSearchHit]
    }

    /// Hybrid (vector + lexical) search across registered code
    /// projects. Runs synchronously on whatever thread you call it
    /// from — typically Task.detached in UI code, the main thread is
    /// fine for small (limit ≤ 50) queries.
    static func codeSearch(
        query: String,
        projectIDs: [String]? = nil,
        languages: [String]? = nil,
        limit: Int = 25,
        alpha: Double? = nil
    ) -> [CodeSearchHit] {
        var body: [String: Any] = [
            "query": query,
            "limit": limit,
        ]
        if let projectIDs, !projectIDs.isEmpty {
            body["project_ids"] = projectIDs
        }
        if let languages, !languages.isEmpty {
            body["languages"] = languages
        }
        if let alpha {
            body["alpha"] = alpha
        }
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: []),
              let jsonString = String(data: json, encoding: .utf8) else {
            return []
        }
        return jsonString.withCString { jsonC -> [CodeSearchHit] in
            guard let raw = tado_dome_code_search(jsonC) else { return [] }
            defer { tado_string_free(raw) }
            return decode(CodeSearchEnvelope.self, from: String(cString: raw))?.results ?? []
        }
    }

    // MARK: - Code watching (Phase 4)

    private struct CodeWatchListEnvelope: Codable {
        let watching: [String]
    }

    /// Start a file watcher for a registered project. The watcher
    /// debounces 500 ms and incrementally re-embeds changed files.
    /// Idempotent — calling twice replaces the prior watcher.
    @discardableResult
    static func codeWatchStart(projectID: String) -> Bool {
        projectID.withCString { idC in
            guard let raw = tado_dome_code_watch_start(idC) else { return false }
            tado_string_free(raw)
            return true
        }
    }

    /// Stop the file watcher for a project. No-op if no watcher was
    /// running.
    @discardableResult
    static func codeWatchStop(projectID: String) -> Bool {
        projectID.withCString { idC in
            guard let raw = tado_dome_code_watch_stop(idC) else { return false }
            tado_string_free(raw)
            return true
        }
    }

    /// Every project_id with an active file watcher.
    static func codeWatchList() -> [String] {
        guard let raw = tado_dome_code_watch_list() else { return [] }
        defer { tado_string_free(raw) }
        return decode(CodeWatchListEnvelope.self, from: String(cString: raw))?.watching ?? []
    }

    /// Reattach watchers for every `enabled=1` project. Idempotent.
    /// Returns the list of project IDs that were started in this
    /// call (excludes ones that already had a watcher).
    @discardableResult
    static func codeWatchResumeAll() -> [String] {
        guard let raw = tado_dome_code_watch_resume_all() else { return [] }
        defer { tado_string_free(raw) }
        struct Resume: Codable { let started: [String] }
        return decode(Resume.self, from: String(cString: raw))?.started ?? []
    }

    /// Stop every active watcher. Returns the project IDs whose
    /// watchers were running. Used when the per-user kill switch
    /// flips OFF.
    @discardableResult
    static func codeWatchStopAll() -> [String] {
        guard let raw = tado_dome_code_watch_stop_all() else { return [] }
        defer { tado_string_free(raw) }
        struct Stop: Codable { let stopped: [String] }
        return decode(Stop.self, from: String(cString: raw))?.stopped ?? []
    }

    /// Cheap polling read of an in-flight index. Safe to call from the
    /// main thread every 250 ms.
    static func codeIndexStatus(projectID: String) -> CodeIndexStatus? {
        projectID.withCString { idC in
            guard let raw = tado_dome_code_index_status(idC) else { return nil }
            defer { tado_string_free(raw) }
            return decode(CodeIndexStatus.self, from: String(cString: raw))
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value else { return body(nil) }
        return value.withCString { body($0) }
    }
}
