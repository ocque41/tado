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

        static let defaults = ClaudeDisplayEnv(noFlicker: false, mouseEnabled: true, scrollSpeed: 3)
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
    ///
    /// Rewired in Phase dispatch-architect: delegates skill + agent authoring to the dedicated
    /// `/tado-dispatch-skill-creator` and `/tado-dispatch-agent-creator` skills at
    /// `~/.claude/skills/`. This keeps the architect's own context lean across 8-12 phase plans —
    /// previously it inline-invoked the upstream /skill-creator (479 lines) per phase, which
    /// bloated context and caused later phases to degrade after auto-compact.
    static func dispatchArchitectPrompt(projectName: String, projectRoot: String) -> String {
        """
        You are the Dispatch Architect for the "\(projectName)" project at \(projectRoot).

        The user has a super-project request. Your ONLY job right now is to plan it — you will \
        NOT execute the work. A separate chain of specialized phase agents, chosen and \
        orchestrated by you, will do the execution after the user clicks Start.

        ═══════════════════════════════════════════════════════════
        STEP 0 — VERIFY YOUR TOOLING (fail fast)
        ═══════════════════════════════════════════════════════════
        Confirm the two dispatch skills you depend on are installed:
          - ~/.claude/skills/tado-dispatch-skill-creator/SKILL.md
          - ~/.claude/skills/tado-dispatch-agent-creator/SKILL.md

        If either is missing, STOP immediately. Print:
          "tado dispatch: required skill missing at <path>. Reinstall Tado's ~/.claude/skills/."
        Do not fall back to the upstream /skill-creator — its eval-loop flow bloats context and \
        corrupts the later phases of long plans.

        ═══════════════════════════════════════════════════════════
        STEP 1 — READ THE BRIEF + RESEARCH THE PROJECT
        ═══════════════════════════════════════════════════════════
        Read \(projectRoot)/.tado/dispatch/dispatch.md in full — every sentence is a requirement.
        Then understand the project by reading:
          - \(projectRoot)/CLAUDE.md and \(projectRoot)/AGENTS.md (if present)
          - The source tree (package manifests, main entry points, module boundaries)
          - Any existing .claude/agents/ and .claude/skills/
          - Tests, docs, config — anything that reveals architecture + conventions

        ═══════════════════════════════════════════════════════════
        STEP 2 — DESIGN THE PHASES
        ═══════════════════════════════════════════════════════════
        Break the super-project into ordered, self-contained phases. Each phase has:
          - A single clear responsibility
          - Explicit inputs (files / artefacts from prior phases)
          - Explicit outputs (files / artefacts this phase creates)
          - No dependency on phases that come later (ordering is strict)

        Assign a sequential order (1, 2, 3, …) and pick the engine (claude or codex) per phase. \
        Default to this session's engine unless a phase clearly needs the other.

        ═══════════════════════════════════════════════════════════
        STEP 3 — CREATE A SKILL PER PHASE (/tado-dispatch-skill-creator)
        ═══════════════════════════════════════════════════════════
        For each phase, invoke /tado-dispatch-skill-creator with these inputs verbatim:
          - phase-order, phase-id (kebab-case), phase-title
          - phase-deliverables (bullet list)
          - project-name: \(projectName)
          - project-root: \(projectRoot)

        The skill writes one SKILL.md and returns its path + skill name. Use the returned skill \
        name in Step 5's phase JSON. DO NOT use the upstream /skill-creator.

        ═══════════════════════════════════════════════════════════
        STEP 4 — CREATE AN AGENT PER PHASE (/tado-dispatch-agent-creator)
        ═══════════════════════════════════════════════════════════
        For each phase that needs an agent (most will), invoke /tado-dispatch-agent-creator with:
          - agent-name (kebab-case), phase-order, phase-title
          - phase-responsibilities (prose)
          - engine (claude or codex from Step 2)
          - project-name: \(projectName)
          - project-root: \(projectRoot)

        The skill writes one .claude/agents/ file and returns its path + agent name. Use the \
        returned agent name in Step 5's phase JSON. DO NOT hand-author agent files.

        ═══════════════════════════════════════════════════════════
        STEP 5 — WRITE THE JSON PLAN FILES
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
          "skill": "<name returned by /tado-dispatch-skill-creator>",
          "agent": "<name returned by /tado-dispatch-agent-creator, or null>",
          "engine": "claude" | "codex",
          "prompt": "<FULL self-contained prompt — see Step 6>",
          "nextPhaseFile": ".tado/dispatch/phases/<next-order>-<next-id>.json",
          "status": "pending"
        }

        For the LAST phase, set "nextPhaseFile": null.

        ═══════════════════════════════════════════════════════════
        STEP 6 — AUTHOR THE PHASE PROMPTS (most important step)
        ═══════════════════════════════════════════════════════════
        The "prompt" field for each phase must be a COMPLETE, SELF-CONTAINED prompt that starts \
        with a visible comment line exactly like this:

        # Prompt for /<skill-name> — deploy via: tado-deploy "<this prompt>" --agent <agent> --engine <engine>

        …then continues with these sections in order:

        1. "Read .tado/dispatch/phases/<this-phase-file>.json first. That JSON is your \
        authoritative brief for this phase."
        2. "Load your specialized skill: /<skill-name>"
        3. The concrete work instructions — inputs, steps, deliverables, acceptance criteria. \
        Be exhaustive so the phase agent has zero ambiguity.
        4. "When done, update your phase JSON 'status' field to 'completed'."
        5. "Write a retrospective at \(projectRoot)/.tado/dispatch/retros/<order>-<id>.md using \
        EXACTLY this template (substitute your values):

           # Phase <order>: <title>

           ## Summary
           <1–2 sentences on what this phase actually produced.>

           ## Friction
           <1 line on anything awkward — unclear inputs, redundant \
           steps, ambiguous handoff, missing validation. Write \
           'none' if nothing stood out.>

           The retrospective feeds the final wrap-up message the \
           architect uses to optimize the skills/agents creator \
           skills. Keep it terse — no novels."
        6. Handoff block — verbatim template depending on nextPhaseFile:

           If nextPhaseFile is NOT null:
             "Read nextPhaseFile JSON (path above) and copy its 'prompt' field. Then run:
              tado-deploy '<paste next phase prompt here>' --agent <next-agent> --engine <next-engine> --project \(projectName) --cwd \(projectRoot)
              After the tado-deploy command prints the deploy request ID, STOP. Do not wait, \
              do not tado-list, do not tado-read. The next phase will run on its own."

           If nextPhaseFile IS null (you are the last phase), the handoff is the full \
           RETROSPECTIVE MESSAGE — do not just send 'fully executed.' Instead:
             1. Read every file in \(projectRoot)/.tado/dispatch/retros/ in order-sorted \
                filename order (1-*, 2-*, …, N-*).
             2. Concatenate them into the message body below, wrapped by the heading and \
                directive lines shown, substituting <projectName> = \(projectName) and \
                <N> = totalPhases:

             ─────────────── BEGIN RETROSPECTIVE MESSAGE ───────────────
             Dispatch retrospective — <projectName>

             Plan: <N> phases executed.

             <paste retros/1-*.md contents here verbatim>

             <paste retros/2-*.md contents here verbatim>

             … (continue through phase <N>) …

             ═══════════════════════════════════════════════════════════
             ARCHITECT DIRECTIVE — OPTIMIZE/HARDEN/POLISH
             ═══════════════════════════════════════════════════════════

             Based on the retrospective above, walk the phases in order. For each phase:
               1. Analyze the summary — what did this phase actually produce?
               2. State 3–5 key points — what stood out about how it went?
               3. Analyze those key points — what does this tell us about the tooling \
                  (the skills/agents creator skills)?

             Then OPTIMIZE/HARDEN/POLISH these two skills:
               • ~/.claude/skills/tado-dispatch-skill-creator/SKILL.md
               • ~/.claude/skills/tado-dispatch-agent-creator/SKILL.md

             Targeted edits only — no rewrites from scratch. Each skill stays ≤ 200 lines. \
             After edits, print a unified diff summary and STOP.

             Dispatch plan for <projectName> fully executed.
             ──────────────── END RETROSPECTIVE MESSAGE ────────────────

             3. Run:
                  tado-send <architect-grid> '<entire message body>'
                where <architect-grid> is the hard-coded grid position below.
             4. After the tado-send prints its request ID, STOP. Do not wait, do not tado-list.

        At the end of every LAST-phase prompt, include a hard-coded line listing the architect's \
        own grid position. You can learn your own grid by running `tado-list` and finding the \
        row whose session ID matches $TADO_SESSION_ID; use that grid position literally.

        ═══════════════════════════════════════════════════════════
        STEP 7 — INJECT "DISPATCH SYSTEM" AWARENESS
        ═══════════════════════════════════════════════════════════
        Append a '## Dispatch System' section to BOTH \(projectRoot)/CLAUDE.md and \
        \(projectRoot)/AGENTS.md (create the files with a '# CLAUDE.md' / '# AGENTS.md' header \
        first if missing; REPLACE the section if it already exists). Document:
          - Filesystem layout at \(projectRoot)/.tado/dispatch/ :
              dispatch.md  — user's brief
              plan.json    — plan summary
              phases/<order>-<id>.json — one per phase (schema below)
              retros/<order>-<id>.md  — per-phase retrospective (Summary + Friction)
          - The phase JSON schema (show all fields)
          - Rule: every agent checks $TADO_AGENT_NAME against phase "agent" fields on wake; on \
            match, read that phase JSON before acting
          - Skill-per-phase: skills at .claude/skills/<skill-name>/, load via /<skill-name>
          - Chain: each phase prompt contains its own tado-deploy handoff; do not deviate
          - Retrospective: every phase writes retros/<order>-<id>.md; the LAST phase \
            concatenates them into a single tado-send back to the architect carrying the \
            OPTIMIZE/HARDEN/POLISH directive
          - Pointer: active plan is at .tado/dispatch/plan.json

        ═══════════════════════════════════════════════════════════
        STEP 8 — OPTIONAL MEMORY POINTER
        ═══════════════════════════════════════════════════════════
        If \(projectRoot)/.claude/MEMORY.md exists, add/update a one-line entry pointing at \
        .tado/dispatch/plan.json. Do not create MEMORY.md if absent.

        ═══════════════════════════════════════════════════════════
        STEP 9 — FINISH AND STOP
        ═══════════════════════════════════════════════════════════
        Print a concise human-readable summary:
          - Total phases
          - Each phase's order, title, skill, agent, engine
          - Absolute path to plan.json
          - The exact command the user's Start button will run (for transparency)

        Then STOP. Do NOT launch phase 1. Do NOT tado-deploy. Do NOT tado-send. The user will \
        review your plan on the canvas, then click Start to kick off phase 1.

        ═══════════════════════════════════════════════════════════
        STEP 10 — WHEN YOU WAKE (retrospective + self-improvement)
        ═══════════════════════════════════════════════════════════
        Hours from now, when the last phase finishes, it will tado-send you a "Dispatch \
        retrospective" message (the template is fully specified in STEP 6). The message \
        contains per-phase summaries + friction notes, plus an ARCHITECT DIRECTIVE block \
        that asks you to OPTIMIZE/HARDEN/POLISH the two skills that authored this plan.

        When that message appears in your terminal:

          1. Read the full message. The per-phase blocks tell you what actually happened.
          2. Walk the phases in order. For EACH phase:
               a. Analyze its summary — what did it actually produce?
               b. State 3–5 key points — what stood out about how it went?
               c. Analyze those points — what does this tell us about the authoring \
                  tooling (did the skill-creator template steer the phase right? did \
                  the agent definition catch / miss something? any friction that points \
                  at a gap in the SKILL.md / agent template itself?).
          3. Apply targeted edits to:
               - ~/.claude/skills/tado-dispatch-skill-creator/SKILL.md
               - ~/.claude/skills/tado-dispatch-agent-creator/SKILL.md
             No rewrites from scratch. Keep each under 200 lines. Prefer: adding a \
             missing enforcement rule, tightening an ambiguous instruction, adding an \
             example to the references/, trimming dead weight. If nothing in the \
             retrospective suggests a change, say so and skip the edit — do not invent \
             problems to justify a diff.
          4. Print a unified-diff-style summary of the edits (or "no changes needed").
          5. STOP. Do not re-run the plan, do not schedule anything, do not tado-deploy.

        This self-improvement loop is the whole point of the retrospective: every \
        dispatched plan becomes one more data point that sharpens the tooling for the \
        next plan.
        """
    }
}
