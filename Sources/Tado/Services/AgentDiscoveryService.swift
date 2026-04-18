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

    /// Per-phase model/effort override, extracted from an agent file's YAML
    /// frontmatter. The dispatch architect asks tado-dispatch-agent-creator to
    /// stamp `model:` + `effort:` onto each phase agent so Haiku runs the
    /// volume work while Opus handles design-heavy phases. Spawning code
    /// (ContentView.handleSpawnRequest, DispatchPlanService.startPhaseOne)
    /// turns these into `--model`/`--effort` CLI flags on the session.
    ///
    /// Returns nil fields when the frontmatter doesn't specify them — callers
    /// fall back to the user's AppSettings model/effort picks.
    struct PhaseOverride {
        let modelFlags: [String]?
        let effortFlags: [String]?
    }

    static func phaseOverride(agentName: String, projectRoot: String) -> PhaseOverride {
        let agents = discover(projectRoot: projectRoot)
        guard let agent = agents.first(where: { $0.id == agentName }),
              agent.source == .claude,
              let contents = try? String(contentsOfFile: agent.filePath) else {
            return PhaseOverride(modelFlags: nil, effortFlags: nil)
        }
        let frontmatter = extractFrontmatter(contents)
        let modelShort = frontmatter["model"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        let effortRaw = frontmatter["effort"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
            return trimmed.isEmpty ? nil : trimmed
        }
        let modelFlags: [String]? = modelShort.flatMap { short in
            guard let full = claudeModelID(forShort: short) else { return nil }
            return ["--model", full]
        }
        let effortFlags: [String]? = effortRaw.flatMap { level in
            guard ["low", "medium", "high", "max"].contains(level) else { return nil }
            return ["--effort", level]
        }
        return PhaseOverride(modelFlags: modelFlags, effortFlags: effortFlags)
    }

    /// Map short names used in agent frontmatter to the Claude Code CLI's
    /// `--model <id>` argument. `haiku` → `claude-haiku-4-5`, etc. Returns nil
    /// for unknown short names so frontmatter typos fall back to settings
    /// instead of silently running a different model.
    static func claudeModelID(forShort short: String) -> String? {
        switch short.trimmingCharacters(in: .whitespaces).lowercased() {
        case "haiku", "haiku45", "haiku-4-5", "haiku4.5": return "claude-haiku-4-5"
        case "sonnet", "sonnet46", "sonnet-4-6", "sonnet4.6": return "claude-sonnet-4-6"
        case "opus", "opus47", "opus-4-7", "opus4.7": return "claude-opus-4-7"
        default: return nil
        }
    }

    private static func extractFrontmatter(_ contents: String) -> [String: String] {
        let lines = contents.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colonIndex)...])
            if let hashIndex = value.firstIndex(of: "#") {
                value = String(value[..<hashIndex])
            }
            let cleaned = value.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty {
                result[key] = cleaned
            }
        }
        return result
    }
}
