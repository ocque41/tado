import Foundation

/// C3 — Team roster mirror into Dome.
///
/// Every time a Tado team is created or its membership changes, we
/// write a Dome note under the project's topic describing who's on
/// the team. The context preamble (C4) reads from this topic to
/// answer "who are my teammates" without re-scraping SwiftData.
///
/// Note title convention: `team-<sanitized-team-name>`. A new write
/// with the same title creates a new note (bt-core's doc_create
/// rejects duplicates with the same folder slug — we swallow that
/// via DomeRpcClient returning nil). Follow-up phase: expose a
/// `tado_dome_note_upsert` FFI that creates-or-updates.
enum DomeTeamTopic {
    static func writeRoster(project: Project, team: Team) {
        let topic = DomeProjectMemory.topic(for: project)
        let title = "team-" + Self.sanitize(team.name)
        let rosterBody = Self.rosterMarkdown(project: project, team: team)

        Task.detached(priority: .utility) {
            _ = DomeRpcClient.writeNote(
                scope: .user,
                topic: topic,
                title: title,
                body: rosterBody,
                domeScope: .project(id: project.id, name: project.name, rootPath: project.rootPath, includeGlobal: true),
                knowledgeKind: "system"
            )
        }
    }

    private static func rosterMarkdown(project: Project, team: Team) -> String {
        let agentList: String
        if team.agentNames.isEmpty {
            agentList = "_No agents yet._"
        } else {
            agentList = team.agentNames
                .map { "- `\($0)` — see `.claude/agents/\($0).md`" }
                .joined(separator: "\n")
        }
        return """
        # Team \(team.name)

        - **project**: \(project.name) (`\(project.rootPath)`)
        - **project_id**: \(project.id.uuidString)
        - **team_id**: \(team.id.uuidString)

        ## Agents
        \(agentList)

        ## How to reach
        `tado-list --team '\(team.name)'` to discover live sessions; \
        `tado-send <grid> "<message>"` to message. Shared project \
        memory: `dome_search --topic \(DomeProjectMemory.topic(for: project))`.
        """
    }

    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = s.lowercased().replacingOccurrences(of: " ", with: "-")
        return String(lowered.unicodeScalars.filter { allowed.contains($0) }.prefix(40))
    }
}
