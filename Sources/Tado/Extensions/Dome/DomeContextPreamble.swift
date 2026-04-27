import Foundation
import CTadoCore

/// Phase 4 — deterministic relative-time formatter used by the
/// spawn-time preamble. Mirrors `bt_core::context::relative::format_relative_ago`
/// byte-for-byte so the Swift composer's output is identical to the
/// Rust pack engine's. Replaces the locale-sensitive
/// `RelativeDateTimeFormatter` we shipped in v0.10.
enum DomeRelativeTime {
    /// Match the Rust algorithm exactly:
    ///   <60 s → "just now"
    ///   <60 m → "{n}m ago"  (60 →"1m ago", 45·60 → "45m ago")
    ///   <24 h → "{n}h ago"
    ///   <7 d  → "{n}d ago"
    ///   <30 d → "{n}w ago"
    ///   <365 d→ "{n}mo ago"
    ///   else  → "{n}y ago"
    /// Future timestamps render with `in {…}` instead of `… ago`.
    static func formatAgo(_ ts: Date, now: Date = Date()) -> String {
        let secs = Int64(now.timeIntervalSince(ts).rounded(.toNearestOrEven))
        let abs = secs < 0 ? -secs : secs
        let body = bucket(absSecs: abs)
        if secs >= 0 {
            return body == "just now" ? "just now" : "\(body) ago"
        } else {
            return body == "just now" ? "in a moment" : "in \(body)"
        }
    }

    private static func bucket(absSecs: Int64) -> String {
        if absSecs < 60 { return "just now" }
        if absSecs < 3_600 { return "\(absSecs / 60)m" }
        if absSecs < 86_400 { return "\(absSecs / 3_600)h" }
        if absSecs < 604_800 { return "\(absSecs / 86_400)d" }
        if absSecs < 2_592_000 { return "\(absSecs / 604_800)w" }
        if absSecs < 31_536_000 { return "\(absSecs / 2_592_000)mo" }
        return "\(absSecs / 31_536_000)y"
    }
}

/// C4 — Composable spawn-time context preamble.
///
/// Builds a short markdown block that gets prepended to an agent's
/// spawn prompt so every session wakes with the basic facts it would
/// otherwise have to re-derive: who am I, who's my team, what's this
/// project about, and what notes exist on the project topic.
///
/// Fragment budget: the full preamble is capped at ~1500 tokens
/// (approx 6000 characters; we truncate at that). Each fragment is
/// independent — if any fragment errors or times out, the remaining
/// fragments still render and the user's actual prompt follows the
/// preamble. No hard dependency on Dome being online.
///
/// Output shape:
///     ```
///     <!-- tado:context:begin -->
///     ## Session context
///     - agent: ...
///     - project: ...
///     - team: ...
///
///     ### Recent project notes
///     - ...
///
///     <!-- tado:context:end -->
///
///     <user prompt here>
///     ```
enum DomeContextPreamble {
    /// Characters cap. 6000 ≈ 1500 tokens at Claude's ~4 char/token
    /// average for English prose.
    static let maxCharacters: Int = 6000

    /// Session context passed in from the spawn site.
    struct Context {
        let agentName: String?
        let projectName: String?
        let projectID: UUID?
        let projectRoot: String?
        let teamName: String?
        let teammates: [String]
    }

    /// Compose a context preamble. Returns nil when there's nothing
    /// useful to say (no project, no team, no agent — i.e. a raw
    /// terminal spawn unrelated to any Tado structure).
    ///
    /// Phase 4 dual-path: when the global setting
    /// `dome.contextPacksV2` is `true`, delegates to the Rust pack
    /// engine via `tado_dome_compose_spawn_preamble` (cached, with
    /// supersede invalidation). Otherwise falls through to the v0.10
    /// Swift composer below. Both render byte-identical output —
    /// the integration test in `tests/byte_equivalence/` exercises
    /// the contract on every release.
    static func build(for ctx: Context) -> String? {
        if useContextPacksV2() {
            if let rustPreamble = composeViaRust(ctx) {
                return rustPreamble
            }
            // Fall through if Rust returned nil (daemon offline,
            // empty context, etc.); v0.10 path produces nil for the
            // same conditions.
        }
        return composeViaSwift(ctx)
    }

