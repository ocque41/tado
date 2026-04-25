import Foundation

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
    static func build(for ctx: Context) -> String? {
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
        let bullets = ordered.map { note -> String in
            let ts = note.updatedAt ?? note.createdAt
            if let ts {
                let rel = Self.rel.localizedString(for: ts, relativeTo: Date())
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

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

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
