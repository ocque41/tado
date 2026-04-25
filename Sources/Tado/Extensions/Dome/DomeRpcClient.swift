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
        domeScope: DomeScopeSelection? = nil
    ) -> GraphSnapshot? {
        let includeTypesJSON: String? = nil
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
