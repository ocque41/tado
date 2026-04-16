import Foundation

enum ProcessSpawner {
    static func command(for todoText: String, engine: TerminalEngine, modeFlags: [String] = [], effortFlags: [String] = [], modelFlags: [String] = [], agentName: String? = nil) -> (executable: String, args: [String]) {
        let escaped = shellEscape(todoText)
        let cli = engine.rawValue
        var flags = modeFlags + effortFlags + modelFlags
        if let agentName, engine == .claude {
            flags.insert(contentsOf: ["--agent", agentName], at: 0)
        }
        let allFlags = flags.joined(separator: " ")
        let cmd = allFlags.isEmpty ? "\(cli) \(escaped)" : "\(cli) \(allFlags) \(escaped)"
        return ("/bin/zsh", ["-l", "-c", cmd])
    }

    /// Tado-embed shim flags for the Codex CLI. Always includes
    /// `-c shell_environment_policy.inherit=all` so tado-send and friends
    /// inherit TADO_* env vars. When `allowAlternateScreen` is false
    /// (the default for embedded SwiftTerm tiles), also passes `--no-alt-screen`
    /// because alt-screen breaks Codex's command execution inside Tado tiles.
    /// See `tui.alternate_screen` in Codex config for the equivalent global setting.
    static func codexEmbedShim(allowAlternateScreen: Bool) -> [String] {
        var flags = ["-c", "shell_environment_policy.inherit=all"]
        if !allowAlternateScreen {
            flags.insert("--no-alt-screen", at: 0)
        }
        return flags
    }

