import Foundation

enum AgentDiscoveryService {
    static func discover(projectRoot: String) -> [AgentDefinition] {
        let rootURL = URL(fileURLWithPath: projectRoot)
        let fm = FileManager.default

        var results: [AgentDefinition] = []

        let sources: [(path: String, source: AgentDefinition.AgentSource)] = [
            (".claude/agents", .claude),
            (".codex/agents", .codex),
        ]

        for (subpath, source) in sources {
            let dir = rootURL.appendingPathComponent(subpath)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension == "md" {
                let stem = file.deletingPathExtension().lastPathComponent
                let agent = AgentDefinition(id: stem, filePath: file.path, source: source)
                results.append(agent)
            }
        }

        return results.sorted { $0.name < $1.name }
    }

    /// Resolve which engine an agent belongs to based on its parent directory.
    /// Agents under `.claude/agents/` → `.claude` engine, `.codex/agents/` → `.codex` engine.
    /// Returns nil if the agent is not found (caller falls back to user settings).
    static func resolveEngine(agentName: String, projectRoot: String) -> TerminalEngine? {
        let agents = discover(projectRoot: projectRoot)
        guard let agent = agents.first(where: { $0.id == agentName }) else {
            return nil
        }
        switch agent.source {
        case .claude: return .claude
        case .codex: return .codex
        }
    }
}
