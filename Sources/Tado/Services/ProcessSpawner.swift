import Foundation

enum ProcessSpawner {
    static func command(for todoText: String, engine: TerminalEngine, modeFlags: [String] = [], effortFlags: [String] = [], agentName: String? = nil) -> (executable: String, args: [String]) {
        let escaped = shellEscape(todoText)
        let cli = engine.rawValue
        var flags = modeFlags + effortFlags
        if let agentName, engine == .claude {
            flags.insert(contentsOf: ["--agent", agentName], at: 0)
        }
        let allFlags = flags.joined(separator: " ")
        let cmd = allFlags.isEmpty ? "\(cli) \(escaped)" : "\(cli) \(allFlags) \(escaped)"
        return ("/bin/zsh", ["-l", "-c", cmd])
    }

    static func shellEscape(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    static func environment(
        sessionID: UUID,
        sessionName: String,
        engine: TerminalEngine,
        ipcRoot: URL,
        projectName: String? = nil,
        projectRoot: String? = nil,
        teamName: String? = nil,
        teamID: UUID? = nil,
        agentName: String? = nil,
        teamAgents: [String]? = nil
    ) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TADO_IPC_ROOT"] = ipcRoot.path
        env["TADO_SESSION_ID"] = sessionID.uuidString.lowercased()
        env["TADO_SESSION_NAME"] = sessionName
        env["TADO_ENGINE"] = engine.rawValue
        if let projectName { env["TADO_PROJECT_NAME"] = projectName }
        if let projectRoot { env["TADO_PROJECT_ROOT"] = projectRoot }
        if let teamName { env["TADO_TEAM_NAME"] = teamName }
        if let teamID { env["TADO_TEAM_ID"] = teamID.uuidString.lowercased() }
        if let agentName { env["TADO_AGENT_NAME"] = agentName }
        if let teamAgents, !teamAgents.isEmpty { env["TADO_TEAM_AGENTS"] = teamAgents.joined(separator: ",") }
        let binPath = ipcRoot.appendingPathComponent("bin").path
        if let existingPath = env["PATH"] {
            env["PATH"] = binPath + ":" + existingPath
        } else {
            env["PATH"] = binPath
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Bootstrap Tools

    /// Resolve the Tado repo root directory at runtime.
    /// Walks up from the app bundle looking for CLAUDE.md + Sources/Tado/,
    /// falls back to ~/Documents/tado.
    static func tadoRepoRoot() -> String? {
        let fm = FileManager.default

        // Walk up from bundle location (swift build puts binary at .build/debug/Tado)
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let claude = dir.appendingPathComponent("CLAUDE.md")
            let sources = dir.appendingPathComponent("Sources/Tado")
            if fm.fileExists(atPath: claude.path) && fm.fileExists(atPath: sources.path) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }

        // Fallback: ~/Documents/tado
        let fallback = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/tado")
        if fm.fileExists(atPath: fallback.appendingPathComponent("CLAUDE.md").path) {
            return fallback.path
        }

        return nil
    }

    /// Generate the prompt for a bootstrap agent that injects A2A CLI docs into a target project.
    static func bootstrapPrompt(targetPath: String) -> String {
        """
        Read the 'Tado A2A' section from ./CLAUDE.md and the 'Tado A2A', \
        'Contacting Other Agents', 'Deploying Agents', 'Responding to Agent Requests (Mandatory)', \
        and 'Message Origin Rules' sections from ./AGENTS.md in this directory. \
        Then inject that documentation into the project at \(targetPath).

        Steps:
        1. Check \(targetPath)/CLAUDE.md \u{2014} if it exists and already has a '## Tado A2A' section, \
        skip it. Otherwise append the Tado A2A section to the end of the file. \
        If the file doesn't exist, create it with a '# CLAUDE.md' header first.
        2. Check \(targetPath)/AGENTS.md \u{2014} same logic: if it exists and already has '## Tado A2A', \
        skip. Otherwise append the Tado A2A section, the Contacting Other Agents section, \
        the Deploying Agents section, the Responding to Agent Requests section, \
        and the Message Origin Rules section. \
        If the file doesn't exist, create it with a '# AGENTS.md' header first.

        Preserve all existing content in both files. Only append new sections. \
        Include tado-list, tado-read, tado-send, tado-deploy usage, target resolution rules, and examples.

        Critical rules to include:
        - Agents must always identify themselves and tell the recipient how to respond back.
        - When an agent receives a request from another agent, it MUST deliver the requested \
        information back via tado-send. This is mandatory, not optional. The requesting agent \
        is waiting. Do not just print the answer locally \u{2014} send it back.

        Include a full '## Deploying Agents' section with this exact documentation:

        tado-deploy is a Tado IPC command (NOT a built-in subagent tool) that creates a new \
        terminal tile on the Tado canvas. It deploys a completely separate agent session.

        Syntax:
        tado-deploy "<prompt>" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]

        Flags:
        --agent <name>    Agent definition from .claude/agents/<name>.md or .codex/agents/<name>.md
        --team <name>     Assign the deployed agent to a team
        --project <name>  Assign to a project
        --engine          Use claude or codex (default: inherited from caller)
        --cwd <path>      Working directory (default: inherited from caller)

        Defaults are inherited from the calling session's environment variables (TADO_TEAM_NAME, \
        TADO_PROJECT_NAME, TADO_ENGINE, TADO_PROJECT_ROOT). You only need --agent and the prompt.

        Examples:
        tado-deploy "implement the auth module" --agent backend
        tado-deploy "write unit tests for the API" --agent backend --team core
        tado-deploy "design the landing page" --agent frontend

        After deploying, STOP immediately. Do not wait, do not run tado-list, do not read the \
        new agent's output. Include in the deployed agent's prompt instructions to deliver \
        results back to you via tado-send when done. The deployed agent will tado-send its \
        results to your grid position, which will wake you. Example: \
        tado-deploy "implement auth module and deliver results via tado-send <my-grid> when done" --agent backend
        """
    }

    /// Generate the prompt for a bootstrap agent that injects team context into a project's docs.
    static func bootstrapTeamPrompt(
        targetPath: String,
        projectName: String,
        teams: [(name: String, agents: [String])]
    ) -> String {
        var teamDescription = ""
        for team in teams {
            let agents = team.agents.isEmpty ? "(no agents)" : team.agents.joined(separator: ", ")
            teamDescription += "- Team \"\(team.name)\": agents [\(agents)]\n"
        }

        return """
        Add a '## Team Structure' section to the CLAUDE.md and AGENTS.md files in \
        this project directory (\(targetPath)).

        This project ("\(projectName)") has the following teams and agents:
        \(teamDescription)
        For each file (CLAUDE.md and AGENTS.md):
        1. If the file already has a '## Team Structure' section, replace it with the \
        updated information below. If it doesn't exist, append it.
        2. If the file doesn't exist at all, create it with a '# CLAUDE.md' or \
        '# AGENTS.md' header first.

        The Team Structure section must include:
        - A list of every team with the agents that belong to it
        - For each agent, explain that it is a specialized role in the team and that \
        the agent definition file lives at .claude/agents/<agent-id>.md or .codex/agents/<agent-id>.md
        - A clear instruction that when an agent is working as part of a team, it should:
          a) Know who its teammates are and what they do (read their agent definition files \
          at .claude/agents/<name>.md to understand each teammate's role)
          b) Use tado-list to find teammates that are currently running
          c) When contacting a teammate, identify yourself by role and team, explain what \
          you need, and tell them how to respond back via tado-send
          d) When a teammate asks you for something, you MUST deliver the requested \
          information back to them via tado-send. This is mandatory. The requesting \
          agent is waiting for your response. Do not just work on it silently \u{2014} \
          send the actual result back.
          e) Use tado-deploy to bring a teammate online when you need specialized help. \
          tado-deploy is a Tado IPC command (NOT your built-in subagent tool) that creates \
          a new terminal tile on the Tado canvas. Syntax: \
          tado-deploy "<prompt>" --agent <name> [--team <name>] [--project <name>] \
          [--engine claude|codex] [--cwd <path>]. Defaults (team, project, engine, cwd) \
          are inherited from your session. You typically only need --agent and the prompt.
        - An example communication workflow: "I'm the 'frontend' agent on team 'core' in \
        the \(projectName) project. I need the API types you generated. Reply with: \
        tado-send 1,1 '<types>'" \u{2014} the recipient MUST respond with the actual types \
        via tado-send.
        - An example deploy workflow: the frontend agent at [1,1] needs database schema work, so it runs: \
        tado-deploy "design the database schema for user auth. When done, deliver results via tado-send 1,1" --agent backend \
        A new agent tile appears on the Tado canvas and begins working immediately. \
        STOP after deploying. The deployed agent will deliver results back via tado-send, which wakes you.

        Preserve all existing content in both files. Only add or replace the Team Structure section.
        """
    }
}