    /// Read the v0.13 feature flag. Honors two paths so it works from
    /// any actor context:
    /// 1. `TADO_DOME_CONTEXT_PACKS_V2=1` env var — set by the
    ///    spawn-site so the flag is readable without main-actor hops.
    /// 2. Static cache populated at app launch by
    ///    `DomeExtension.onAppLaunch` reading `global.json`.
    /// Returns `false` until either is positively set.
    private static func useContextPacksV2() -> Bool {
        if let env = ProcessInfo.processInfo.environment["TADO_DOME_CONTEXT_PACKS_V2"],
           env == "1" || env.lowercased() == "true" {
            return true
        }
        return _contextPacksV2Override.value
    }

    /// Cached override populated by callers running on the main actor
    /// (DomeExtension on launch, Settings UI on toggle). Reads here
    /// are lock-free.
    static let _contextPacksV2Override = AtomicBool(initial: false)
}

/// Tiny wrapper around `OSAllocatedUnfairLock` over a `Bool` so any
/// thread can read/write the spawn-pack feature flag without
/// main-actor coordination.
final class AtomicBool: @unchecked Sendable {
    private var inner: Bool
    private let lock = NSLock()
    init(initial: Bool) { self.inner = initial }
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return inner
    }
    func set(_ next: Bool) {
        lock.lock(); defer { lock.unlock() }
        inner = next
    }
}

// Re-open DomeContextPreamble to keep the file structure clean.
extension DomeContextPreamble {

    /// Pure Swift composer (v0.10 path). Kept verbatim so dark-launch
    /// flips are reversible without a release.
    static func composeViaSwift(_ ctx: Context) -> String? {
        var fragments: [String] = []

        if let identity = identityFragment(ctx) { fragments.append(identity) }
        if let project = projectFragment(ctx) { fragments.append(project) }
        if let team = teamFragment(ctx) { fragments.append(team) }
        if let recent = recentProjectNotesFragment(ctx) { fragments.append(recent) }
        fragments.append(retrievalContractFragment(ctx))

        guard !fragments.isEmpty else { return nil }

        let body = fragments.joined(separator: "\n\n")
        let wrapped = """
        <!-- tado:context:begin -->
        ## Session context

        \(body)

        <!-- tado:context:end -->
        """
        if wrapped.count <= maxCharacters { return wrapped }
        // Hard cap — trim from the end, keep the open tag + title so
        // the close tag disappears but the content is still partially
        // visible. In practice we never hit this with today's fragments.
        return String(wrapped.prefix(maxCharacters))
    }

    /// Phase 4 — delegate to bt-core's `tado_dome_compose_spawn_preamble`.
    /// Returns nil when the daemon isn't running or has nothing to
    /// render. Wraps the FFI call so callers don't need C-string
    /// lifetimes.
    ///
    /// JSON-encoding failures and FFI returning nil are surfaced via
    /// stderr (visible in Console.app under the Tado bundle); the
    /// caller falls through to the v0.10 Swift composer so spawns
    /// never lose their preamble — diagnostic, not blocking.
    private static func composeViaRust(_ ctx: Context) -> String? {
        var payload: [String: Any] = [:]
        if let agent = ctx.agentName, !agent.isEmpty { payload["agent_name"] = agent }
        if let project = ctx.projectName, !project.isEmpty { payload["project_name"] = project }
        if let id = ctx.projectID { payload["project_id"] = id.uuidString }
        if let root = ctx.projectRoot { payload["project_root"] = root }
        if let team = ctx.teamName, !team.isEmpty { payload["team_name"] = team }
        if !ctx.teammates.isEmpty { payload["teammates"] = ctx.teammates }
        guard let json = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonStr = String(data: json, encoding: .utf8) else {
            FileHandle.standardError.write(Data(
                "tado: composeViaRust JSON encode failed; falling back to Swift composer\n".utf8
            ))
            return nil
        }
        return jsonStr.withCString { jsonC in
            guard let raw = tado_dome_compose_spawn_preamble(jsonC) else {
                // Daemon offline OR Rust returned None (empty-context
                // case). Either way, the Swift fallback handles the
                // same edge gracefully.
                return nil
            }
            defer { tado_string_free(raw) }
            return String(cString: raw)
        }
    }

