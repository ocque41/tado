import Foundation

/// Decoded shape of `service.context_resolve(...)` from bt-core. Only
/// the subset the Knowledge → Second Brain Retrieval surface and its
/// P3 acceptance harness need is captured here — extra fields decode
/// into nil and the rest of the JSON envelope is ignored. Adding a
/// field is safe; renaming bt-core's keys requires a coordinated
/// CodingKeys bump on this type.
struct ContextPackResult: Codable, Equatable {
    var resolved: Bool
    var brand: String?
    var mode: String?
    var contextPack: ContextPackSummary?
    var preferredViewPath: String?
    var sourceReferences: [ContextPackSource]?
    var recommendedNextSteps: [String]?

    enum CodingKeys: String, CodingKey {
        case resolved
        case brand
        case mode
        case contextPack = "context_pack"
        case preferredViewPath = "preferred_view_path"
        case sourceReferences = "source_references"
        case recommendedNextSteps = "recommended_next_steps"
    }
}

/// One pack record as returned by `db::list_context_packs`. We keep
/// the original snake_case for `context_id`/`brand` etc.
struct ContextPackSummary: Codable, Equatable {
    var contextId: String
    var brand: String
    var sessionId: String?
    var docId: String?
    var sourceHash: String?
    var summaryPath: String?
    var manifestPath: String?

    enum CodingKeys: String, CodingKey {
        case contextId = "context_id"
        case brand
        case sessionId = "session_id"
        case docId = "doc_id"
        case sourceHash = "source_hash"
        case summaryPath = "summary_path"
        case manifestPath = "manifest_path"
    }
}

/// One citation row inside a pack — the cited doc the agent is meant
/// to expand if the compact summary is insufficient. We surface
/// these as clickable rows that deep-link back to the source note.
struct ContextPackSource: Codable, Equatable, Identifiable {
    var sourceRef: String
    var hash: String?
    var rank: Int?
    var docId: String?
    var title: String?

    enum CodingKeys: String, CodingKey {
        case sourceRef = "source_ref"
        case hash
        case rank
        case docId = "doc_id"
        case title
    }

    var id: String { sourceRef }
}

/// Engine the Knowledge surface talks to for context-pack work. Has
/// two implementations: one wired to `DomeRpcClient` (live FFI), one
/// in-memory (used by `ContextPackTests`). The protocol layer also
/// satisfies the brief's "pack resolve/compact round-trip" acceptance:
/// the harness drives the protocol, so the round-trip contract is
/// pinned even when the Rust daemon isn't booted.
protocol ContextPackEngine: AnyObject {
    func resolve(brand: String?, sessionID: String?, docID: String?, mode: String?) -> ContextPackResult?
    func compact(brand: String, sessionID: String?, docID: String?, force: Bool) -> ContextPackResult?
}

/// Live engine — calls the new `tado_dome_context_resolve` and
/// `tado_dome_context_compact` FFI exports. Returns nil on daemon-down
/// or any FFI/decoding failure.
final class DomeContextPackEngine: ContextPackEngine {
    func resolve(brand: String?, sessionID: String?, docID: String?, mode: String?) -> ContextPackResult? {
        DomeRpcClient.contextResolve(brand: brand, sessionID: sessionID, docID: docID, mode: mode)
    }
    func compact(brand: String, sessionID: String?, docID: String?, force: Bool) -> ContextPackResult? {
        DomeRpcClient.contextCompact(brand: brand, sessionID: sessionID, docID: docID, force: force)
    }
}

/// `tado://` deep-link helper for citation rows. Mirrors the contract
/// established for events in `EventLedger.deepLink(for:)` — `dome/<id>`
/// for note ids, `pack/<context_id>` when only the pack is known.
enum ContextPackDeepLink {
    static func sourceLink(for source: ContextPackSource) -> String? {
        if let docID = source.docId, !docID.isEmpty {
            return "tado://dome/\(docID)"
        }
        // `source_ref` looks like "doc:<id>" or "pack:<context_id>".
        let trimmed = source.sourceRef.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("doc:") {
            return "tado://dome/\(String(trimmed.dropFirst(4)))"
        }
        if trimmed.hasPrefix("pack:") {
            return "tado://dome/pack/\(String(trimmed.dropFirst(5)))"
        }
        return nil
    }

    static func packLink(for summary: ContextPackSummary) -> String {
        "tado://dome/pack/\(summary.contextId)"
    }
}