    static func shellEscape(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Display-mode env knobs forwarded to the Claude Code CLI. Mirrors AppSettings so
    /// the spawn site (TerminalNSViewRepresentable) can pass them through without
    /// importing SwiftData. See https://code.claude.com/docs/en/fullscreen
    struct ClaudeDisplayEnv {
        var noFlicker: Bool
        var mouseEnabled: Bool
        var scrollSpeed: Int

        static let defaults = ClaudeDisplayEnv(noFlicker: true, mouseEnabled: true, scrollSpeed: 3)
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
        teamAgents: [String]? = nil,
        claudeDisplay: ClaudeDisplayEnv = .defaults
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

        // Claude Code fullscreen / "all useful UI" knobs (no-op for codex sessions).
        if engine == .claude {
            if claudeDisplay.noFlicker {
                env["CLAUDE_CODE_NO_FLICKER"] = "1"
                if !claudeDisplay.mouseEnabled {
                    env["CLAUDE_CODE_DISABLE_MOUSE"] = "1"
                }
                let clamped = max(1, min(20, claudeDisplay.scrollSpeed))
                env["CLAUDE_CODE_SCROLL_SPEED"] = String(clamped)
            }
        }

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

    // MARK: - Dispatch Architect

    /// Generate the prompt for the dispatch architect. This agent reads the user's markdown brief
    /// at .tado/dispatch/dispatch.md, designs a multi-phase plan with per-phase skills, writes the
    /// JSON plan files, and injects "Dispatch System" awareness into the project's CLAUDE.md and
    /// AGENTS.md so every spawned phase agent wakes with full context before typing.
    static func dispatchArchitectPrompt(projectName: String, projectRoot: String) -> String {
        """
        You are the Dispatch Architect for the "\(projectName)" project at \(projectRoot).

        The user has a super-project request. Your ONLY job right now is to plan it — you will \
        NOT execute the work. A separate chain of specialized phase agents, chosen and \
        orchestrated by you, will do the execution after the user clicks Start.

        ═══════════════════════════════════════════════════════════
        STEP 1 — READ THE BRIEF (take it seriously)
        ═══════════════════════════════════════════════════════════
        Read \(projectRoot)/.tado/dispatch/dispatch.md in full. This is the user's super-project \
        request. Treat every sentence as a requirement.

        ═══════════════════════════════════════════════════════════
        STEP 2 — DEEP RESEARCH THE PROJECT
        ═══════════════════════════════════════════════════════════
        Before planning, understand the project. Read:
          - \(projectRoot)/CLAUDE.md (if present)
          - \(projectRoot)/AGENTS.md (if present)
          - The source tree (package manifests, main entry points, module boundaries)
          - Any existing .claude/agents/ and .claude/skills/ definitions
          - Tests, docs, config — anything that reveals architecture and conventions

        ═══════════════════════════════════════════════════════════
        STEP 3 — DESIGN A SKILL PER PHASE (use /skill-creator)
        ═══════════════════════════════════════════════════════════
        For every phase you are about to design, invoke the /skill-creator slash command (or the \
        best equivalent skill-authoring flow available in this harness) to produce a dedicated \
        skill. Each skill must live at \(projectRoot)/.claude/skills/<skill-name>/SKILL.md.

        Each SKILL.md description MUST begin with: \
        "Dispatch-plan phase skill for the \(projectName) project — ..." so that later when a \
        phase agent types /<skill-name>, Claude Code loads the right specialized context.

        ═══════════════════════════════════════════════════════════
        STEP 4 — DESIGN THE MEGA IMPLEMENTATION PLAN
        ═══════════════════════════════════════════════════════════
        Break the super-project into ordered, self-contained phases. Each phase should have:
          - A clear single responsibility
          - Explicit inputs (files / artefacts from prior phases)
          - Explicit outputs (files / artefacts this phase creates)
          - No blocking dependencies on phases that come later (ordering is strict)

        ═══════════════════════════════════════════════════════════
        STEP 5 — ASSIGN ORDER, SKILL, AND AGENT PER PHASE
        ═══════════════════════════════════════════════════════════
        For each phase:
          - Assign a sequential order number (1, 2, 3, …)
          - Assign the skill you authored in Step 3
          - Assign (or create) an agent definition at .claude/agents/<agent-name>.md. The agent \
            definition's description must say it is a phase agent for the dispatch plan.
          - Pick the engine (claude or codex) that best suits the phase; default to this \
            session's engine unless a phase clearly needs the other.

        ═══════════════════════════════════════════════════════════
        STEP 6 — WRITE THE JSON PLAN FILES
        ═══════════════════════════════════════════════════════════
        Create these files under \(projectRoot)/.tado/dispatch/ :

        plan.json:
        {
          "status": "ready",
          "totalPhases": <N>,
          "createdAt": "<ISO8601 timestamp>"
        }

        One phase file per phase at phases/<order>-<kebab-phase-id>.json :
        {
          "id": "<kebab-phase-id>",
          "order": <1..N>,
          "title": "<human-readable phase title>",
          "skill": "<skill-name from Step 3>",
          "agent": "<agent-name from Step 5, or null>",
          "engine": "claude" | "codex",
          "prompt": "<FULL self-contained prompt — see Step 7>",
          "nextPhaseFile": ".tado/dispatch/phases/<next-order>-<next-id>.json",
          "status": "pending"
        }

        For the LAST phase, set "nextPhaseFile": null.

        ═══════════════════════════════════════════════════════════
        STEP 7 — AUTHOR THE PHASE PROMPTS (most important step)
        ═══════════════════════════════════════════════════════════
        The "prompt" field for each phase must be a COMPLETE, SELF-CONTAINED prompt that starts \
        with a visible comment line exactly like this:

        # Prompt for /<skill-name> — deploy via: tado-deploy "<this prompt>" --agent <agent> --engine <engine>

        …then continues with these sections in order:

        1. "Read .tado/dispatch/phases/<this-phase-file>.json first. That JSON is your \
        authoritative brief for this phase."
        2. "Load your specialized skill: /<skill-name>"
        3. The concrete work instructions for this phase — inputs, steps, deliverables, \
        acceptance criteria. Be exhaustive so the phase agent has zero ambiguity.
        4. "When done, update your phase JSON 'status' field to 'completed'."
        5. Handoff block — verbatim template depending on nextPhaseFile:

           If nextPhaseFile is NOT null:
             "Read nextPhaseFile JSON (path above) and copy its 'prompt' field. Then run:
              tado-deploy '<paste next phase prompt here>' --agent <next-agent> --engine <next-engine> --project \(projectName) --cwd \(projectRoot)
              After the tado-deploy command prints the deploy request ID, STOP. Do not wait, \
              do not tado-list, do not tado-read. The next phase will run on its own."

           If nextPhaseFile IS null (you are the last phase):
             "All dispatch phases are complete. Run:
              tado-send <architect-grid> 'Dispatch plan for \(projectName) fully executed.'
              where <architect-grid> is the grid position printed below."

        At the end of every LAST-phase prompt, include a hard-coded line listing the architect's \
        own grid position. You can learn your own grid by running `tado-list` and finding the \
        row whose session ID matches $TADO_SESSION_ID; use that grid position literally.

        ═══════════════════════════════════════════════════════════
        STEP 8 — INJECT "DISPATCH SYSTEM" AWARENESS
        ═══════════════════════════════════════════════════════════
        Append a new '## Dispatch System' section to BOTH \(projectRoot)/CLAUDE.md and \
        \(projectRoot)/AGENTS.md (create the files with a '# CLAUDE.md' / '# AGENTS.md' header \
        first if they do not exist). If the section already exists, REPLACE it.

        The section must document:
          - The filesystem layout at \(projectRoot)/.tado/dispatch/ (dispatch.md, plan.json, \
            phases/<order>-<id>.json)
          - The phase JSON schema (show all fields)
          - The rule: every agent spawned inside this project should check whether its task \
            matches a phase file on wake. If $TADO_AGENT_NAME matches a phase's "agent" field, \
            the agent should read that phase JSON before acting.
          - The skill-per-phase convention — skills live at .claude/skills/<skill-name>/ and \
            must be loaded via /<skill-name> at the start of each phase.
          - The chain convention — each phase prompt contains its own tado-deploy handoff; \
            agents must not deviate from that prescribed next step.
          - A one-line reminder that the active plan is at .tado/dispatch/plan.json.

        This section is load-before-the-user-types context: every future Claude Code / Codex \
        session in this project will see it in its auto-loaded CLAUDE.md / AGENTS.md.

        ═══════════════════════════════════════════════════════════
        STEP 9 — OPTIONAL MEMORY POINTER
        ═══════════════════════════════════════════════════════════
        If \(projectRoot)/.claude/MEMORY.md exists, add or update a single one-line entry \
        pointing at .tado/dispatch/plan.json as the active dispatch plan. Do not create \
        MEMORY.md if it does not exist.

        ═══════════════════════════════════════════════════════════
        STEP 10 — FINISH AND STOP
        ═══════════════════════════════════════════════════════════
        Print a concise human-readable summary:
          - Total phases
          - Each phase's order, title, skill, agent, engine
          - Absolute path to plan.json
          - The exact command the user's Start button will run (for transparency)

        Then STOP. Do NOT launch phase 1. Do NOT tado-deploy. Do NOT tado-send. The user will \
        review your plan on the canvas, then click Start in the Projects view to kick off \
        phase 1.
        """
    }
}