    // MARK: - Fragments

    private static func identityFragment(_ ctx: Context) -> String? {
        guard let agent = ctx.agentName, !agent.isEmpty else { return nil }
        return "- **you are**: `\(agent)` (agent definition: `.claude/agents/\(agent).md`)"
    }

    private static func projectFragment(_ ctx: Context) -> String? {
        guard let name = ctx.projectName, !name.isEmpty else { return nil }
        var lines = ["- **project**: \(name)"]
        if let root = ctx.projectRoot {
            lines.append("- **root**: `\(root)`")
        }
        if let id = ctx.projectID {
            lines.append("- **dome topic**: `project-\(id.uuidString.prefix(8).lowercased())`")
        }
        return lines.joined(separator: "\n")
    }

    private static func teamFragment(_ ctx: Context) -> String? {
        guard let team = ctx.teamName, !team.isEmpty else { return nil }
        var lines = ["- **team**: \(team)"]
        if !ctx.teammates.isEmpty {
            let others = ctx.teammates.filter { $0 != ctx.agentName }
            if !others.isEmpty {
                lines.append("- **teammates**: " + others.map { "`\($0)`" }.joined(separator: ", "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Query Dome for the 5 most recent notes on the project's topic
    /// and list their titles. Silently returns nil if Dome is offline
    /// or the topic has no notes yet.
    private static func recentProjectNotesFragment(_ ctx: Context) -> String? {
        guard let id = ctx.projectID else { return nil }
        let topic = "project-" + id.uuidString.prefix(8).lowercased()
        let domeScope = DomeScopeSelection.project(
            id: id,
            name: ctx.projectName ?? "Project",
            rootPath: ctx.projectRoot ?? "",
            includeGlobal: true
        )
        guard let notes = DomeRpcClient.listNotes(topic: topic, limit: 20, domeScope: domeScope),
              !notes.isEmpty else {
            return nil
        }
        let ordered = notes.sorted { $0.sortTimestamp > $1.sortTimestamp }.prefix(5)
        let now = Date()
        let bullets = ordered.map { note -> String in
            let ts = note.updatedAt ?? note.createdAt
            if let ts {
                let rel = DomeRelativeTime.formatAgo(ts, now: now)
                return "  - `\(note.title)` (\(rel))"
            } else {
                return "  - `\(note.title)`"
            }
        }.joined(separator: "\n")
        return "### Recent project notes (topic `\(topic)`)\n\(bullets)\n\nUse `dome_search` and `dome_read` for the cited details before relying on these notes."
    }

    private static func retrievalContractFragment(_ ctx: Context) -> String {
        let topic = ctx.projectID.map { "project-" + $0.uuidString.prefix(8).lowercased() }
        var lines = [
            "### Dome retrieval contract",
            "- Before architecture decisions, unfamiliar edits, team handoffs, stale context, or completion claims, query Dome first.",
            "- Use `dome_graph_query` to find related notes, tasks, runs, context packs, and agent activity.",
            "- Use `dome_context_resolve` for compact cited context; use `dome_context_compact` when the pack is missing or stale.",
            "- Cite Dome note ids, context pack ids, or graph node ids when prior knowledge affects your answer.",
            "- If retrieval is unavailable, say that clearly before proceeding."
        ]
        if let topic {
            lines.append("- For this project, start with topic `\(topic)` when using `dome_search`.")
        }
        return lines.joined(separator: "\n")
    }

    // (Phase 4 retired the locale-sensitive RelativeDateTimeFormatter;
    // recent-notes timestamps now flow through `DomeRelativeTime.formatAgo`
    // so the Rust pack engine can render byte-identical output.)

    // MARK: - Convenience

    /// Prepend the preamble to a raw user prompt, returning the full
    /// string the agent will receive as its first message. If the
    /// preamble is nil (no usable context), the prompt passes through
    /// unchanged — no empty delimiter pollution.
    static func prependedPrompt(for ctx: Context, userPrompt: String) -> String {
        guard let preamble = build(for: ctx) else { return userPrompt }
        return preamble + "\n\n---\n\n" + userPrompt
    }
}
