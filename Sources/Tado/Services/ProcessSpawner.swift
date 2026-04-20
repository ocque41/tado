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
            // Never let an auto-update prompt halt a long-running tile. The
            // update nag pauses the CLI on a major bump and is a guaranteed
            // stall for ralph-loop style sessions. Users who want to update
            // can do so manually via `claude doctor`.
            env["CLAUDE_CODE_AUTO_UPDATE_DISABLED"] = "1"
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
    static func dispatchArchitectPrompt(projectName: String, projectRoot: String, runID: UUID) -> String {
        let runShortID = String(runID.uuidString.prefix(8)).lowercased()
        let runDir = "\(projectRoot)/.tado/dispatch/runs/\(runID.uuidString)"
        return """
        You are the Dispatch Architect for the "\(projectName)" project at \(projectRoot).

        The user has a super-project request. Your ONLY job right now is to plan it — you will \
        NOT execute the work. A separate chain of specialized phase agents, chosen and \
        orchestrated by you, will do the execution after the user clicks Start.

        ═══════════════════════════════════════════════════════════
        RUN SCOPE — multiple concurrent dispatches per project
        ═══════════════════════════════════════════════════════════
        This dispatch has a unique run id. ALL files you author — the plan JSON, \
        phase JSONs, per-phase skills, and per-phase agents — MUST include the \
        run short-id in their names or paths so two concurrent dispatches on the \
        same project don't clobber each other.

          run-id:           \(runID.uuidString)
          run-short-id:     \(runShortID)
          run-dir:          \(runDir)

        The run-short-id is the first 8 hex chars of run-id. Use it wherever the \
        templates below reference `<run-short-id>`.

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
        Read \(runDir)/dispatch.md in full — every sentence is a requirement.
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

        Phase-count sanity: target 4–10 phases. Fewer than 4 usually means a phase is hiding \
        sub-structure (split it). More than 10 makes the chain brittle — every extra hand-off is \
        another place the context can decay. If your first cut produces 12+, look for phases that \
        can fold together without breaking the "single clear responsibility" rule.

        Per-phase model + effort routing (load-bearing — do not skip):
        For each phase, pick a `model` and `effort` pairing that will end up in the agent file's
        frontmatter (see STEP 4). Defaults, in order of likelihood:
          • `haiku` + `high`  — templated code, mechanical transforms, docs synthesis, glue, \
            most scaffold phases. Use this aggressively; Haiku is the volume engine.
          • `haiku` + `max`   — Haiku on a denser phase where quality matters (tight DSL, \
            schema migration with edge cases, adapter correctness).
          • `opus`  + `max`   — reserved for the one or two phases that make genuinely non-\
            trivial design calls: overall architecture, cross-phase contract design, semantic \
            rule systems. Never pick Opus just because "this feels important"; pick it only \
            when the phase has branching design decisions a templated runner would botch.
          • `sonnet` + `high` — fallback for mid-complexity reasoning when Haiku is too light \
            and Opus is overkill. Prefer Haiku/max before reaching for Sonnet.
        Rule of thumb: if more than one phase in a plan lands on `opus`, re-examine — you are \
        probably misallocating. A healthy 6-phase plan is typically 5× Haiku + 1× Opus, or \
        6× Haiku. Record the `model`/`effort` choice alongside each phase in your notes; you \
        will pass them verbatim to the agent-creator skill in STEP 4.

        ═══════════════════════════════════════════════════════════
        STEP 3 — CREATE A SKILL PER PHASE (/tado-dispatch-skill-creator)
        ═══════════════════════════════════════════════════════════
        For each phase, invoke /tado-dispatch-skill-creator with these inputs verbatim:
          - phase-order, phase-id (kebab-case), phase-title
          - phase-deliverables (bullet list)
          - project-name: \(projectName)
          - project-root: \(projectRoot)
          - run-short-id: \(runShortID)

        The skill writes one SKILL.md and returns its path + skill name. The
        returned skill name MUST embed the run-short-id like
        `dispatch-<projectslug>-\(runShortID)-<phase-id>` so concurrent
        dispatches don't collide. Use the returned skill name in Step 5's phase
        JSON. DO NOT use the upstream /skill-creator.

        ═══════════════════════════════════════════════════════════
        STEP 4 — CREATE AN AGENT PER PHASE (/tado-dispatch-agent-creator)
        ═══════════════════════════════════════════════════════════
        For each phase that needs an agent (most will), invoke /tado-dispatch-agent-creator with:
          - agent-name (kebab-case — MUST include the run-short-id as a suffix,
            e.g. `backend-\(runShortID)`, so the file name never collides with a
            concurrently-running dispatch's agent on the same project)
          - phase-order, phase-title
          - phase-responsibilities (prose)
          - engine (claude or codex from Step 2)
          - model (haiku | sonnet | opus — from Step 2's per-phase routing)
          - effort (low | medium | high | max — from Step 2's per-phase routing)
          - project-name: \(projectName)
          - project-root: \(projectRoot)
          - run-short-id: \(runShortID)

        The `model` and `effort` inputs land as frontmatter fields in the emitted agent file. \
        Tado's dispatch pipeline (AgentDiscoveryService.phaseOverride) reads them at phase-spawn \
        time and passes `--model <id> --effort <level>` to the CLI. Omitting either sends the \
        phase to whatever the user picked in Settings — usually not what you want for Haiku-heavy \
        volume work.

        The skill writes one .claude/agents/ file and returns its path + agent name. Use the \
        returned agent name in Step 5's phase JSON. DO NOT hand-author agent files.

        ═══════════════════════════════════════════════════════════
        STEP 5 — WRITE THE JSON PLAN FILES
        ═══════════════════════════════════════════════════════════
        Create these files under \(runDir)/ :

        plan.json:
        {
          "status": "ready",
          "totalPhases": <N>,
          "createdAt": "<ISO8601 timestamp>",
          "runID": "\(runID.uuidString)",
          "runShortID": "\(runShortID)"
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
          "nextPhaseFile": ".tado/dispatch/runs/\(runID.uuidString)/phases/<next-order>-<next-id>.json",
          "status": "pending"
        }

        For the LAST phase, set "nextPhaseFile": null.

        ═══════════════════════════════════════════════════════════
        STEP 5.5 — SELF-CHECK PLAN COVERAGE (coverage audit)
        ═══════════════════════════════════════════════════════════
        Before moving to STEP 6, audit what you just wrote. This catches the \
        single most expensive failure mode: phase prompts that silently drift \
        from what dispatch.md actually requires, which compounds across the \
        chain and is invisible until smoke-test time.

        1. Re-read \(runDir)/dispatch.md and enumerate its \
           acceptance criteria as a numbered list — every testable claim \
           (commands that must work, files that must exist, formats that must \
           be supported, behaviors that must hold). Aim for 6–20 items; \
           granular enough that each maps to at most one or two phases.

        2. Re-read every phases/<order>-<id>.json you just wrote. For each \
           acceptance criterion, identify which phase(s) deliver it. Mark \
           coverage:
             - COVERED — a phase's deliverables clearly produce it.
             - PARTIAL — a phase mentions it but the deliverable is vague.
             - MISSING — no phase claims it.

        3. Stack-drift check: if dispatch.md specifies a runtime (Node 20+, \
           Python 3.12, Bun, Deno, Swift, Rust…), a test harness (node --test, \
           pytest, vitest, swift test…), a module format (ESM vs CJS), or a \
           package manager (npm / pnpm / uv / cargo), every phase prompt MUST \
           name that choice verbatim. A phase mentioning a different one is \
           drift — fix it now, before phase agents start spawning.

        4. If any item is PARTIAL or MISSING, or any drift was detected, \
           REWRITE the offending phase JSON's "prompt" field (and its \
           deliverables list) so the gap is closed. Write the fix directly \
           over the existing file; do not append a note. If a genuine gap \
           spans no existing phase, prefer merging the work into the \
           nearest-matching phase over adding a new phase — extra phases \
           decay the chain. If you MUST add a phase, update plan.json's \
           "totalPhases" and every "nextPhaseFile" pointer.

        5. After all rewrites, print a one-block audit summary:
             coverage: <covered>/<total> criteria
             drift fixes: <count>
             phases touched: <list of phase ids>
           Then proceed to STEP 6. If coverage is 100% and drift is 0, print \
           "audit clean" and proceed.

        Do not skip this. The cost is one extra pass over files you already \
        have open; the cost of a phase agent acting on a drifted prompt \
        compounds across every subsequent phase.

        ═══════════════════════════════════════════════════════════
        STEP 6 — AUTHOR THE PHASE PROMPTS (most important step)
        ═══════════════════════════════════════════════════════════
        The "prompt" field for each phase must be a COMPLETE, SELF-CONTAINED prompt that starts \
        with a visible comment line exactly like this:

        # Prompt for /<skill-name> — deploy via: tado-deploy "<this prompt>" --agent <agent> --engine <engine>

        …then continues with these sections in order:

        1. "Read .tado/dispatch/runs/\(runID.uuidString)/phases/<this-phase-file>.json first. That JSON is your \
        authoritative brief for this phase."
        2. "Load your specialized skill: /<skill-name>"
        3. The concrete work instructions — inputs, steps, deliverables, acceptance criteria. \
        Be exhaustive so the phase agent has zero ambiguity.
        4. "When done, update your phase JSON 'status' field to 'completed'."
        5. "Write a retrospective at \(runDir)/retros/<order>-<id>.md using \
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
             1. Read every file in \(runDir)/retros/ in order-sorted \
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
          - Filesystem layout at \(runDir)/ :
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
          - Pointer: active plan is at .tado/dispatch/runs/\(runID.uuidString)/plan.json

        ═══════════════════════════════════════════════════════════
        STEP 8 — OPTIONAL MEMORY POINTER
        ═══════════════════════════════════════════════════════════
        If \(projectRoot)/.claude/MEMORY.md exists, add/update a one-line entry pointing at \
        .tado/dispatch/runs/\(runID.uuidString)/plan.json. Do not create MEMORY.md if absent.

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

    // MARK: - Eternal

    /// Permission-mode flags for an Eternal session's Claude Code spawn.
    ///
    /// Belt-and-suspenders, because the user observed a live worker process
    /// with just `--dangerously-skip-permissions` still hitting a permission
    /// prompt (screenshot 2026-04-18). Per Claude Code docs the two flag
    /// forms are "equivalent", but in practice CLI v2.1.101 behaves better
    /// when BOTH are set. We also pin `--setting-sources=user,project,local`
    /// so the project's `.claude/settings.json` allowlist we just wrote is
    /// actually loaded — without this, some CLI builds fall back to user-
    /// only sources and the project allowlist we rely on is invisible.
    ///
    /// `skipPermissions = true`  → full bypass: mode + skip flag + settings.
    /// `skipPermissions = false` → mode only (Claude Code still refuses
    ///                              obviously dangerous commands but never
    ///                              opens a prompt in bypass mode).
    /// Shell command that launches the Tado Eternal external-loop wrapper.
    /// Used in place of `command(for:engine:…)` when
    /// `TerminalSession.isEternalWorker == true`. The wrapper is installed
    /// by `EternalService.installHooks` at
    /// `<projectRoot>/.tado/eternal/hooks/eternal-loop.sh`. It reads
    /// TADO_* env vars (see `eternalWorkerEnv(...)`) to build each
    /// `claude -p` invocation and re-spawn until ETERNAL-DONE, the user
    /// presses Stop, or the Max-Iter cap hits.
    static func eternalWorkerCommand(projectRoot: String) -> (executable: String, args: [String]) {
        let script = "\(projectRoot)/.tado/eternal/hooks/eternal-loop.sh"
        // zsh -l so the user's login PATH is loaded (same convention as the
        // normal spawn). The wrapper itself is bash-shebang; we invoke it
        // explicitly via bash so the shebang doesn't need to resolve on $PATH.
        return ("/bin/zsh", ["-l", "-c", "bash \(shellEscape(script))"])
    }

    /// Env-var dictionary consumed by the eternal-loop wrapper. Merged
    /// with `ProcessSpawner.environment(...)` at spawn time so the
    /// wrapper inherits everything else (Tado IPC, PATH, etc.) AND gets
    /// the eternal-specific knobs.
    static func eternalWorkerEnv(
        runID: UUID,
        mode: String,
        doneMarker: String,
        sprintMarker: String = "[SPRINT-DONE]",
        modelID: String?,
        effortLevel: String?,
        skipPermissions: Bool
    ) -> [String: String] {
        var env: [String: String] = [
            // Per-run scope key. Every hook script uses this to resolve
            // paths under `.tado/eternal/runs/<run-id>/`. If it's empty
            // the wrappers short-circuit to no-ops — that's how architect
            // and interventor tiles (which don't set this) stay hook-inert.
            "TADO_ETERNAL_RUN_ID": runID.uuidString,
            "TADO_ETERNAL_MODE": mode,
            "TADO_DONE_MARKER": doneMarker,
            "TADO_SPRINT_MARKER": sprintMarker,
            "TADO_SKIP_PERMISSIONS": skipPermissions ? "1" : "0",
            // Constant now that external is the only loop kind — stop.sh
            // reads this to allow-stop (the wrapper owns continuation).
            "TADO_ETERNAL_LOOP_MODE": "1",
        ]
        if let modelID, !modelID.isEmpty {
            env["TADO_MODEL"] = modelID
        }
        if let effortLevel, !effortLevel.isEmpty {
            env["TADO_EFFORT"] = effortLevel
        }
        return env
    }

    static func eternalPermissionFlags(skipPermissions: Bool) -> [String] {
        var flags = [
            "--permission-mode", "bypassPermissions",
            "--setting-sources", "user,project,local",
        ]
        if skipPermissions {
            flags.append("--dangerously-skip-permissions")
        }
        return flags
    }

    /// Prompt for a Mega-mode Eternal worker. Plain text — callers shell-escape
    /// when spawning. The Stop hook picks up context from `state.json` so this
    /// prompt only has to tell the worker what the session IS, not how it loops.
    static func eternalMegaPrompt(projectName: String, projectRoot: String, marker: String, runID: UUID) -> String {
        let runDir = "\(projectRoot)/.tado/eternal/runs/\(runID.uuidString)"
        return """
        You are running as a Tado Eternal agent (MEGA mode) for project "\(projectName)" at \(projectRoot).

        Your authoritative brief is \(runDir)/crafted.md — the Eternal Architect \
        wrote it for you. Read it before anything else. If it's missing, fall back to \
        \(runDir)/user-brief.md (raw).

        You are in an ETERNAL session. A Stop hook will intercept your normal end-of-turn \
        and restart you automatically. The session exits only when:
          (a) You output this exact completion marker on its own line: \(marker)
          (b) The user presses Stop in Tado (the tile will close).

        Each iteration:
          1. Read \(runDir)/progress.md to recall state (survives compaction).
          2. Do the next unit of work — one chunk, don't stall on a single giant step.
          3. Append ONE short progress line to \(runDir)/progress.md, e.g.
             "2026-04-18 18:03: Refactored AuthMiddleware; tests green."
          4. If (and only if) the task is truly, fully done, output "\(marker)" on its own line.

        Don't ask clarifying questions — decide and proceed.
        Don't summarise at the end of turns — progress.md is the summary.
        If you get stuck on a single-turn problem, write what you tried to progress.md and move \
        on to the next independent unit of work; revisit the stuck one later with fresh context.

        ═══════════════════════════════════════════════════════════
        NON-STOP HYGIENE — avoid the only prompts bypass can't skip
        ═══════════════════════════════════════════════════════════
        Claude Code's `--dangerously-skip-permissions` skips every prompt \
        EXCEPT writes to protected paths under `.claude/` when the parent \
        directory has to be created. To keep the loop truly non-stop:
          • BEFORE any `Write` or `Edit` on a new path, run `Bash(mkdir -p <dir>)`
            first. Always. Especially for `.claude/agents/`, `.claude/skills/`,
            and any new subdirectory tree.
          • Prefer writing generated files OUTSIDE `.claude/` when possible
            (scratch files, trial-project outputs, reports, etc.). The
            `.tado/scratch/` and `\(runDir)/` directories are safe.
          • If you genuinely need to create something under `.claude/`, create
            `.claude/` and its full subpath via mkdir FIRST, then Write.
          • Never use tools that open interactive dialogs or confirmations.
        """
    }

    /// Prompt for a Sprint-mode Eternal worker. Each turn = one APPLY → EVAL → IMPROVE \
    /// cycle ending in `sprintMarker`. Only `marker` terminates the session.
    static func eternalSprintPrompt(
        projectName: String,
        projectRoot: String,
        marker: String,
        sprintMarker: String,
        runID: UUID
    ) -> String {
        let runDir = "\(projectRoot)/.tado/eternal/runs/\(runID.uuidString)"
        return """
        You are running as a Tado Eternal agent (SPRINT mode) for project "\(projectName)" at \(projectRoot).

        Your authoritative brief is \(runDir)/crafted.md — the Eternal Architect \
        wrote it for you. Read it now. It contains these sections:
          TASK              — what to build/optimize each sprint
          EVALUATE          — exactly how to score a sprint (one command + formula)
          IMPROVE           — the ladder of knobs to turn, with plateau rules
          Hard rules        — never-violate constraints
          Sprint end ritual — what to output at the end of each sprint

        You are in a loop of sprints. Each sprint has three phases:

          1. APPLY   — implement the current proposal, or apply the last sprint's chosen improvement.
          2. EVAL    — run the evaluation from the TASK/EVALUATE sections. Append one line to
                       \(runDir)/metrics.jsonl in this exact shape:
                       {"sprint": N, "timestamp": "<iso>", "metric": <number-or-short-string>, "note": "<one-liner>"}
          3. IMPROVE — read the last 5 lines of metrics.jsonl. Decide what to change next, guided by
                       the IMPROVE section. Write your plan as ONE short line in
                       \(runDir)/progress.md.

        Then output exactly \(sprintMarker) on its own line. A Stop hook starts the next sprint.

        There is no natural end. The session exits only when:
          (a) The metric is clearly satisfactory and you output "\(marker)" on its own line.
          (b) The user presses Stop in Tado.

        Don't ask clarifying questions — decide and proceed.
        Don't summarise at the end of turns — metrics.jsonl and progress.md are the summary.

        ═══════════════════════════════════════════════════════════
        NON-STOP HYGIENE — avoid the only prompts bypass can't skip
        ═══════════════════════════════════════════════════════════
        Claude Code's `--dangerously-skip-permissions` skips every prompt \
        EXCEPT writes to protected paths under `.claude/` when the parent \
        directory has to be created. To keep the loop truly non-stop:
          • BEFORE any `Write` or `Edit` on a new path, run `Bash(mkdir -p <dir>)`
            first. Always. Especially for `.claude/agents/`, `.claude/skills/`,
            and any new subdirectory tree in a fresh trial project.
          • Prefer writing generated files OUTSIDE `.claude/` when possible
            (scratch files, reports, trial-project sources). `.tado/scratch/`
            and `\(runDir)/` are safe.
          • If you must create something under `.claude/`, create `.claude/`
            and the full subpath via `mkdir -p` FIRST, then Write.
          • Never use tools that open interactive dialogs or confirmations.
        """
    }

    // MARK: - Eternal Interventor

    /// One-shot agent spawned when the user clicks "Intervene" on a running
    /// Eternal worker. Reads the user's plain-language message, grounds it
    /// in the current worker state (crafted.md + progress.md tail), distills
    /// it into a structured directive, writes a file under
    /// `.tado/eternal/inbox/`, and prints a one-paragraph confirmation to
    /// the tile so the user knows when the worker will pick it up.
    ///
    /// Pinned to Haiku 4.5 at high effort — this is pure note-distillation,
    /// not planning. Opus would be overkill and slow.
    static func eternalInterventorPrompt(
        projectName: String,
        projectRoot: String,
        userMessage: String,
        runID: UUID
    ) -> String {
        let runDir = "\(projectRoot)/.tado/eternal/runs/\(runID.uuidString)"
        // Escape the user's message for inclusion in a heredoc-ish region.
        // The agent reads the triple-bar block as literal text regardless
        // of its content.
        return """
        You are the Tado Eternal Interventor for project "\(projectName)" at \(projectRoot).

        The user has clicked "Intervene" on a running Eternal worker (run id \
        \(runID.uuidString)). Your job — and ONLY your job right now — is to \
        translate that message into a structured note the worker will read \
        at the top of its next iteration, then STOP. Do NOT run sprints, do \
        NOT tado-deploy, do NOT modify crafted.md, do NOT tado-send.

        ═══════════════════════════════════════════════════════════
        THE USER'S MESSAGE
        ═══════════════════════════════════════════════════════════
        \(userMessage)
        ═══════════════════════════════════════════════════════════

        STEP 0 — Ground yourself. Read:
          - \(runDir)/crafted.md (the worker's authoritative brief)
          - \(runDir)/progress.md (tail ~30 lines — what the worker has done recently)
          - \(runDir)/state.json (the worker's phase and lastActivityAt — tells you how soon the worker will pick up the intervention)

        STEP 1 — Classify the user's intent. Pick ONE:
          • PRIORITY   — change what the worker focuses on next.
          • CORRECTION — worker did something wrong; fix it.
          • CONSTRAINT — add a new never-violate rule.
          • CONTEXT    — extra background info / clarification.
          • QUESTION   — user wants an answer from the worker (e.g. "why are you on M2 still?").

        STEP 2 — Decide the timing. Compare `state.json.lastActivityAt` \
        (unix seconds) to the current time:
          • If less than 60 seconds ago: the worker is mid-iteration. It \
            will see this at the start of the NEXT iteration.
          • Otherwise: the worker is between iterations. It will see this \
            within seconds.

        STEP 3 — Write the distilled directive to
          \(runDir)/inbox/intervene-<iso-timestamp>.md

        Use `Bash(mkdir -p \(runDir)/inbox)` first (the \
        directory may not exist yet). Use a UTC-formatted timestamp with \
        no colons in the filename, e.g. `intervene-20260419T001503Z.md`.

        The file's body must be in this exact shape:

          # Intervention: <short title, <= 60 chars>

          **Type:** PRIORITY | CORRECTION | CONSTRAINT | CONTEXT | QUESTION
          **Received (UTC):** <iso-8601 timestamp>
          **User's raw message:** \\\"<original message, verbatim, newlines preserved>\\\"

          ## Directive for the worker

          <2-5 sentence precise instruction: what to do, what to stop doing, \
          what to answer. Ground it in the actual files / phases the worker \
          is touching — be specific, not generic.>

          ## Act when

          <one of: "before anything else this iteration" | "after current \
          sprint ends" | "respond then continue normally">

        STEP 4 — Print a single paragraph to the tile so the user can see \
        that their intervention landed. Structure:
          • What classification you gave it (PRIORITY / CORRECTION / ...).
          • One-line summary of what you told the worker.
          • When the worker will see it, based on STEP 2's timing. Use \
            exact phrasing:
              - mid-iteration: "The worker is mid-iteration — it'll read \
                your note at the start of the next one (usually 1-3 \
                minutes from now)."
              - between iterations: "The worker is between iterations — \
                it'll read your note within a few seconds."

        STEP 5 — STOP. Do not loop, do not run sprints, do not tado-send. \
        Your job is done the moment STEP 3 and STEP 4 are complete.

        ═══════════════════════════════════════════════════════════
        HARD RULES
        ═══════════════════════════════════════════════════════════
        • BEFORE any Write or Edit on a new path, run Bash(mkdir -p <dir>).
        • DO NOT write under .claude/ — protected paths still prompt even \
          in bypass mode. Use .tado/eternal/inbox/ as specified.
        • DO NOT modify crafted.md. The architect owns that file. If the \
          user's message implies a brief change, capture that as a \
          CONSTRAINT in your directive and let the worker decide whether \
          to escalate.
        • Keep the directive precise and short. The worker re-reads the \
          full crafted.md every iteration; your note is a DELTA, not a \
          rewrite.
        """
    }

    // MARK: - Eternal Architect

    /// Prompt for the Eternal Architect — a short-lived Opus 4.7 / max-effort
    /// tile that reads the user's plain-language brief at
    /// `.tado/eternal/user-brief.md` and writes a fully-structured worker
    /// brief to `.tado/eternal/crafted.md`, then STOPS. It does not run
    /// sprints — the worker spawns after the user reviews and clicks Start.
    static func eternalArchitectPrompt(
        projectName: String,
        projectRoot: String,
        mode: String,
        runID: UUID
    ) -> String {
        let isSprint = (mode == "sprint")
        let runDir = "\(projectRoot)/.tado/eternal/runs/\(runID.uuidString)"

        let modeSectionSprint = """

        Design the three-phase sprint structure:
          TASK     — what to build/optimize each sprint. Specific. Measurable.
                     Grounded in files that actually exist in the project.
          EVALUATE — exactly how to score a sprint. Prefer ONE deterministic
                     bash command whose stdout is easy to parse into a number.
                     Describe a 0-1 composite score with sub-component weights
                     so the worker has a clear objective, not a hand-wave.
          IMPROVE  — the ladder of knobs the worker can turn between sprints,
                     ordered from safest to structural. Include plateau rules:
                     "if score within ±0.03 for N sprints, promote to next rung".

        Write the crafted specification to \(runDir)/crafted.md \
        in this exact shape:

          # Eternal Sprint — \(projectName)

          ## TASK
          <prose grounded in the project>

          ## EVALUATE
          <prose, including the exact bash command and the composite formula>

          ## IMPROVE
          <prose, plateau rules, ladder from safest to most structural>

          ## Hard rules
          <never-violate rules the worker should carry across all sprints —
           build must stay green, specific files off-limits, etc.>

          ## Sprint end ritual
          Each sprint ends when you output [SPRINT-DONE] on its own line.
          Only output ETERNAL-DONE if the metric is clearly satisfactory AND
          the user has indicated satisfaction.
        """

        let modeSectionMega = """

        Design one comprehensive implementation plan:
          - TASK: a single big goal, split into an ordered checklist of
            concrete deliverables the worker can tackle one at a time.
          - Acceptance criteria: how the worker knows the task is done.
          - Hard rules: files off-limits, build-must-stay-green, etc.

        Write the crafted specification to \(runDir)/crafted.md \
        in this exact shape:

          # Eternal Mega — \(projectName)

          ## TASK
          <one-paragraph summary of the whole plan>

          ## Checklist
          - [ ] concrete deliverable 1
          - [ ] concrete deliverable 2
          - [ ] ... (as many as the plan needs, usually 6-20)

          ## Acceptance
          <how to tell the whole plan is done>

          ## Hard rules
          <never-violate constraints>

          ## End ritual
          When every checklist item is ticked and Acceptance holds, output
          ETERNAL-DONE on its own line.
        """

        return """
        You are the Eternal Architect for the "\(projectName)" project at \(projectRoot).

        A Tado user has written a plain-language brief at
          \(runDir)/user-brief.md

        Your job — and ONLY your job right now — is to translate that brief into a \
        properly-structured Eternal \(isSprint ? "SPRINT" : "MEGA") specification at \
        \(runDir)/crafted.md, then STOP. A separate worker agent will run \
        the actual infinite \(isSprint ? "sprints" : "plan") after the user reviews what \
        you produced and clicks Start.

        ═══════════════════════════════════════════════════════════
        STEP 0 — READ THE USER BRIEF + GROUND YOURSELF
        ═══════════════════════════════════════════════════════════
        Read \(runDir)/user-brief.md. Then read the project's \
        CLAUDE.md, AGENTS.md, package manifests, and relevant source so your \
        specification is grounded in reality, not your prior-memory guess at \
        what the project is. The worker will run many iterations against this \
        spec — every ambiguity you leave becomes a wasted iteration.

        ═══════════════════════════════════════════════════════════
        STEP 1 — DESIGN THE SPECIFICATION
        ═══════════════════════════════════════════════════════════
        \(isSprint ? modeSectionSprint : modeSectionMega)

        ═══════════════════════════════════════════════════════════
        STEP 2 — WRITE crafted.md AND PRINT A SUMMARY
        ═══════════════════════════════════════════════════════════
        Write the file. Keep it under ~220 lines — the worker re-reads it \
        every iteration, so verbosity here costs tokens forever.

        Then print a short human-readable summary of what you produced: \
        \(isSprint ? "which composite score components, how many IMPROVE ladder rungs, what you had to infer vs what was explicit in the user brief" : "how many checklist items, which files the plan targets, what you had to infer").

        Then STOP. Do NOT:
          - run the plan yourself
          - tado-deploy anything
          - tado-send anything
          - loop or retry
        The user will review crafted.md on the Eternal section of the project \
        detail page and click Start (worker spawns) or Redo (re-runs you).

        ═══════════════════════════════════════════════════════════
        MANDATORY RULES YOU MUST INCLUDE IN crafted.md's "Hard rules"
        ═══════════════════════════════════════════════════════════
        Include these exact rules verbatim — they are the difference between \
        a truly non-stop loop and one that stalls or drifts:

          1. BEFORE any `Write` or `Edit` on a new path, run `Bash(mkdir -p <dir>)` \
             first. Always. Claude Code's `--dangerously-skip-permissions` skips \
             every prompt EXCEPT writes to protected paths under `.claude/` \
             when the parent directory has to be created. Prefer non-`.claude/` \
             output locations whenever possible; `.tado/scratch/` and \
             `\(runDir)/` are safe. If you must write under `.claude/`, \
             mkdir the full subpath first.

          2. EVERY turn, BEFORE you end the turn, append at least one concrete \
             line to `\(runDir)/progress.md` in the format \
             `YYYY-MM-DD HH:MM: <one sentence describing what you did>`. This \
             survives compaction — it's the worker's memory across context \
             resets. The Stop hook shows you the last progress.md line on every \
             block; if that line doesn't advance between turns, you forgot to \
             append.

          3. NEVER use tools that open interactive dialogs or confirmations. \
             If a tool asks for input, abort that path and take a different one.

        These rules go in the "Hard rules" section of crafted.md. Don't \
        paraphrase — paste them roughly verbatim so the worker can't \
        misinterpret them after a compaction.
        """
    }
}
