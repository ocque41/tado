import Foundation

enum ProcessSpawner {
    static func command(for todoText: String, engine: TerminalEngine, modeFlags: [String] = [], effortFlags: [String] = [], modelFlags: [String] = [], agentName: String? = nil, projectRoot: String? = nil, runID: UUID? = nil) -> (executable: String, args: [String]) {
        // Cowork has no CLI binary on PATH — Cowork is a tab inside
        // the Claude Desktop app. Tado launches it via the bundled
        // `tado-cowork` Rust binary, which builds the documented
        // `claude://cowork/new?q=…&folder=…` URL and shells `open(1)`.
        // The `tado-cowork` invocation is one-shot: it returns
        // immediately after `open(1)` succeeds, so the tile's PTY
        // sees the launcher's status preamble and then closes; the
        // CoworkOutputPoller takes over from there, watching for
        // the result file the bundled plugin's skill instructs
        // Cowork to write.
        if engine == .cowork {
            return coworkCommand(
                for: todoText,
                projectRoot: projectRoot,
                runID: runID
            )
        }
        let escaped = shellEscape(todoText)
        let cli = engine.rawValue
        var flags = modeFlags + effortFlags + modelFlags
        if let agentName, engine == .claude {
            flags.insert(contentsOf: ["--agent", agentName], at: 0)
        }
        flags = sanitizeFlags(flags)
        // Every flag token is shell-escaped so zsh doesn't mis-interpret
        // glob metacharacters. Load-bearing for `--model opus[1m]` (the
        // 1M-context Opus variant) — unquoted `opus[1m]` would trigger
        // zsh's `nomatch` and abort before claude ever runs. Simple
        // tokens like `--effort` or `claude-opus-4-7` single-quote to
        // themselves harmlessly, so no existing flag regresses.
        let allFlags = flags.map(shellEscape).joined(separator: " ")
        let cmd = allFlags.isEmpty ? "\(cli) \(escaped)" : "\(cli) \(allFlags) \(escaped)"
        return ("/bin/zsh", ["-l", "-c", cmd])
    }

    /// Resolve the `tado-cowork` binary path. Tries the bundled
    /// `.app/Contents/MacOS/tado-cowork` first (production), then
    /// `~/.local/bin/tado-cowork` (where IPCBroker installs the
    /// helper at app launch), then the dev workspace
    /// `tado-core/target/release/tado-cowork`. If none exist, fall
    /// back to a bare `tado-cowork` and let zsh's PATH lookup
    /// surface the failure to the user.
    private static func resolveTadoCoworkBinary() -> String {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/tado-cowork")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        let userBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/tado-cowork")
        if FileManager.default.fileExists(atPath: userBin.path) {
            return userBin.path
        }
        let devBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tado-core/target/release/tado-cowork")
        if FileManager.default.fileExists(atPath: devBuild.path) {
            return devBuild.path
        }
        return "tado-cowork"
    }

    /// Build a `tado-cowork --prompt … --folder … --run-id …`
    /// invocation. The `tado-cowork` binary is what actually fires
    /// the `claude://cowork/new` URL via `open(1)`. We pass the
    /// project root as the `--folder` so Cowork attaches it to the
    /// task; the run-id is what the bundled `cowork-tado-tools`
    /// skill teaches Cowork to use as the result-file basename
    /// (`<projectRoot>/.tado/cowork/<runID>.md`), which is what
    /// `CoworkOutputPoller` watches for.
    static func coworkCommand(
        for todoText: String,
        projectRoot: String?,
        runID: UUID?
    ) -> (executable: String, args: [String]) {
        let binary = resolveTadoCoworkBinary()
        // Default the folder to the user's home if no projectRoot
        // is provided — that's the safe fallback for an ad-hoc
        // Cowork tile spawned outside any registered project.
        let folder = projectRoot ?? FileManager.default
            .homeDirectoryForCurrentUser.path
        let runIDString = (runID ?? UUID()).uuidString.lowercased()
        let cmd = "\(shellEscape(binary)) " +
                  "--prompt \(shellEscape(todoText)) " +
                  "--folder \(shellEscape(folder)) " +
                  "--run-id \(shellEscape(runIDString))"
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

    /// Drop any `(flag, value)` pair whose value is the literal sentinel
    /// `"auto"` (and the engine-specific Codex variants like
    /// `model_reasoning_effort="auto"` baked into a `-c` payload).
    ///
    /// `"auto"` is Tado's UI sentinel meaning "do not send this flag — let
    /// the CLI pick its own default." `ClaudeEffort.cliFlags` and
    /// `CodexEffort.cliFlags` already honor this by returning `[]`, but
    /// any composed flag list that flows through generic call sites
    /// (Eternal worker assembly, tado-deploy, retry/fallback respawns)
    /// can re-introduce the literal. This helper guarantees that whatever
    /// the upstream picker emitted, the actual CLI invocation never sees
    /// `--effort auto` / `--model auto` / `-c key="auto"` (any of which
    /// the CLI rejects with "must be one of: low, medium, high, xhigh, max"
    /// or similar shape).
    ///
    /// Safe to call on any `[String]` flag list. Pure / order-preserving.
    static func sanitizeFlags(_ flags: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < flags.count {
            let token = flags[i]
            if token.hasPrefix("--"), i + 1 < flags.count, flags[i + 1] == "auto" {
                // Two-token flag with literal "auto" value — drop both.
                i += 2
                continue
            }
            if token == "-c", i + 1 < flags.count {
                let payload = flags[i + 1]
                // Codex `-c key="auto"` and `-c key=auto` both should be
                // dropped. Match either quoting style.
                if payload.hasSuffix("=\"auto\"") || payload.hasSuffix("=auto") {
                    i += 2
                    continue
                }
            }
            out.append(token)
            i += 1
        }
        return out
    }

    /// Engine-aware sanitizer. Runs the universal `"auto"` filter, then
    /// consults `CLICapabilities` to drop any `(--flag, value)` pair
    /// whose value is documented to be invalid by the installed CLI's
    /// own `--help` text.
    ///
    /// Why a second arity instead of a single helper: the engine-
    /// agnostic call sites (e.g. `codexExecCommand` after the embed
    /// shim is composed, mixed-engine tests) are content with the
    /// universal filter. The engine-aware call sites (every spawn that
    /// has already chosen a CLI) get the additional safety net.
    /// `CLICapabilities.shouldRejectValue` returns `false` whenever the
    /// cache hasn't probed yet — this method NEVER drops a flag because
    /// the cache is empty, only when the CLI explicitly told us the
    /// value would be rejected.
    @MainActor
    static func sanitizeFlags(_ flags: [String], engine: TerminalEngine) -> [String] {
        let universal = sanitizeFlags(flags)
        let caps = CLICapabilities.shared
        caps.probe(engine)
        var out: [String] = []
        var i = 0
        while i < universal.count {
            let token = universal[i]
            if token.hasPrefix("--"), i + 1 < universal.count {
                let value = universal[i + 1]
                if caps.shouldRejectValue(engine: engine, flag: token, value: value) {
                    EventBus.shared.publish(
                        .spawnFlagDropped(
                            sessionID: nil,
                            title: "pre-spawn sanitize",
                            flag: token,
                            value: value,
                            engine: engine.rawValue,
                            projectName: nil
                        )
                    )
                    i += 2
                    continue
                }
            }
            out.append(token)
            i += 1
        }
        return out
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
        projectID: UUID? = nil,
        projectRoot: String? = nil,
        teamName: String? = nil,
        teamID: UUID? = nil,
        agentName: String? = nil,
        teamAgents: [String]? = nil,
        claudeDisplay: ClaudeDisplayEnv = .defaults
    ) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TADO_IPC_ROOT"] = ipcRoot.path
        env["TADO_STORAGE_ROOT"] = StorePaths.root.path
        env["TADO_SESSION_ID"] = sessionID.uuidString.lowercased()
        env["TADO_SESSION_NAME"] = sessionName
        env["TADO_ENGINE"] = engine.rawValue
        if let projectName { env["TADO_PROJECT_NAME"] = projectName }
        if let projectID { env["TADO_PROJECT_ID"] = projectID.uuidString.lowercased() }
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
            env["TADO_DOME_VAULT"] = DomeVault.resolveRoot().path
            env["TADO_DOME_RETRIEVAL_FRESHNESS"] = "spawn"
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

    /// Prompt for the "Bootstrap Auto Mode" tile. The spawned agent
    /// merges Tado's recommended auto-mode configuration into the user's
    /// Claude Code settings — user-scope (`~/.claude/settings.json`)
    /// AND project-local (`<project>/.claude/settings.local.json`).
    ///
    /// The prompt is written for an audience that doesn't assume prior
    /// familiarity with Claude Code's permission system. Every term is
    /// defined before it's used — bypass mode, auto mode, the classifier,
    /// the protected-path exception, `autoMode.environment`,
    /// `permissions.allow`. That way the user reading the transcript
    /// understands what changed and why.
    static func bootstrapAutoModePrompt(projectName: String, projectRoot: String) -> String {
        """
        You are bootstrapping Tado's "auto mode" configuration for Claude Code.
        Project: "\(projectName)" at \(projectRoot).

        (This setup is required because Continuous Eternal runs need
        `--permission-mode auto` — Claude Code's classifier-gated autonomy
        mode, available for Opus 4.7 on Max/Teams/Enterprise plans. Tado
        pins Opus 4.7 automatically for Continuous runs.

        Codex Eternal does NOT need this setup — Codex uses its own
        `--ask-for-approval never --sandbox danger-full-access` flag set
        which Tado wires up automatically. Both session styles work for
        Codex: Normal (per-turn) respawns `codex "<prompt>"` each
        iteration via the eternal-loop wrapper; Continuous keeps one
        interactive `codex` session alive and lets Tado's idle injection
        re-fire the continue prompt every time the session goes idle.)

        ═══════════════════════════════════════════════════════════
        CONTEXT — WHAT YOU ARE DOING AND WHY
        ═══════════════════════════════════════════════════════════

        Tado is a macOS app that runs long-lived Claude Code agents as
        terminal tiles. Its "Eternal" feature runs a single agent for
        hours or days without user input. That only works if every
        Claude Code tool call auto-approves — a single permission
        dialog halts the loop forever.

        Historically Tado used `--dangerously-skip-permissions` (a.k.a.
        "bypass mode") to silence prompts. Bypass has a hard-coded
        exception: writes to `.git`, `.claude`, `.vscode`, `.idea`, and
        `.husky` STILL prompt. That exception regularly stalled Eternal
        runs mid-iteration.

        Claude Code shipped **auto mode** in late April 2026 as the
        official replacement for bypass. Auto mode sends each tool call
        to an AI classifier that judges safety on four axes:
          1. Reversibility — can this be undone?
          2. Scope alignment — is it inside the user's request?
          3. Risk surface — does it touch credentials or external data?
          4. Cascading effects — could this chain into damage?

        Safe calls auto-approve. Risky calls still prompt. Crucially,
        auto mode has NO protected-path exception. Writes to `.git/`
        auto-approve if the classifier considers them in-scope.

        Your job: set up both layers of Tado's recommended auto-mode
        config:

          * Layer A — USER SCOPE (`~/.claude/settings.json`). Machine-wide.
            Lets auto mode work on EVERY Claude Code session on this
            machine, not just ones spawned from this project. Without it,
            the user running `claude` from a regular Terminal outside
            Tado would still hit permission prompts.

          * Layer B — PROJECT-LOCAL SCOPE
            (`\(projectRoot)/.claude/settings.local.json`). Gitignored
            by convention. Holds this project's specific trust context so
            the classifier understands what's safe in THIS repo (the
            `autoMode.environment` prose mentions this project's
            filesystem, remotes, and build tools). Without it, the
            classifier errs on the side of blocking routine in-repo
            operations.

        CRITICALLY, you will NOT touch the committed project-scoped
        settings file at `\(projectRoot)/.claude/settings.json`. That
        file is for hooks + a baseline allow list that other developers
        on the team share via git. The classifier-context keys
        (`autoMode.environment`, the full permissions.allow list) stay
        in Layer A + Layer B only, so teammates don't inherit Tado-
        specific trust context assuming unattended execution.

        ═══════════════════════════════════════════════════════════
        STEP 0 — READ THE CURRENT STATE
        ═══════════════════════════════════════════════════════════

        Read these two files. If either is missing, treat it as an empty
        JSON object `{}` — you will create it during the merge:

          * ~/.claude/settings.json         (user scope)
          * \(projectRoot)/.claude/settings.local.json   (project-local scope)

        Note the existing keys. You must NOT delete or overwrite any
        keys the user set intentionally. This merge is strictly additive.

        ═══════════════════════════════════════════════════════════
        STEP 1 — UPDATE user scope (~/.claude/settings.json)
        ═══════════════════════════════════════════════════════════

        Read the existing JSON (or start from {} if the file is absent).
        Make the following changes, preserving everything else:

        1a. Set `permissions.defaultMode = "auto"`.
            If `permissions` doesn't exist, create it. If `defaultMode`
            was previously "bypassPermissions", log that you changed it.

        1b. Ensure `permissions.allow` is an array and contains AT LEAST
            these entries (append any that are missing, don't touch
            existing):

              "Bash(*)"
              "Edit(**)"
              "Write(**)"
              "Read(**)"
              "Glob"
              "Grep"
              "WebFetch"
              "WebSearch"
              "NotebookEdit"
              "TodoWrite"
              "Task"
              "mcp__*"
              "mcp__tado__*"
              "mcp__dome__*"
              "Edit(./.git/**)"
              "Write(./.git/**)"
              "Edit(./.claude/**)"
              "Write(./.claude/**)"
              "Edit(./.tado/**)"
              "Write(./.tado/**)"
              "Edit(./.vscode/**)"
              "Write(./.vscode/**)"
              "Edit(./.idea/**)"
              "Write(./.idea/**)"
              "Edit(./.husky/**)"
              "Write(./.husky/**)"

            The `.git/**`, `.claude/**`, `.tado/**`, `.vscode/**`,
            `.idea/**`, `.husky/**` patterns are the critical ones —
            they replace bypass mode's hard-coded exception list with
            explicit allow rules. `.tado/**` is the per-project state
            directory (eternal/dispatch run JSON, project memory) that
            v0.9.0 agents routinely write to.

            `mcp__tado__*` and `mcp__dome__*` are explicitly listed
            (in addition to the wildcard `mcp__*`) so a future user
            who narrows their wildcard doesn't accidentally lock the
            Tado-shipped MCP tools out of auto-approval.

        1c. Ensure `autoMode.environment` is an array and contains
            these natural-language trust descriptors (append any that
            are missing). These are prose that Claude Code's classifier
            reads to understand what counts as "routine" vs. "external
            data exfiltration":

              "Organization: local developer machine. Primary use: software development driven by the Tado macOS app, which spawns long-lived `claude` sessions as terminal tiles."
              "Trusted source control: this project's git remote (typically GitHub / GitLab over HTTPS or SSH). Pushing to the project's own origin is routine, not exfiltration."
              "Trusted local filesystem: the project root and everything under it — including `.git`, `.claude`, `.tado`, `.vscode`, `.idea`, `.husky`, `node_modules`, `.venv`, and `.build`. Tado agents routinely edit these as part of normal workflow. The `.tado/` directory holds Eternal/Dispatch run state, project memory, and per-project notes — write access is required."
              "Trusted MCP servers: any tool matching `mcp__*`. The user wires MCP servers explicitly in `~/.claude/settings.json`. Specifically, `mcp__tado__*` (Tado A2A + config + memory + events) and `mcp__dome__*` (Dome second-brain knowledge graph) are first-party tools shipped with Tado itself — their writes target the user's own vault and IPC sockets, never external services."
              "Trusted Tado IPC: `tado-list`, `tado-read`, `tado-send`, `tado-deploy`, `tado-events`, `tado-config`, `tado-memory`, `tado-notify`, `tado-dome`. These are local CLIs at `~/.local/bin/` that talk to the running Tado app via Unix sockets and atomic JSON files — they never reach the network."
              "Trusted package managers and build tools: npm, pnpm, yarn, bun, pip, uv, cargo, swift, brew, gem, go. Package install, update, audit, and build operations are routine."
              "Additional context: Tado's Eternal feature runs unattended for hours or days. Err on the side of autonomy for reversible, in-scope operations. Bash commands like `rm -rf <path-under-project>` are legitimate cleanup within the project; Bash commands that reach outside the project root (into `/usr`, `/System`, user home outside the project) are NOT routine and should still be gated."

        Write the merged JSON back atomically (mktemp + mv) with
        pretty-printed two-space indent.

        ═══════════════════════════════════════════════════════════
        STEP 2 — UPDATE project-local scope
        ═══════════════════════════════════════════════════════════

        Same as Step 1, but target
        \(projectRoot)/.claude/settings.local.json instead. This file is
        gitignored by convention, so the config is local to this
        machine's clone and doesn't leak into the repo.

        Create the `.claude/` directory first if it doesn't exist:
          Bash(mkdir -p \(projectRoot)/.claude)

        Then repeat Steps 1a / 1b / 1c against
        `settings.local.json`. Identical content; the two scopes
        reinforce each other so a user who blows away their user
        settings still has the project-local coverage.

        ═══════════════════════════════════════════════════════════
        STEP 3 — VERIFY AND REPORT
        ═══════════════════════════════════════════════════════════

        Print a summary with a clearly-labeled section for EACH of the
        two scopes (USER and PROJECT-LOCAL), so the user reading this
        tile transcript can confirm both scopes were merged without
        having to diff files by hand. For each scope, include:

          * File path (absolute)
          * Did the file exist before you touched it? (yes/no)
          * What value `permissions.defaultMode` had before vs. after
          * Count of entries already in `permissions.allow` vs. how
            many you appended (and which ones, in a bulleted list)
          * Count of entries already in `autoMode.environment` vs. how
            many you appended (and a short excerpt of each new one)
          * Whether `skipDangerousModePermissionPrompt` (a legacy
            bypass-mode key) is present — if so, note that it's now
            harmless under auto mode but can be removed

        End the summary with one line confirming that
        `\(projectRoot)/.claude/settings.json` (the committed file) was
        NOT modified — so the user can confirm Tado's trust context
        didn't leak into the shared repo.

        Then STOP. Do NOT:
          * Start any Eternal runs
          * tado-deploy anything
          * tado-send anything
          * Modify CLAUDE.md, AGENTS.md, or project source code
          * Fiddle with permissions on unrelated files
          * Touch `\(projectRoot)/.claude/settings.json` — that's the
            committed team-shared file and is explicitly out of scope.
        """
    }

    /// Generate the prompt for a bootstrap agent that injects A2A CLI docs into a target project.
    /// Refreshed for v0.9.0: now mentions `tado-events` (real-time bus), the Rust MCP bridges,
    /// and the broadcast pub/sub surface. Older bootstraps wrote a v0.4.0-shaped section that
    /// only knew about file-based IPC; agents reading those stale docs missed half the surface.
    static func bootstrapPrompt(targetPath: String) -> String {
        """
        You are bootstrapping the Tado A2A (Agent-to-Agent) tooling docs into the project at \
        \(targetPath). After this runs, every Claude Code or Codex agent that wakes up inside \
        this project will know how to talk to its sibling terminals on the Tado canvas.

        ═══════════════════════════════════════════════════════════
        SOURCE — what to inject
        ═══════════════════════════════════════════════════════════
        Read these sections from the Tado repo's docs (your current cwd is the Tado repo):
          * From ./CLAUDE.md  : '## Tado A2A (Agent-to-Agent IPC)'
          * From ./AGENTS.md  : '## Tado A2A', '## Contacting Other Agents',
                                '## Team Coordination', '## Deploying Agents',
                                '## Responding to Agent Requests (Mandatory)',
                                '## Message Origin Rules'

        ═══════════════════════════════════════════════════════════
        TARGET — where it lands
        ═══════════════════════════════════════════════════════════
        1. \(targetPath)/CLAUDE.md \u{2014} if it has a '## Tado A2A' section already, REPLACE \
        it with the fresh copy (older bootstraps may have written v0.4.0-shaped docs that don't \
        mention `tado-events` or the Rust MCP bridges). If the file doesn't exist, create it \
        with a '# CLAUDE.md' header.
        2. \(targetPath)/AGENTS.md \u{2014} same logic for each of the six sections listed above. \
        Replace stale copies; append fresh ones; create the file with a '# AGENTS.md' header if \
        absent.

        Preserve every other section in both files. Only the listed Tado-A2A sections are \
        in scope.

        ═══════════════════════════════════════════════════════════
        REQUIRED CONTENT (v0.9.0 shape)
        ═══════════════════════════════════════════════════════════

        **AXI-compact convention** (key for token efficiency \u{2014} use it everywhere):
        Every Tado read CLI accepts `--toon`: one record per line, space-separated, no \
        header, ~40\u{2013}45% fewer tokens than the default JSON shape. Use `--toon` by \
        default for `tado-list`, `tado-events`, `tado-dome query`, `tado-dome code-search`, \
        `tado-dome watch-list`, etc. Drop the flag only when you need a JSON field that's \
        not in the compact form.

        **Core CLI tools** (installed at `~/.local/bin/`):
          tado-list [--toon]                        \u{2014} active sessions (UUID, engine, grid, status, name)
          tado-read <target> [--tail N] [--follow] [--raw]
          tado-send <target> <message>
          tado-deploy "<prompt>" [--agent <name>] [--team <name>] [--project <name>] [--engine claude|codex] [--cwd <path>]
          tado-events [filter] [--toon]             \u{2014} real-time event stream from /tmp/tado-ipc/events.sock
          tado-config {get,set,list,path,export,import} [scope] [key] [value]
          tado-notify {send "<title>", tail}
          tado-memory {read,note,search,path} [scope]
          tado-dome {register,query,read,code-search,...} [--toon]
                                                    \u{2014} scoped Dome knowledge from canvas agents
          tado-kanban {list, move <todo-id> <column-key>, add-column --title <text>}
                                                    \u{2014} per-project Kanban board (cards + columns)

        **Target resolution** (priority order, same for `tado-read` and `tado-send`):
          1. Exact UUID
          2. Grid coordinates: `1,1` or `1:1` or `[1,1]`
          3. Name substring match

        **Real-time event bus** (NEW in v0.9.0): `tado-events "*"` subscribes to every event \
        on the local socket; filter forms include `topic:<name>`, `session:<uuid>`, or any \
        kind prefix (e.g. `terminal.`). Use this instead of polling `tado-list` when you need \
        to react to teammate activity \u{2014} the socket is fed by Tado's in-process EventBus, \
        so you see `terminal.completed`, `eternal.phaseCompleted`, `ipc.messageReceived`, and \
        user broadcasts within milliseconds.

        **MCP bridges** (auto-registered into Claude Code at user scope; agents can call \
        these tools without spawning shell commands):
          tado-mcp \u{2014} `tado_list`, `tado_send`, `tado_read`, `tado_broadcast`,
                       `tado_config_{get,set,list}`, `tado_memory_{read,append,search}`,
                       `tado_notify`, `tado_events_query`
          dome-mcp \u{2014} `dome_search`, `dome_read`, `dome_note`, `dome_schedule`,
                       `dome_graph_query`, `dome_context_resolve`, `dome_context_compact`,
                       `dome_agent_status`
        Both bridges are stdio Rust binaries inside the bundled `.app` \u{2014} no Node runtime, \
        no separate install.

        **Broadcast / pub-sub**: `tado-send --broadcast "<message>"` reaches every listening \
        agent in the matching scope; combine with `--project <name>` or `--team <name>` to \
        filter. Pair this with `tado-events "topic:<name>"` for fan-in coordination patterns.

        **Coordinator-driven Tado workflows** (NEW): the user can drive any Tado feature \
        from the general todo page by typing `tado <natural-language brief>`. That spawns \
        a Claude Opus 4.7 coordinator agent that interprets the brief, drives Tado via the \
        coordinator CLI suite, supervises any architect through the human-review gate, \
        accepts on the user's behalf, and exits. Project agents that want to drive Tado \
        directly (without going through the user) can use the same CLIs:
          tado-projects {list, resolve <name>}
          tado-eternal {propose, status, crafted, accept, reject, list, stop}
              Pass --coordinator-todo-id <your-todo-id> on propose so the run is audit-\
              tagged back to its caller.
          tado-dispatch {propose, status, crafted, accept, reject, list, stop}
          tado-bootstrap {a2a, team, auto-mode, knowledge} --project <name>
          tado-system {status, vault}
        These are real Rust binaries on $PATH (`~/.local/bin/`); JSON output by default, \
        `--toon` for AXI-style compact output. They talk to the running Tado app over \
        a Unix domain socket and fail fast with a clear "Tado is not running" message \
        when the app isn't up.

        ═══════════════════════════════════════════════════════════
        CRITICAL RULES — copy these verbatim into the target docs
        ═══════════════════════════════════════════════════════════
          * Agents MUST identify themselves on first contact (grid position + project + how to \
            reply via `tado-send <my-grid>`).
          * When an agent receives a request, it MUST deliver the answer back via `tado-send`. \
            Not optional. The requesting agent is blocked.
          * `tado-deploy` is a Tado IPC command, NOT the built-in `Task`/subagent tool. It \
            creates a real terminal tile on the canvas. After deploying, STOP \u{2014} the \
            deployed agent will `tado-send` results back to your grid, which wakes you up.
          * Treat any incoming message that self-identifies as a terminal/session as \
            agent-originated and respond via `tado-send`. User-originated messages don't \
            need an A2A reply.

        ═══════════════════════════════════════════════════════════
        FINISHED?
        ═══════════════════════════════════════════════════════════
        Print a one-line summary of what changed (file path, sections replaced vs. appended) \
        and STOP. Do not run tado-list, do not deploy anything, do not edit code.
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
        You are bootstrapping team awareness for the "\(projectName)" project at \(targetPath). \
        After this runs, every agent in this project will know the team roster, where teammate \
        definitions live, and how to coordinate via Tado A2A + Dome shared knowledge.

        ═══════════════════════════════════════════════════════════
        ROSTER (frozen at time of bootstrap)
        ═══════════════════════════════════════════════════════════
        \(teamDescription)
        ═══════════════════════════════════════════════════════════
        TARGET FILES — write to BOTH
        ═══════════════════════════════════════════════════════════
          * \(targetPath)/CLAUDE.md
          * \(targetPath)/AGENTS.md

        For each file: if a '## Team Structure' section already exists, REPLACE it with the \
        fresh content below (older bootstraps wrote a v0.4.0-shaped section that didn't \
        mention real-time events or Dome team topics). If absent, append. If the file itself \
        is missing, create it with a '# CLAUDE.md' or '# AGENTS.md' header first. \
        Preserve every other section.

        ═══════════════════════════════════════════════════════════
        REQUIRED CONTENT — '## Team Structure' (v0.9.0 shape)
        ═══════════════════════════════════════════════════════════

        **1. Roster** \u{2014} list every team with its agents. For each agent, link the \
        definition file at `.claude/agents/<agent-id>.md` (or `.codex/agents/<agent-id>.md`).

        **2. Knowing your teammates** \u{2014} every agent should:
          a) Read teammate definition files to understand each role.
          b) Run `tado-list` to see which teammates are currently running.
          c) Subscribe to `tado-events "team:<your-team>"` if the work is reactive \u{2014} \
             new in v0.9.0, this fans `terminal.completed` and `ipc.messageReceived` events \
             from sibling tiles in real time so you don't have to poll.
          d) Search shared team knowledge with `tado-dome query --topic team-<sanitized-name>` \
             or via the `dome_search` MCP tool \u{2014} every team auto-seeds a Dome topic at \
             registration that captures retros, decisions, and shared notes.

        **3. Contacting a teammate** \u{2014} every first contact MUST include:
          * Who you are (grid + project + role)
          * What you need
          * How to reply (`tado-send <your-grid> "<response>"`)

        **4. Responding to a teammate request** (MANDATORY \u{2014} not optional):
          * Read the request, produce the actual deliverable, send it back via `tado-send`.
          * Don't just work silently. Don't just acknowledge. The teammate is BLOCKED until \
            you deliver.

        **5. Bringing a teammate online with `tado-deploy`**:
          * `tado-deploy` is a Tado IPC command (NOT your built-in `Task` / subagent tool). \
            It spawns a real terminal tile on the canvas.
          * Syntax: `tado-deploy "<prompt>" --agent <name> [--team <name>] [--project <name>] \
            [--engine claude|codex] [--cwd <path>]`
          * Defaults (team, project, engine, cwd) inherit from your `TADO_*` env vars; usually \
            you only need `--agent` and the prompt.
          * Always include `tado-send <my-grid> "<result>"` instructions in the deployed \
            agent's prompt. After deploying, STOP \u{2014} the deployed agent will wake you \
            when it sends results back.

        **6. Persistent team memory** (v0.9.0):
          * Append durable team decisions and retros via `tado-dome register --topic team-<name> --note "..."` \
            (or the `dome_note` MCP tool). Anything you write is searchable by every \
            current and future teammate via `dome_search` and shows up in their spawn-time \
            context preamble.

        ═══════════════════════════════════════════════════════════
        EXAMPLES (copy verbatim into the docs)
        ═══════════════════════════════════════════════════════════

        Communication \u{2014}
          "I'm the 'frontend' agent on team 'core' in the \(projectName) project (grid [1,1]). \
          I need the API types you generated. Reply with: tado-send 1,1 '<types>'"
        The recipient MUST then run: `tado-send 1,1 "Here are the types: ..."` with the \
        actual content.

        Delegation \u{2014}
          # frontend at [1,1] needs schema work
          tado-deploy "design the database schema for user auth. When done, deliver results \
          via tado-send 1,1" --agent backend
          # STOP. The backend agent will tado-send results, which wakes you.

        Reactive coordination \u{2014}
          tado-events "team:core" &
          # now your terminal sees every team-scoped event in real time

        Coordinator-driven runs \u{2014}
          # The user can spawn a Claude coordinator from the general todo page by typing
          # `tado <natural-language brief>`. The coordinator drives Tado via the
          # `tado-eternal` / `tado-dispatch` / `tado-bootstrap` CLIs and accepts the
          # human-review gate on the user's behalf. Team agents can call those same
          # CLIs directly (with `--coordinator-todo-id <your-todo-id>` for audit) to
          # propose runs without involving the user. See `Bootstrap A2A tools` for the
          # full coordinator CLI surface.

        ═══════════════════════════════════════════════════════════
        FINISHED?
        ═══════════════════════════════════════════════════════════
        Print which sections were replaced vs. appended in each file, then STOP.
        """
    }

    /// Generate the prompt for a bootstrap agent that injects Tado's knowledge-layer docs
    /// (Dome second brain + spawn-time context preamble + the dome-mcp / tado-mcp tool
    /// surfaces) into the project's `CLAUDE.md` and `AGENTS.md`.
    ///
    /// New in v0.9.0: every Tado-spawned agent already wakes with a context preamble
    /// drawn from Dome, but the agent has no idea it exists or how to *extend* the vault
    /// (`tado-dome register`, `dome_note`, `dome_search`) until it reads docs that say so.
    /// This bootstrap closes that gap — it's the third leg next to "A2A tools" and
    /// "team awareness".
    static func bootstrapKnowledgePrompt(
        projectName: String,
        projectRoot: String
    ) -> String {
        """
        You are bootstrapping Tado's knowledge-layer docs into the "\(projectName)" project at \
        \(projectRoot). After this runs, every agent that wakes up here will know the second \
        brain (Dome) exists, what's already in it, and how to read + extend it without \
        burning tokens on prose-shaped output.

        ═══════════════════════════════════════════════════════════
        WHY THIS MATTERS
        ═══════════════════════════════════════════════════════════
        Tado's "Bootstrap A2A tools" teaches an agent how to TALK to siblings. \
        "Bootstrap team awareness" teaches it WHO its siblings are. \
        This bootstrap teaches it what it KNOWS \u{2014} the persistent vault that survives \
        across runs, accumulates project history, and is automatically searched + injected \
        into every spawn's prompt.

        Without this section in the project's docs, agents wake up, see the Dome context \
        preamble in their prompt, and treat it as ambient noise instead of a queryable, \
        writable, MEASURED knowledge base. They re-derive context every run, never write \
        retros, never use compact AXI flags, and burn tokens reading prose-shaped JSON \
        when one-line records would do.

        ═══════════════════════════════════════════════════════════
        TARGET FILES
        ═══════════════════════════════════════════════════════════
          * \(projectRoot)/CLAUDE.md
          * \(projectRoot)/AGENTS.md

        For each file: if a '## Knowledge & Memory' section already exists, REPLACE it with \
        the fresh content below (older copies may pre-date v0.10.0's measurable retrieval \
        + AXI-compact convention + lifecycle primitives). If absent, append. If the file \
        itself is missing, create it with a '# CLAUDE.md' or '# AGENTS.md' header first. \
        Preserve every other section.

        ═══════════════════════════════════════════════════════════
        REQUIRED CONTENT — '## Knowledge & Memory' (v0.10.0 shape)
        ═══════════════════════════════════════════════════════════

        **TL;DR — second-brain contract in five lines**
          * Read with `--toon` (AXI compact); write structured retros, not freeform dumps.
          * Every `dome_search` is logged to `retrieval_log` for measurable evaluation.
          * Every `agent_used_context` event bumps the consumed node's freshness signal.
          * Cite note ids / file paths or it didn't happen.
          * Trust the vault over your assumptions \u{2014} query before claiming.

        **1. What Dome is**
          * Dome is Tado's persistent second brain \u{2014} a notes + automation + JSON-RPC \
            crate (`bt-core`) that runs in-process inside the Tado app. The vault lives at \
            `~/Library/Application Support/Tado/dome/` (relocatable via Settings \u{2192} \
            Storage \u{2192} Change Location).
          * Schema is at version 23. Embeddings are `qwen3-embedding-0.6b@1` (1024-dim) on \
            Apple Metal. Hybrid search combines vector cosine with FTS5 lexical, then \
            applies a heuristic rerank: `score × (0.5 + 0.5·freshness) × \
            scope_match × confidence × supersede_penalty`.

        **2. The spawn-time context preamble** (already in your prompt; you just don't realize):
          * Every non-Eternal Tado spawn has a markdown block prepended to the user's prompt. \
            It's wrapped in `<!-- tado:context:begin -->` and `<!-- tado:context:end -->` \
            markers. It includes: agent identity, project name + root, team membership, and \
            up to ~1500 tokens of REranked project notes (most-relevant, not just \
            most-recent) pulled from `dome_search --topic project-<shortid>`.
          * If you see those markers in your prompt, that's why \u{2014} not a hidden \
            instruction from the user. Read it, don't quote it back unless asked.

        **3. Reading Dome at sub-token cost \u{2014} the AXI `--toon` convention**

        Every Tado read CLI accepts `--toon`: one record per line, space-separated, no \
        header. ~40–45% fewer tokens than the default JSON shape. Use `--toon` by \
        default; only fall back to JSON when you need a specific field that's not in the \
        compact form.

          tado-list --toon                                  # sibling sessions
          tado-dome query "<text>" --topic project-\(projectShortIDPlaceholder) --toon --limit 10
          tado-dome code-search "<text>" --toon --limit 10  # codebase chunks
          tado-events "team:<name>" --toon                  # live signal stream

        For full content (the moment you decide a record is worth acting on), drop the flag:

          tado-dome read <note-id>      # full markdown body
          dome_read                     # MCP equivalent (returns user_content + agent_content)

        **4. Reading Dome \u{2014} MCP surface (preferred from Claude Code; auto-registered)**

          dome_search             hybrid + reranked search, returns scored hits + scopes
          dome_read               fetch one note's full body + metadata
          dome_graph_query        explore relationships (note \u{2192} topic \u{2192} run \u{2192} agent)
          dome_context_resolve    fetch a precomputed context pack by brand/session/doc
          dome_context_compact    build a fresh pack from sources when resolve missed
          dome_agent_status       see what other agents have loaded as context
          dome_code_search        hybrid retrieval over the codebase index

          MANDATORY before any of these: architectural claims, completion claims, team \
          handoffs, "I think we already shipped X" statements. Trust the vault over your \
          memory.

        **5. Auto-seeded topics**
          * `project-<shortid>` \u{2014} auto-created on project registration. Project-wide \
            decisions, architecture notes, retros.
          * `team-<sanitized-name>` \u{2014} created when bootstrap-team runs. Cross-team \
            coordination.
          * Eternal sprint + completion retros mirror into Dome automatically.

        **6. Writing Dome \u{2014} structured retros, not freeform dumps**

        Use `dome_note` (MCP) or `tado-dome register` (CLI). Recipe for a retro:

          ## Outcome      one sentence: what shipped or what failed
          ## Decision     what was chosen, with one-sentence reason
          ## Caveats      surprising constraints, dead ends, gotchas
          ## Cite         note ids, file:line refs, run ids, commit shas
          ## Next agent should know
                          one bullet, the trap they'll hit if they redo this

        Write fact, not narrative. NO secrets, credentials, in-flight chatter, or \
        speculation. The vault is SQLite + chunked markdown on disk; everything is \
        retrievable + indexed.

        **7. Measurable retrieval (NEW in v0.10.0)**

        Every `dome_search` / `dome_recipe_apply` call writes one row to `retrieval_log`: \
        query, ranked results, scopes, latency, pack_id. When you (or another agent) \
        consume a context pack via `dome_context_resolve`, an `agent_used_context` event \
        fires and:

          * the consumed `graph_node`'s `last_referenced_at` bumps to now (it ranks \
            higher in the next preamble);
          * the matching `retrieval_log` row flips `was_consumed = 1` (this is implicit \
            relevance feedback the upcoming `dome-eval` CLI replays).

        Implication: your queries shape the next agent's preamble. Be specific \u{2014} \
        one targeted query per intent beats five shotgun ones.

        **8. Lifecycle primitives + governed answers (v0.10.0 stack)**

        `graph_nodes` now carry: `confidence`, `superseded_by`, `supersedes`, `expires_at`, \
        `archived_at`, `content_hash`, `last_referenced_at`, `entity_version`. \
        `graph_edges` carry: `source_signal`, `signal_confidence`, `evidence_id`.

        Three lifecycle MCP tools (Phase 3):

          dome_supersede --old_id <id> --new_id <id> [--reason "..."]
                         # Demotes the old node 0.3× via the supersede penalty.
          dome_verify --node_id <id> --verdict confirmed|disputed
                      # Lifts confidence ≥ 0.9 (confirmed) or ≤ 0.4 (disputed).
          dome_decay --node_id <id> [--reason "..."]
                     # Soft-archives a stale node. Hard delete is reversed-only.

        Two recipe MCP tools (Phase 5 — governed answers):

          dome_recipe_list [--scope global|project] [--project_id ...]
                           # List enabled retrieval recipes.
          dome_recipe_apply --intent_key <key> [--project_id ...]
                            # Returns synthesized markdown + citations + missing-authority
                            # gaps. No LLM in the loop — deterministic template render.

        Three baseline recipes ship with every Tado install:

          - **architecture-review** — use before making architecture decisions.
            Surfaces prior decisions, outstanding intents, recent retros.
          - **completion-claim** — use before claiming a feature is shipped.
            Surfaces outcomes, retros, decisions backing the claim.
          - **team-handoff** — use before delegating to or accepting work from
            a teammate. Surfaces team-scoped decisions + recent retros.

        Always prefer `dome_recipe_apply` over hand-crafted `dome_search` queries \
        for these high-stakes intents — the recipe encodes the right scope, kinds, \
        freshness window, and minimum-confidence threshold for the question.

        **9. Scoped knowledge**
          * `--scope global` — cross-project conventions ("Tado IPC conventions", \
            "Anthropic API caching patterns").
          * `--scope project` (default) — this codebase only; lives in \
            `project-<shortid>`.
          * `merged` reads include both — the spawn preamble uses merged when the \
            user toggles "include global with project".

        **10. Real-time signals + project-local memory**
          * `tado-events "*"` streams every Tado event from `/tmp/tado-ipc/events.sock`. \
            Filters: `topic:<name>`, `session:<uuid>`, kind prefix (`terminal.`, \
            `eternal.`, `dispatch.`).
          * `tado_events_query` MCP tool answers historical queries from \
            `~/Library/Application Support/Tado/events/current.ndjson`.
          * `<project>/.tado/memory/{project.md, notes/<ISO>-*.md}` — plain markdown \
            mirror of project-scoped Dome content, human-readable. CLI: `tado-memory \
            {read,note,search,path}`. MCP: `tado_memory_*`.

        ═══════════════════════════════════════════════════════════
        RECIPES — copy verbatim into the docs
        ═══════════════════════════════════════════════════════════

        ① Search before re-deriving (compact form by default) —
          tado-dome query "framework upgrade decision" \\
                          --topic project-\(projectShortIDPlaceholder) --toon --limit 10

        ② Read full body when you've picked a hit —
          tado-dome read <note-id>
          # MCP equivalent: dome_read with note_id

        ③ Persist a retro after finishing a task —
          dome_note --topic project-\(projectShortIDPlaceholder) \\
                    --title "Auth refactor — 2026-04-26 retro" \\
                    --body "$(cat <<'EOF'
          ## Outcome
          Replaced session-token storage with HttpOnly cookies.

          ## Decision
          Cookies over JWTs because legal flagged token-in-localStorage as non-compliant.

          ## Caveats
          Safari 16 strips Domain= on the redirect; pin Domain explicitly.

          ## Cite
          - Sources/Auth/Session.swift:42
          - run-id: 7f3e1a9c

          ## Next agent should know
          Don't \"fix\" the explicit Domain= attribute. Safari needs it.
          EOF
          )"

        ④ Register cross-project conventions globally —
          tado-dome register --scope global --topic tado-ipc-conventions \\
                             --note "All A2A messages must self-identify on first contact ..."

        ⑤ Stream live team activity —
          tado-events "team:core" --toon | head -20

        ⑥ Quick \"who's been reading what\" snapshot —
          dome_agent_status --limit 20
          # Combine with tado-list --toon to map back to grid positions.

        ⑦ Drive Tado from inside an agent (coordinator CLIs) —
          # Spawn an Eternal sprint without bothering the user:
          tado-eternal propose --project <name> --feature <feature> \\
                               --task "<text>" --mode sprint \\
                               --coordinator-todo-id $TADO_SESSION_ID
          tado-eternal status <run_id>
          tado-eternal crafted <run_id>     # read the architect's plan
          tado-eternal accept <run_id> --note "<one-paragraph rationale>"
          # See `Bootstrap A2A tools` for the full coordinator CLI surface
          # (tado-projects, tado-eternal, tado-dispatch, tado-bootstrap, tado-system).

        ═══════════════════════════════════════════════════════════
        FINISHED?
        ═══════════════════════════════════════════════════════════
        Print which sections were replaced vs. appended in each file. List the topics this \
        project has Dome notes in (run `tado-dome query "" --topic project-\(projectShortIDPlaceholder) --toon --limit 1`). \
        Then STOP. Do NOT start writing notes yourself — that's for the user (and \
        future agents on real tasks) to do as work happens.
        """
    }

    /// Placeholder used inside the knowledge-bootstrap prompt where we want the
    /// running agent to substitute the real project short-id at execution time.
    /// We don't have it at prompt-construction time (the project's UUID hasn't
    /// been deterministically expanded into the 8-char short form here), and
    /// hard-coding a fake one would mislead the agent. Keeping it as a literal
    /// `<shortid>` placeholder keeps the example readable and the agent will
    /// resolve via `tado-list` or env vars.
    private static let projectShortIDPlaceholder = "<shortid>"

    // MARK: - Bootstrap Cowork plugin

    /// One-shot prompt for the agent that installs the bundled
    /// `tado-cowork-plugin` into the user's Claude install. This is
    /// the fifth `Bootstrap …` action; it complements the four
    /// existing ones (A2A, Team, Auto Mode, Knowledge) by extending
    /// the same surface to Claude Cowork running inside the Desktop
    /// app.
    ///
    /// The prompt is engine-agnostic — the spawned agent can be
    /// either Claude Code or Codex; both can shell `claude plugin
    /// install`. The prompt instructs the agent to run the install
    /// + smoke-test the result + report back, then exit. No code
    /// changes, no project mutations.
    static func bootstrapCoworkPluginPrompt(
        projectName: String,
        projectRoot: String
    ) -> String {
        """
        You are bootstrapping the bundled `tado-cowork-plugin` into the user's Claude \
        install. After this runs, Claude Cowork (and any Claude Code session) will see \
        Tado's full 71-tool MCP surface (16 `tado_*` + 18 `dome_*` + 41 `tado_use_*`) \
        plus a teaching skill (`cowork-tado-tools`) and an agent persona \
        (`cowork-canvas-coworker`). Project: "\(projectName)" at \(projectRoot).

        ═══════════════════════════════════════════════════════════
        WHY THIS MATTERS
        ═══════════════════════════════════════════════════════════
        Tado's Eternal/Dispatch architects, the canvas tiles, and Tado Use already drive \
        the same MCP surface from Claude Code's side. Cowork — the desktop-first \
        knowledge-work coworker that ships inside the Claude Desktop app — has no CLI \
        binary; the only way to give it the same tool surface is via the plugin model. \
        This bootstrap closes the parity gap so Cowork can sit on top of an active \
        Tado canvas as a long-form planning surface, delegating executable work to \
        running Code/Codex tiles via `tado_send`.

        ═══════════════════════════════════════════════════════════
        WHAT TO DO
        ═══════════════════════════════════════════════════════════
        1. Verify the `claude` CLI is on PATH:
             Bash: `claude --version`
           If it errors, tell the user "Claude Code CLI not found — install from \
           https://code.claude.com/docs/en/setup before running this bootstrap" and stop.

        2. Resolve the bundled plugin path. Tado's installer looks for the plugin tree \
           at one of these paths in order:
             a. `Tado.app/Contents/Resources/tado-cowork-plugin/` (production)
             b. `<repo>/tado-core/crates/tado-cowork-plugin/` (dev)
           Use whichever exists. If neither exists, tell the user "tado-cowork-plugin \
           tree not found — Tado.app may be incomplete or `make plugin` hasn't run yet" \
           and stop.

        3. Register the local marketplace + install the plugin:
             Bash: `claude plugin marketplace add <plugin-path>`
             Bash: `claude plugin install tado-cowork-plugin@tado-local`

           The first command is idempotent — re-running it on an existing tado-local \
           marketplace just refreshes the path. The second installs the plugin if not \
           already enabled; it's a no-op otherwise.

        4. Verify install:
             Bash: `claude plugin list`
           Confirm `tado-cowork-plugin@tado-local` appears in the output.

        5. Smoke-test the MCP surface (optional but informative):
             Bash: `claude --plugin-dir <plugin-path> -p "Run dome_recipe_apply with intent_key=architecture-review and tell me how many citations came back."`
           This proves Cowork (and any other Claude Code session) can reach the plugin's \
           MCP servers. If it errors, the most common cause is a stale `dome` token — \
           tell the user to open Tado's Settings → Knowledge → Agent tokens and copy \
           a fresh one.

        6. Tell the user the plugin is installed, then exit. Do NOT modify any files in \
           \(projectRoot) — this bootstrap is purely about registering the plugin with \
           Claude.

        ═══════════════════════════════════════════════════════════
        WHAT NOT TO DO
        ═══════════════════════════════════════════════════════════
          • Do NOT edit `~/.claude/settings.json` or `~/.claude/plugins/` directly. The \
            `claude plugin` CLI does the right thing; bypassing it leaves stale state.
          • Do NOT attempt to install the plugin into anything other than the user's \
            Claude install. The plugin is meant for Claude Cowork (and Claude Code as a \
            consequence); it doesn't make sense for Codex.
          • Do NOT start an Eternal/Dispatch run with `engine = cowork`. Cowork has no \
            PTY-attached output and the perf/sprint Stop-hook contract can't fire \
            against it. The Eternal modal already filters Cowork out of the engine \
            picker; agents that hand-edit state.json will see clear error messages \
            from `EternalService.startWorker`.
          • Do NOT skip the `claude --version` preflight. The plugin install commands \
            silently no-op when the CLI isn't installed, which is the worst possible \
            failure mode.
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
        STEP 9 — WRITE crafted.md FOR HUMAN REVIEW
        ═══════════════════════════════════════════════════════════
        Write a human-reviewable plan summary to \(runDir)/crafted.md (this is what \
        the user opens in Tado's Plan Review modal — keep it scannable, not exhaustive). \
        Use this EXACT section structure so the modal's left-side index renders cleanly:

        ```
        # Dispatch — \(projectName)

        ## Brief
        <2–4 sentence restatement of the user's request, in your own words, as you \
        understood it. Surface anything that was ambiguous and how you resolved it.>

        ## Plan summary
        - Total phases: <N>
        - Skills authored: dispatch-<projectslug>-\(runID.uuidString.prefix(8))-phase-1 … phase-N
        - Agents assigned: <list of agent names used>
        - Estimated total wall-clock: <rough order-of-magnitude>

        ## Phase 1: <title>
        - **Skill:** <skill name>
        - **Agent:** <agent name>
        - **Engine:** <claude|codex>
        - **Goal:** <one sentence>
        - **Outputs:** <files / artifacts / state changes this phase produces>

        ## Phase 2: <title>
        … (one section per phase, in execution order) …

        ## Risks & assumptions
        - <bulleted list — anything that could derail the chain, dependencies on \
          external state, things you assumed without being able to verify>

        ## Acceptance criteria
        - <bulleted list — what "this dispatch is done" looks like, the signals the \
          user can check after the last phase completes>
        ```

        Rules:
          - Sections in `## ` form become sidebar entries in Tado's review modal. Do not \
            invent new top-level sections — keep to the schema above.
          - Use sub-headings (`### `) freely inside Phase sections if you need to call \
            out implementation notes; they render but do not appear in the sidebar.
          - Prose. Not JSON. Not a literal copy of plan.json. The user is reading this \
            to decide whether to approve the plan, not to debug it.
          - Inline backticks for paths and identifiers. Fenced code blocks for any \
            literal commands or schemas you reference.

        ═══════════════════════════════════════════════════════════
        STEP 9b — FINISH AND STOP
        ═══════════════════════════════════════════════════════════
        Print a concise human-readable summary in your terminal:
          - Total phases
          - Each phase's order, title, skill, agent, engine
          - Absolute path to plan.json AND crafted.md
          - The exact command the user's Accept button will run (for transparency)

        Then STOP. Do NOT launch phase 1. Do NOT tado-deploy. Do NOT tado-send. The user \
        opens Tado's Plan Review modal next; once they click Accept, phase 1 spawns.

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

    // MARK: - Coordinator (natural-language todo)

    /// System prompt for a coordinator tile spawned from the
    /// general todo page when the user types `tado <brief>`. The
    /// agent inside this tile is not a worker — it's a CLI driver
    /// that interprets the user's natural-language intent, calls
    /// the right Tado CLI(s), supervises any architect through the
    /// human-review gate, accepts on the user's behalf, and
    /// exits.
    ///
    /// The prompt names every CLI it expects to use and gives
    /// concrete worked examples for the most common intents
    /// (Eternal, Dispatch, bootstraps, agent deployment, status
    /// queries). The 15-minute supervision rule baked into
    /// section 5 is the user's literal instruction: wait, check,
    /// nudge, re-prompt, accept-or-give-up.
    static func coordinatorPrompt(brief: String, todoID: UUID) -> String {
        let todoIDStr = todoID.uuidString
        return """
        You are the Tado Coordinator. The user is away from the keyboard and \
        typed a natural-language todo on the general todo page. They are \
        trusting you to interpret it, drive the right Tado feature(s) end-to-\
        end via Tado's CLI tools, supervise any architect through the human-\
        review gate, accept the review on their behalf, and exit cleanly. \
        You are the user's hands while they're offline.

        Your tile id (the coordinator todo's UUID — pass this to every CLI \
        that needs `--coordinator-todo-id`):

          \(todoIDStr)

        ═══════════════════════════════════════════════════════════
        THE USER'S BRIEF (verbatim — your source of truth)
        ═══════════════════════════════════════════════════════════
        <<<USER_BRIEF
        \(brief)
        USER_BRIEF>>>

        ═══════════════════════════════════════════════════════════
        YOUR TOOLBOX — the only commands you should run
        ═══════════════════════════════════════════════════════════
        Every command below is on $PATH (`~/.local/bin/`). They emit JSON \
        on stdout by default. Pass `--toon` for compact AXI-style output \
        when context is tight; `--human` for pretty-printed JSON.

        # Project resolution
        tado-projects list
        tado-projects resolve <name>
            -> exits 1 with `error [no_match]` if the name doesn't match.
               Try the substring of the name the user typed; if ambiguous,
               `tado-projects list` and pick.

        # Eternal lifecycle (long-running single-agent loops; mega or sprint)
        tado-eternal propose --project <name> --feature <feature> \\
                             --task "<text>" [--mode mega|sprint] \\
                             [--engine claude|codex] \\
                             --coordinator-todo-id \(todoIDStr) [--label <text>]
            -> returns {run_id, project_id, project_name, label, mode, engine, state}
        tado-eternal status <run_id>
            -> returns {state, mode, engine, has_crafted, is_active, ...}
        tado-eternal crafted <run_id>
            -> returns {run_id, state, crafted}; only succeeds when has_crafted
        tado-eternal accept <run_id> [--note "<one-paragraph rationale>"]
            -> ok on accept; error code `state_mismatch` if the human
               accepted manually first
        tado-eternal reject <run_id> --reason "<text>" [--rebrief "<new brief>"]
            -> archives crafted.md, optionally rewrites user-brief.md,
               re-spawns the architect
        tado-eternal stop <run_id>
            -> writes stop-flag; the next loop iteration exits cleanly
        tado-eternal list [--project <name>] [--state <state>]
            -> JSON list of every run; useful for sanity-checking before
               proposing a duplicate

        # Dispatch lifecycle (one-shot multi-phase plan)
        tado-dispatch propose --project <name> --feature <feature> \\
                              --task "<text>" \\
                              --coordinator-todo-id \(todoIDStr) [--label <text>]
        tado-dispatch status <run_id>
        tado-dispatch crafted <run_id>
        tado-dispatch accept <run_id> [--note "<text>"]
        tado-dispatch reject <run_id> --reason "<text>" [--rebrief "<text>"]
        tado-dispatch list [--project <name>] [--state <state>]

        # Bootstraps (one-shot project setup; no review gate)
        tado-bootstrap a2a       --project <name>
        tado-bootstrap team      --project <name>
        tado-bootstrap auto-mode --project <name>
        tado-bootstrap knowledge --project <name>

        # System / vault status
        tado-system status   # pid, version, storage_root, vault_path, vault_exists
        tado-system vault    # vault_path + vault_exists only

        # Generic agent deployment (existing — for one-off jobs that don't
        # need an architect/review gate)
        tado-deploy "<prompt>" --project <name> [--agent <name>] \\
                               [--team <name>] [--engine claude|codex]

        # Tile inspection (existing) — useful for supervising a spawned architect
        tado-list [--project <name>] [--toon]
        tado-read <target> [--tail N]
        tado-send <target> <message>
        tado-broadcast --project <name> "<message>"

        # User-facing messaging (the user is offline — this is how they hear from you)
        tado-notify send "<title>" --body "<text>" --severity info|success|warning|error

        # Knowledge / memory (audit trail)
        tado-memory append --scope project --tags coordinator,<verb> "<one-line note>"
        tado-dome register --topic project-<shortid> --note "<markdown>"

        # Settings / events (rarely useful — usually read-only)
        tado-config get|set|list <scope> [<key>] [<value>]
        tado-events query [filter] [--limit N]

        ═══════════════════════════════════════════════════════════
        COMMON INTENTS — worked examples
        ═══════════════════════════════════════════════════════════
        Below are six shapes the user's brief usually takes. Pattern-match \
        the brief to one (or compose them — "trigger an eternal AND notify \
        me" is propose + tado-notify on completion).

        1) "Trigger an Eternal sprint on <project> for <feature> to do <task>"
           -> `tado-projects resolve <project>` (capture rootPath)
           -> `tado-eternal propose --project <project> --feature <feature> \\
                --task "<task>" --mode sprint --coordinator-todo-id \(todoIDStr)`
           -> read `run_id` from the response
           -> follow the architect-supervision rule (section 5)
           -> read `tado-eternal crafted <run_id>`, run the review checklist
              (section 6), accept or reject
           -> emit a final `tado-notify` and exit

        2) "Trigger Dispatch on <project> to do <task>"
           -> same shape, swap the verb to `tado-dispatch propose ...`
           -> phases run automatically after accept; the coordinator does
              NOT babysit phase tiles

        3) "Bootstrap A2A docs on <project>" (no review gate)
           -> `tado-bootstrap a2a --project <project>`
           -> `tado-list --project <project> --toon` to find the spawned
              bootstrap tile id; `tado-read <tile-id>` until the agent
              prints completion (or a clear error)
           -> `tado-notify` with the outcome and exit

        4) "Spawn <agent-name> on <project> to do <task>" (no review gate)
           -> `tado-deploy "<task>" --project <project> --agent <agent-name>`
           -> exit immediately; the deployed agent will tado-send back if
              it has results to report

        5) "What's running on <project>?" / "Status check"
           -> `tado-list --project <project> --toon`
           -> optionally `tado-eternal list --project <project>` and
              `tado-dispatch list --project <project>` for run-state context
           -> `tado-notify` with a one-paragraph summary; exit

        6) "I don't understand what you want" — when the brief is too vague:
           -> Don't guess. `tado-notify` with "couldn't determine which Tado
              feature you wanted; please type a more specific todo.
              Examples: 'tado run an eternal sprint on X to do Y'."
           -> Exit. Do NOT spawn anything.

        ═══════════════════════════════════════════════════════════
        ARCHITECT SUPERVISION RULE (the user's literal instruction)
        ═══════════════════════════════════════════════════════════
        After `tado-eternal propose` or `tado-dispatch propose` returns a \
        `run_id`, the architect tile is spawning. You wait, then check, \
        then nudge if needed, with strict bounds:

        1. Sleep 15 minutes: `sleep 900`
        2. Check: `tado-eternal status <run_id>` (or dispatch). Branch:

           a. state == "awaitingReview"
              -> The architect is done. `tado-eternal crafted <run_id>`,
                 run the review checklist (section 6), accept or reject.

           b. state == "planning" (still working)
              -> `tado-list --toon` to find the architect tile id.
                 `tado-read <architect-tile-id> --tail 100`.
                 If the output is healthy (recent progress, no obvious
                 errors): sleep ANOTHER 15 minutes, then re-check.
                 If the output shows an error or has been silent for
                 over 5 minutes: `tado-send <architect-tile-id>
                 "the user is waiting; please describe blockers
                 concretely or finalize crafted.md"`. Then sleep 15 more.
                 Cap nudges at 3 (so total wait is ~60 minutes max
                 from initial propose).

           c. state == "stopped" / "failed" / "completed"
              -> Architect died unexpectedly. `tado-notify` with a
                 diagnosis pulled from the architect tile's tail.
                 Exit. Do NOT propose a new run automatically — the
                 user can decide whether to retry when they return.

        3. If `tado-system status` shows the app unresponsive, or any \
           Tado CLI fails outright (returns non-zero with no JSON \
           response), the process is fundamentally broken. Emit a clear \
           `tado-notify` diagnosis and EXIT. The user is offline; they \
           will restart the app when they return.

        ═══════════════════════════════════════════════════════════
        REVIEW CHECKLIST — what makes crafted.md acceptable
        ═══════════════════════════════════════════════════════════
        When `tado-eternal crafted <run_id>` (or dispatch) returns the \
        plan, decide accept-or-reject by checking ALL of:

        - The plan addresses the user's task verbatim. NOT a generic
          version of the user's task. NOT "implement OAuth2" when the
          user asked for "implement OAuth2 with refresh tokens".
        - For Eternal sprints: there's a clear sprint plan and a done
          marker. For Mega: there's a coherent long-running goal.
          For Dispatch: 4-10 phases, each with a single responsibility,
          each with explicit inputs and outputs.
        - No obvious gaps: testing/verification phase exists where it
          should; rollback considered for risky changes.
        - Phase prompts mention the project's actual stack (language,
          runtime, package manager). If you can `cat <root>/CLAUDE.md`,
          spot-check that the plan respects its conventions.

        If acceptable: `tado-eternal accept <run_id> --note "<paragraph>"`. \
        The note persists to `<run-dir>/review-note.md` and shows in \
        Cross-Run Browser — write a one-paragraph rationale: what the \
        plan does, what you liked, what you'd watch for.

        If not acceptable: `tado-eternal reject <run_id> --reason "<concrete>" \
        --rebrief "<refined brief>"`. The architect re-spawns with the new \
        brief; loop back to section 5. CAP REBRIEFS AT 1 — if the second \
        crafted.md is still wrong, accept the closest version with a note \
        flagging the gap, OR `tado-notify` and exit (your call based on \
        how badly the plan misses the brief).

        ═══════════════════════════════════════════════════════════
        ACCEPTANCE AND EXIT
        ═══════════════════════════════════════════════════════════
        Once you accept, the worker tile spawns automatically. Eternal \
        workers can run for hours or days; Dispatch chains phases via \
        `tado-deploy` handoffs. You do NOT babysit either. Your job ends \
        at acceptance.

        Final exit:
          1. `tado-notify send "Coordinator done: <one-line summary>" \\
              --body "<two-paragraph summary of what you did>" \\
              --severity success`
          2. `tado-memory append --scope project --tags coordinator,<verb> \\
              "Coordinator accepted run <run_id>: <one-line>"`
          3. Print a final paragraph to your own terminal explaining what \
             happened (audit trail in the tile's log).
          4. Stop. Do not re-run anything.

        ═══════════════════════════════════════════════════════════
        FAILURE MODES — when something goes wrong
        ═══════════════════════════════════════════════════════════
        - `tado-projects resolve` returns `no_match`:
            -> `tado-projects list` to see what exists, suggest the
               closest match in a `tado-notify` and exit. Do NOT pick
               a wrong project.

        - The brief is too vague to act on:
            -> `tado-notify` "couldn't determine your intent; please
               retype with the project name and verb you want", exit.

        - `state_mismatch` on accept (the human accepted in the modal
          before you got there):
            -> Read the error data; you'll see actual=running. Log it,
               `tado-notify "human accepted manually before coordinator
               finished review"`, exit cleanly. Do NOT try to revert.

        - App not responding (CLI exits with "Tado is not running"):
            -> `tado-notify` with the diagnosis, exit. The user will
               restart the app when they return.

        ═══════════════════════════════════════════════════════════
        NEVER DO THESE
        ═══════════════════════════════════════════════════════════
        - Don't invent CLI flags or commands not listed in section 3.
        - Don't bypass the review gate (always `tado-eternal crafted`
          BEFORE `tado-eternal accept`; read the plan, then decide).
        - Don't loop indefinitely — bounded to 3 architect nudges and
          1 rebrief. Beyond that, accept-or-exit.
        - Don't modify project files directly. The CLIs are the only
          legitimate way to mutate Tado state.
        - Don't hand-edit `.tado/eternal/runs/<uuid>/state.json` or any
          on-disk run artifact. Use `tado-eternal accept|reject|stop`.
        - Don't spawn other coordinators (no recursion). If the brief
          asks for parallel work, run the CLIs in sequence yourself.

        ═══════════════════════════════════════════════════════════
        AUDIT AND REPORTING
        ═══════════════════════════════════════════════════════════
        At every key transition, print a plain-text paragraph into \
        your own terminal explaining what you just did and why. The \
        tile's log is the audit trail — make it readable. Examples:

          "Parsed brief as: trigger an eternal sprint on project tado
           for the auth feature, task='implement OAuth2 with refresh tokens'."

          "Resolved project 'tado' -> /Users/miguel/Documents/tado.
           Calling tado-eternal propose with --mode sprint."

          "Architect produced crafted.md after 28 minutes. Plan has 5
           sprint phases ending with the standard ETERNAL-DONE marker.
           Phases address the OAuth2 task verbatim and reference the
           existing token-store at Sources/Auth/. Accepting."

          "Accepted run \(todoIDStr.prefix(8)). Worker tile spawning.
           Coordinator exiting."

        Begin work now. Read the brief above carefully, identify which \
        intent shape it fits, run the appropriate CLIs.
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

    /// Shell command that launches an INTERACTIVE `claude --permission-mode auto`
    /// session — used for Eternal's internal loop kind, which keeps ONE
    /// session alive for the whole run instead of respawning `claude -p`
    /// every turn.
    ///
    /// There is no wrapper script: the PTY runs `claude` directly. The
    /// initial eternal prompt is fed in through Tado's prompt-queue
    /// mechanism (it types as if the user typed) once the TUI becomes
    /// idle. Continuation after the first turn is driven by two layers:
    ///   1. Tado's idle-detection injecting a "continue" prompt every
    ///      time `TerminalSession.status == .needsInput`.
    ///   2. A `/loop 30s <continue>` command typed once after the first
    ///      turn completes — Claude Code's own scheduler fires it on
    ///      its interval as a backup driver.
    ///
    /// `--permission-mode auto` is load-bearing: without auto mode, the
    /// session would stall on any tool-permission prompt. Auto mode
    /// replaces the old `--dangerously-skip-permissions` hack.
    ///
    /// **Model and effort are threaded through explicitly.** Without this,
    /// `claude` with no `--model`/`--effort` picks up the user's
    /// `~/.claude/settings.json` defaults, so Tado's model/effort picker
    /// silently didn't apply to internal-mode workers. Both values are
    /// `shellEscape`d so the brackets in `opus[1m]` survive zsh parsing
    /// (raw `opus[1m]` would hit `nomatch` and abort before `claude` ran).
    static func internalEternalCommand(
        projectRoot: String,
        modelID: String?,
        effortLevel: String?
    ) -> (executable: String, args: [String]) {
        _ = projectRoot
        var parts: [String] = [
            "claude",
            "--permission-mode", "auto",
            "--setting-sources", "user,project,local",
        ]
        if let modelID, !modelID.isEmpty {
            parts.append("--model")
            parts.append(shellEscape(modelID))
        }
        // `"auto"` is the same skip-the-flag sentinel honored by
        // `ClaudeEffort.cliFlags` and `eternalWorkerEnv` (see :1769). The
        // CLI rejects `--effort auto` with "must be one of: low, medium,
        // high, xhigh, max" — this guard is the missing twin of that one.
        if let effortLevel, !effortLevel.isEmpty, effortLevel != "auto" {
            parts.append("--effort")
            parts.append(shellEscape(effortLevel))
        }
        let inner = parts.joined(separator: " ")
        return ("/bin/zsh", ["-l", "-c", inner])
    }

    /// Codex's analog of `internalEternalCommand` for Continuous-mode
    /// Eternal runs. Spawns ONE interactive `codex` session that stays
    /// alive for the whole run. The session is driven by Tado's idle
    /// injection (the same primary driver that ticks Claude internal
    /// mode); there is no Codex equivalent of Claude Code's `/loop`
    /// scheduler, so the secondary backup driver is omitted (see
    /// `TerminalSession.refillQueueForInternalEternalIfNeeded` — it
    /// gates the `/loop` typing on engine).
    ///
    /// The flags come pre-bundled from
    /// `EternalService.spawnWorker` (which assembles
    /// `codexEmbedShim + eternalCodexPermissionFlags` as the pre-flags
    /// and `codexModel.cliFlags + codexEffort.cliFlags` as the post-
    /// flags) so the caller doesn't have to know Codex's flag layout.
    static func internalCodexEternalCommand(
        projectRoot: String,
        codexPreFlags: [String],
        codexPostFlags: [String]
    ) -> (executable: String, args: [String]) {
        _ = projectRoot
        var parts: [String] = ["codex"]
        // Sanitize each phase independently so a `-c key="auto"` payload
        // (or any future literal-"auto" foot-gun) is dropped before the
        // codex invocation is composed. Mirrors the safety net in
        // `command(for:engine:...)` for one-shot tile spawns.
        parts.append(contentsOf: sanitizeFlags(codexPreFlags).map(shellEscape))
        parts.append(contentsOf: sanitizeFlags(codexPostFlags).map(shellEscape))
        let inner = parts.joined(separator: " ")
        return ("/bin/zsh", ["-l", "-c", inner])
    }

    /// Env-var dictionary consumed by the eternal-loop wrapper. Merged
    /// with `ProcessSpawner.environment(...)` at spawn time so the
    /// wrapper inherits everything else (Tado IPC, PATH, etc.) AND gets
    /// the eternal-specific knobs.
    ///
    /// Codex runs route through `codexPreFlags` / `codexPostFlags` (already
    /// shell-escaped strings ready to be word-split inside the bash
    /// wrapper). Claude runs continue to use `TADO_MODEL` / `TADO_EFFORT`
    /// for back-compat with hooks that read those names. The wrapper picks
    /// the right path off `$TADO_ENGINE`, which `ProcessSpawner.environment`
    /// already exports from the session's engine choice.
    static func eternalWorkerEnv(
        runID: UUID,
        mode: String,
        doneMarker: String,
        sprintMarker: String = "[SPRINT-DONE]",
        modelID: String?,
        effortLevel: String?,
        skipPermissions: Bool,
        codexPreFlags: [String]? = nil,
        codexPostFlags: [String]? = nil,
        perfMode: Bool = false,
        sprintMode: Bool = false
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
        // Set when EternalRun.kind == "perf". Read by stop.sh and
        // eternal-loop.sh to enforce the [PERF-OK]-before-marker
        // contract, and by the worker prompt to know it should call
        // perf-gate.sh before printing the iteration marker.
        if perfMode {
            env["TADO_PERF_MODE"] = "1"
        }
        if sprintMode {
            env["TADO_SPRINT_MODE"] = "1"
        }
        if let modelID, !modelID.isEmpty {
            env["TADO_MODEL"] = modelID
        }
        // `"auto"` is the same "skip the flag" sentinel that
        // `ClaudeEffort.cliFlags` / `CodexEffort.cliFlags` already honor
        // for one-shot tile spawns. Without this filter the wrapper
        // appends `--effort auto`, which neither CLI accepts (claude:
        // "must be one of: low, medium, high, xhigh, max"; codex same
        // shape minus xhigh) — every iteration aborts in milliseconds.
        if let effortLevel, !effortLevel.isEmpty, effortLevel != "auto" {
            env["TADO_EFFORT"] = effortLevel
        }
        if let codexPreFlags, !codexPreFlags.isEmpty {
            env["TADO_CODEX_PRE_FLAGS"] = codexPreFlags.map(shellEscape).joined(separator: " ")
        }
        if let codexPostFlags, !codexPostFlags.isEmpty {
            env["TADO_CODEX_POST_FLAGS"] = codexPostFlags.map(shellEscape).joined(separator: " ")
        }
        return env
    }

    /// Codex's analog of `eternalPermissionFlags` for non-interactive
    /// Eternal runs: `--ask-for-approval never` + `--sandbox danger-full-access`
    /// give the agent permission to act without prompting, the same way
    /// `--permission-mode auto` does for Claude. These flags are appended
    /// to the codex embed shim by the Eternal pipeline so architect /
    /// worker / interventor tiles never stall on an approval prompt.
    ///
    /// **Interactive only.** The `codex exec` subcommand rejects these
    /// argument names — for exec mode use `eternalCodexExecPreFlags()`
    /// which substitutes the `--dangerously-bypass-approvals-and-sandbox`
    /// shortcut.
    static func eternalCodexPermissionFlags() -> [String] {
        ["--ask-for-approval", "never", "--sandbox", "danger-full-access"]
    }

    /// Pre-prompt flags for the `codex exec` subcommand, used by the
    /// non-interactive Eternal roles (architect, interventor, and the
    /// per-iteration worker invocation in the eternal-loop wrapper).
    ///
    /// `codex exec` bundles "no approval prompts + no sandbox" into the
    /// single `--dangerously-bypass-approvals-and-sandbox` shortcut and
    /// rejects the standalone `--ask-for-approval` / `--sandbox` flags
    /// (and the interactive-only `--no-alt-screen`). Codex 0.125.0
    /// interactive-mode also rejects gpt-5.5 with "newer Codex required"
    /// despite the model being available — that error doesn't reproduce
    /// in `codex exec`, so non-interactive roles route through this flag
    /// set as a side benefit.
    static func eternalCodexExecPreFlags() -> [String] {
        [
            "--dangerously-bypass-approvals-and-sandbox",
            "-c", "shell_environment_policy.inherit=all",
        ]
    }

    /// Build a `codex exec <flags> "<prompt>"` invocation for a one-shot
    /// or per-iteration Eternal role. Mirrors `command(for:engine:...)`
    /// but inserts the `exec` subcommand and skips the
    /// agent-flag injection (Codex doesn't take `--agent`). The `flags`
    /// array is shell-escaped element-wise the same way `command()` does
    /// it so glob-meta characters in model ids survive zsh parsing.
    static func codexExecCommand(
        for prompt: String,
        flags: [String]
    ) -> (executable: String, args: [String]) {
        let escaped = shellEscape(prompt)
        let allFlags = sanitizeFlags(flags).map(shellEscape).joined(separator: " ")
        let cmd = allFlags.isEmpty
            ? "codex exec \(escaped)"
            : "codex exec \(allFlags) \(escaped)"
        return ("/bin/zsh", ["-l", "-c", cmd])
    }

    /// Permission-mode flags for any Eternal-pipeline spawn (architect,
    /// worker, interventor).
    ///
    /// Uses Claude Code's `auto` permission mode, shipped late Apr 2026
    /// (see https://code.claude.com/docs/en/permissions). Auto mode runs
    /// every tool call through an AI classifier that checks reversibility,
    /// scope alignment, risk surface, and cascading effects. Safe calls
    /// auto-approve with no prompt; risky ones still prompt.
    ///
    /// Auto mode replaces `--dangerously-skip-permissions` + the
    /// `bypassPermissions` pair. The critical difference: bypass had a
    /// hard-coded exception list for protected paths (`.git`, `.claude`,
    /// `.vscode`, `.idea`, `.husky`) that STILL prompted. Auto has no
    /// such exception — the classifier decides based on scope, and our
    /// `permissions.allow` settings pre-approve everything bypass used to
    /// prompt on. A live Eternal worker genuinely never halts.
    ///
    /// `--setting-sources=user,project,local` pins which config files
    /// Claude Code loads. Without this, some CLI builds fall back to
    /// user-only sources, skipping the project's `.claude/settings.json`
    /// that Tado merged the Eternal allowlist into.
    ///
    /// `skipPermissions` is vestigial now — auto mode doesn't need the
    /// danger flag. Kept in the signature so callers don't break; the
    /// flag is no longer emitted regardless of the value.
    static func eternalPermissionFlags(skipPermissions: Bool) -> [String] {
        _ = skipPermissions
        return [
            "--permission-mode", "auto",
            "--setting-sources", "user,project,local",
        ]
    }

    /// Prompt for a Mega-mode Eternal worker. Plain text — callers shell-escape
    /// when spawning. The Stop hook picks up context from `state.json` so this
    /// prompt only has to tell the worker what the session IS, not how it loops.
    ///
    /// `engine` tailors the closing "non-stop hygiene" paragraph: Claude gets
    /// the `.claude/`-protected-path warning that's specific to its bypass
    /// flag; Codex (which uses `--ask-for-approval never --sandbox
    /// danger-full-access`) doesn't have that foot-gun and gets a Codex-flavored
    /// reminder instead.
    static func eternalMegaPrompt(
        projectName: String,
        projectRoot: String,
        marker: String,
        runID: UUID,
        engine: TerminalEngine = .claude,
        perfMode: Bool = false,
        sprintMode: Bool = false
    ) -> String {
        let runDir = "\(projectRoot)/.tado/eternal/runs/\(runID.uuidString)"
        let perfStep = perfMode ? eternalPerfStepBlock(runDir: runDir, marker: marker, sprintMarker: nil) : ""
        let sprintStep = sprintMode ? eternalSprintStepBlock(runDir: runDir, marker: marker, sprintMarker: nil) : ""
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
        \(perfStep)
        \(sprintStep)

        \(eternalNonStopHygiene(engine: engine, runDir: runDir))
        """
    }

    /// Performance step instructions appended to mega/sprint worker
    /// prompts when `EternalRun.kind == "perf"`. Identical content for
    /// both modes — the only difference is which terminal marker the
    /// worker pairs with [PERF-OK]. Sprint mode passes its sprint
    /// marker too so the prompt names both.
    private static func eternalPerfStepBlock(
        runDir: String,
        marker: String,
        sprintMarker: String?
    ) -> String {
        let pairedMarker = sprintMarker ?? marker
        return """


        ═══════════════════════════════════════════════════════════
        PERFORMANCE STEP (kind=perf — same-turn pay-back required)
        ═══════════════════════════════════════════════════════════
        This run was created with kind=perf. Before you print "\(pairedMarker)" \
        OR "\(marker)" on its own line, you MUST clear the perf gate. The gate \
        is a single bash hook script that runs the project's correctness tests, \
        measures eight curated performance dimensions (algorithmic complexity, \
        allocation count per op, critical-path ops, IO syscalls per op, DB \
        query cost, cross-process roundtrips, cold-start ops, steady-state \
        RSS ratio), and scores against the project's all-time-best baseline at \
        \(runDir)/../../../perf-baselines/<project>.json (auto-detected).

        Per-iteration perf protocol:
          A. Do your work (mega: one unit; sprint: APPLY+EVAL+IMPROVE).
          B. Run: bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
             The gate prints exactly one of these one-liners to stdout:
               "PERF: PASS composite=<n>"          followed by
               "[PERF-OK] composite=<n>"            ← the marker the loop reads
               "PERF: BASELINE-INIT composite=<n>"  followed by [PERF-OK] (first run)
               "PERF: REGRESSION delta=<d> hot=<sub-metric> composite=<n>"
                                                    ← no [PERF-OK] is printed
               "PERF: NO-STACK-DETECTED"            followed by [PERF-OK] (free pass)
               "PERF: CORRECTNESS-FAILED <stack> <error>"
                                                    ← tests broke
          C. If [PERF-OK] appeared: copy that line into your output AND print \
             "\(pairedMarker)" on its own line afterward. The Stop hook + loop \
             driver verify [PERF-OK] precedes "\(pairedMarker)" / "\(marker)".
          D. If [PERF-OK] did NOT appear: you must, IN THIS SAME TURN, either:
               (i)  revert the offending diff with `git revert HEAD --no-edit` \
                    and document the revert reason in progress.md; OR
               (ii) read \(runDir)/perf-proposals.md (auto-generated by the \
                    gate when it detects a regression), apply ONE refactor \
                    proposal, then re-run the gate.
             After the second run, if [PERF-OK] still hasn't printed, append \
             a one-line "regressed perf, will pay back next iter" note to \
             progress.md and DO NOT print "\(pairedMarker)" / "\(marker)" — the \
             external loop driver and the Stop hook both refuse to honor an \
             out-of-order marker, and Tado will block-and-continue with a \
             pay-back nudge.

        Do NOT edit benchmark code in the same iteration where it produces \
        the metric — that's how you fool yourself. Do NOT disable correctness \
        tests to make perf pass. The worker's job is to make code FASTER \
        without making it WRONG.

        See \(runDir)/crafted.md's `## PERFORMANCE` section for the active \
        baseline numbers, the per-component weights, and the project's \
        satisfaction threshold (above which printing "\(marker)" is OK).
        """
    }

    /// Sprint step instructions appended to mega/sprint worker prompts
    /// when `EternalRun.kind == "sprint"`. Mirrors `eternalPerfStepBlock`
    /// but for the SprintSuccessScore gate (sprint-suite + sprint-gate.sh).
    private static func eternalSprintStepBlock(
        runDir: String,
        marker: String,
        sprintMarker: String?
    ) -> String {
        let pairedMarker = sprintMarker ?? marker
        return """


        ═══════════════════════════════════════════════════════════
        SPRINT STEP (kind=sprint — same-turn pay-back required)
        ═══════════════════════════════════════════════════════════
        This run was created with kind=sprint. The methodology under \
        optimization is `sprint_rules.txt` in the project root. Each \
        iteration you propose ONE rule change, edit `sprint_rules.txt`, \
        record a measured row in `sprint-data.json`, then run the gate. \
        The gate computes the SprintSuccessScore via:

          score = (points_completed / total_points_planned * 100)
                + (code_review_passes * 2)
                - (bugs_found_after_sprint * 10)
                + (developer_satisfaction_score * 5)

        and compares it to the all-time-best baseline at \
        `.tado/sprint-baselines/<project>.json`. The baseline is \
        ratcheting — it never moves backwards.

        Per-iteration sprint protocol:
          A. Read \(runDir)/crafted.md's `## SPRINT RULES OPTIMIZATION` \
             section for the active formula, baseline composite, and \
             rules-hygiene constraints.
          B. Propose ONE rule change (add, refine, or retire). Edit \
             `sprint_rules.txt` to apply it. Add or update one row in \
             `sprint-data.json`.
          C. Run: bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/sprint-gate.sh
             Stdout shapes:
               "SCORE: PASS composite=<n>"          followed by
               "[SCORE-OK] composite=<n>"            ← the marker the loop reads
               "SCORE: BASELINE-INIT composite=<n>"  followed by [SCORE-OK] (first run)
               "SCORE: REGRESSION delta=<d> hot=<sub-metric> composite=<n>"
                                                    ← no [SCORE-OK] is printed
               "SCORE: NO-DATA-DETECTED"            followed by [SCORE-OK] (free pass)
          D. If [SCORE-OK] appeared: copy that line into your output AND \
             print "\(pairedMarker)" on its own line afterward. The Stop \
             hook + loop driver verify [SCORE-OK] precedes \
             "\(pairedMarker)" / "\(marker)". `git commit -am "<short \
             rule-change message>"` so the per-rule history is auditable.
          E. If [SCORE-OK] did NOT appear: in this same turn, either \
             (i) revert the diff with `git revert HEAD --no-edit` and \
             document the revert reason in progress.md; OR (ii) read \
             \(runDir)/sprint-proposals.md, apply ONE different proposal, \
             and re-run the gate.

        Do NOT modify `prepare.py` (the scorer) or the formula in the \
        same iteration where it produces the metric. Do NOT inflate \
        `sprint-data.json` rows with unrealistic values to game the gate.

        See \(runDir)/crafted.md's `## SPRINT RULES OPTIMIZATION` \
        section for active baseline, per-component guards (bugs cannot \
        rise; reviews cannot drop), and the satisfaction threshold \
        (above which printing "\(marker)" is OK).
        """
    }

    /// Engine-tailored "non-stop hygiene" closing paragraph for Mega and
    /// Sprint prompts. Claude callers get the `.claude/`-protected-path
    /// warning specific to `--dangerously-skip-permissions`; Codex callers
    /// get the equivalent reminder for `--ask-for-approval never --sandbox
    /// danger-full-access`. Both end with the same "no interactive
    /// dialogs" line.
    private static func eternalNonStopHygiene(engine: TerminalEngine, runDir: String) -> String {
        switch engine {
        case .claude:
            return """
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
        case .codex:
            return """
            ═══════════════════════════════════════════════════════════
            NON-STOP HYGIENE — Codex CLI specifics
            ═══════════════════════════════════════════════════════════
            You're running with `--ask-for-approval never --sandbox \
            danger-full-access`, so file edits and shell commands proceed \
            without prompts. To keep the loop truly non-stop:
              • Do not invoke commands that open an interactive UI (e.g. \
                `vim`, `less`, `git rebase -i`). They block the PTY without \
                a path back. Prefer non-interactive equivalents (`git rebase`, \
                `cat`, the Edit tool).
              • Don't run watch-mode dev servers in the foreground. If you \
                need a server, background it (`& disown`).
              • Prefer writing scratch files under `.tado/scratch/` or \
                `\(runDir)/` so generated content is easy to inspect.
              • Never ask the user a question via the CLI — log it to \
                progress.md and decide.
            """
        case .cowork:
            // Eternal does not support Cowork — Cowork has no PTY, no
            // turn-marker contract, and no headless output capture, so
            // the per-iteration `[SCORE-OK]` / `ETERNAL-DONE` Stop-hook
            // dance can't run. EternalService rejects cowork runs at
            // the architect/worker spawn site. This branch exists for
            // switch-exhaustiveness only.
            return """
            ═══════════════════════════════════════════════════════════
            NON-STOP HYGIENE — Cowork is NOT a supported Eternal engine
            ═══════════════════════════════════════════════════════════
            Eternal runs need a PTY-attached, turn-marker-aware CLI \
            (Claude Code or Codex). Cowork lives inside the Claude \
            Desktop app and has no per-turn output Tado can read, so \
            Sprint / Performance gates can't fire. Stop the run and \
            re-create it with `engine = claude` or `engine = codex`.
            """
        }
    }

    /// Prompt for a Sprint-mode Eternal worker. Each turn = one APPLY → EVAL → IMPROVE \
    /// cycle ending in `sprintMarker`. Only `marker` terminates the session.
    static func eternalSprintPrompt(
        projectName: String,
        projectRoot: String,
        marker: String,
        sprintMarker: String,
        runID: UUID,
        engine: TerminalEngine = .claude,
        perfMode: Bool = false,
        sprintMode: Bool = false
    ) -> String {
        let runDir = "\(projectRoot)/.tado/eternal/runs/\(runID.uuidString)"
        let perfStep = perfMode ? eternalPerfStepBlock(runDir: runDir, marker: marker, sprintMarker: sprintMarker) : ""
        let sprintStep = sprintMode ? eternalSprintStepBlock(runDir: runDir, marker: marker, sprintMarker: sprintMarker) : ""
        let evalLine = perfMode
            ? "2. EVAL    — run the evaluation from the TASK/EVALUATE sections AND `bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh`. Read the gate's output. Append one line to\n                       \(runDir)/metrics.jsonl in this exact shape, with `metric` set to the perf composite and `components` carrying every per-dimension normalized score:\n                       {\"sprint\": N, \"timestamp\": \"<iso>\", \"metric\": <perf-composite-or-task-metric>, \"components\": {\"algo_complexity\": ..., \"alloc_per_op\": ...}, \"note\": \"<one-liner>\"}"
            : "2. EVAL    — run the evaluation from the TASK/EVALUATE sections. Append one line to\n                       \(runDir)/metrics.jsonl in this exact shape:\n                       {\"sprint\": N, \"timestamp\": \"<iso>\", \"metric\": <number-or-short-string>, \"note\": \"<one-liner>\"}"
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
          \(evalLine)
          3. IMPROVE — read the last 5 lines of metrics.jsonl. Decide what to change next, guided by
                       the IMPROVE section. Write your plan as ONE short line in
                       \(runDir)/progress.md.

        Then output exactly \(sprintMarker) on its own line. A Stop hook starts the next sprint.

        There is no natural end. The session exits only when:
          (a) The metric is clearly satisfactory and you output "\(marker)" on its own line.
          (b) The user presses Stop in Tado.

        Don't ask clarifying questions — decide and proceed.
        Don't summarise at the end of turns — metrics.jsonl and progress.md are the summary.
        \(perfStep)
        \(sprintStep)

        \(eternalNonStopHygiene(engine: engine, runDir: runDir))
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
    ///
    /// `engine` tailors the "Hard rules" the architect bakes into
    /// crafted.md so a Codex worker doesn't get told to obey
    /// Claude-Code-specific bypass-mode foot-guns.
    static func eternalArchitectPrompt(
        projectName: String,
        projectRoot: String,
        mode: String,
        runID: UUID,
        engine: TerminalEngine = .claude,
        kind: String = "general"
    ) -> String {
        let isSprint = (mode == "sprint")
        let isPerf = (kind == "perf")
        let isSprintKind = (kind == "sprint")
        let runDir = "\(projectRoot)/.tado/eternal/runs/\(runID.uuidString)"
        let perfBriefAddendum = isPerf ? eternalPerfArchitectAddendum(projectName: projectName, projectRoot: projectRoot, runDir: runDir, isSprint: isSprint) : ""
        let sprintBriefAddendum = isSprintKind ? eternalSprintArchitectAddendum(projectName: projectName, projectRoot: projectRoot, runDir: runDir, isSprintMode: isSprint) : ""

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
        STEP 0.5 — QUERY DOME FOR PRIOR ART (IF AVAILABLE)
        ═══════════════════════════════════════════════════════════
        If the `dome` MCP server is registered (check via `/mcp` in \
        Claude Code, or try calling `dome_search` directly — the tool \
        is a no-op in error-tolerant mode if not wired up), run:

          dome_search("\(projectName) architect prior art", limit=5)
          dome_search("\(projectName) sprint retro", limit=5)
          dome_search("\(projectName) metric evaluation", limit=5)

        These queries pull any prior sprints' retros, architect \
        outputs, and metric evaluations stored by previous Eternal runs \
        on this project. If Dome returns hits, read them via `dome_read` \
        and weave the insights into your TASK / EVALUATE / IMPROVE \
        sections — especially the IMPROVE ladder, where knowing which \
        knobs plateaued last time saves the worker many iterations.

        If Dome returns zero hits (first run on this project, or Dome \
        isn't registered), proceed without it — the spec still has to \
        stand on its own. Your goal is to be informed by history when \
        history exists, not blocked by its absence.

        \(perfBriefAddendum)
        \(sprintBriefAddendum)
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
        Once crafted.md lands on disk, Tado flips the run to REVIEW state and \
        the user opens the Plan Review modal. They click Accept (worker spawns) \
        or Re-plan (you respawn with their feedback in user-brief.md).

        ═══════════════════════════════════════════════════════════
        MANDATORY RULES YOU MUST INCLUDE IN crafted.md's "Hard rules"
        ═══════════════════════════════════════════════════════════
        Include these exact rules verbatim — they are the difference between \
        a truly non-stop loop and one that stalls or drifts:

        \(eternalArchitectHardRules(engine: engine, runDir: runDir))

        These rules go in the "Hard rules" section of crafted.md. Don't \
        paraphrase — paste them roughly verbatim so the worker can't \
        misinterpret them after a compaction.
        """
    }

    /// Performance Brief Addendum prepended to the architect prompt
    /// when `EternalRun.kind == "perf"`. Tells the architect to
    /// auto-detect the project's stack via `perf-suite detect`, read
    /// `bench/PERF_KNOBS.md` for the universal IMPROVE ladder, and
    /// produce a `## PERFORMANCE` section in crafted.md with the
    /// project's baseline numbers, the eight default component weights,
    /// and the satisfaction threshold above which printing
    /// `ETERNAL-DONE` is OK. The block is appended to the generic
    /// architect prompt — the mode section (sprint or mega) handles
    /// the rest of the structure.
    private static func eternalPerfArchitectAddendum(
        projectName: String,
        projectRoot: String,
        runDir: String,
        isSprint: Bool
    ) -> String {
        let modeNote = isSprint
            ? "Each sprint's TASK should drive ONE knob from the IMPROVE ladder. EVALUATE invokes perf-gate.sh and stores the composite + per-component scores into metrics.jsonl. IMPROVE re-reads the last 5 metric lines + perf-proposals.md and picks the next knob."
            : "Mega's checklist should be ordered by IMPROVE ladder rung — safest (Rung 0 measurement hygiene) first, most structural (Rung 7 algorithm swap) last. Each checklist item ends in a perf-gate.sh invocation that must clear before ticking the box."
        return """

        ═══════════════════════════════════════════════════════════
        PERFORMANCE STEP MODE — additional architect responsibilities
        ═══════════════════════════════════════════════════════════
        This run was created with kind=perf. The user wants performance \
        as optimized as possible always in all cases. Your crafted.md \
        must include a `## PERFORMANCE` section that the worker reads \
        every iteration. Follow this protocol:

        STEP P0 — Auto-detect the project's stack:
          bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh — \
          on first invocation it detects the stack via `perf-suite \
          detect` and writes `\(runDir)/perf-report.json`. Run this \
          ONCE during your architect pass to learn what stack you're \
          designing for (rust / swift / node / python / go / polyglot).

        STEP P1 — Read \(projectRoot)/bench/PERF_KNOBS.md (if it \
          exists) for the universal IMPROVE ladder + EVAL stencils per \
          stack. If the file is missing in this project, fall back to \
          the in-prompt summary at the end of this addendum.

        STEP P2 — Add a `## PERFORMANCE` section to crafted.md with:
          • **Stack:** (from STEP P0)
          • **EVAL stencil:** the exact bash command sequence (per the \
            stack's stencil) the worker uses each iteration. This must \
            include a literal call to `bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh` \
            and instructions to copy the resulting `[PERF-OK] composite=<n>` \
            line into the iteration's output.
          • **Default weights:** the 8 dimensions and their weights \
            (algo_complexity 0.18, alloc_per_op 0.12, critical_path_ops \
            0.12, io_syscalls_per_op 0.10, db_query_cost 0.10, \
            xproc_roundtrips 0.10, cold_start_ops 0.13, \
            steady_state_rss_ratio 0.15). If a dimension is irrelevant \
            to this project (e.g. db_query_cost on a project with no DB), \
            note that explicitly so the worker doesn't fight ghost regressions.
          • **Satisfaction threshold:** the composite score above which \
            the worker may print `ETERNAL-DONE` (default: 1.5 — i.e. \
            50% above the all-time baseline). Tune per project.
          • **Mode hint:** \(modeNote)

        STEP P3 — Add to the `## Hard rules` section (verbatim):
          • Never edit benchmark code in the same iteration where it \
            produces the metric — that's how you fool yourself.
          • Never disable correctness tests to make perf pass. The \
            perf gate runs tests FIRST; if tests fail it refuses to \
            score and emits `PERF: CORRECTNESS-FAILED`.
          • Never print `\(isSprint ? "[SPRINT-DONE]" : "ETERNAL-DONE")` \
            without `[PERF-OK]` already present in the same turn's \
            transcript. The Stop hook + external loop driver both \
            refuse out-of-order markers.

        UNIVERSAL IMPROVE LADDER (rungs to recommend in IMPROVE \
        section, ordered safest → most structural):
          Rung 0  Measurement hygiene  (warmup, baseline lock, deterministic input)
          Rung 1  Algorithmic          (Big-O reductions, drop redundant work, hoist invariants)
          Rung 2  Allocation           (pre-size buffers, reuse, arena/SmallVec, drop clones)
          Rung 3  Data layout          (struct-of-arrays, cache-line packing)
          Rung 4  Concurrency          (parallel iter, batching, off the hot path)
          Rung 5  Caching/memoization  (LRU, interning, lazy compute)
          Rung 6  IO / syscall         (vectored writes, buffered IO, batching)
          Rung 7  Structural           (replace algorithm family, swap data structure, codegen)

        EVAL STENCILS (pick the one that matches the detected stack — \
        every command must end with a perf-gate.sh invocation):
          rust   →  cargo bench [--bench <name>] && bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
          swift  →  swift test --filter '*Bench*' && bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
          node   →  npx vitest bench --run && bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
          python →  pytest --benchmark-only && bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
          go     →  go test -bench=. -benchmem ./... && bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
          generic→  hyperfine '<entry-cmd>' --warmup 3 && bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh

        """
    }

    /// Architect addendum injected when `EternalRun.kind == "sprint"`.
    /// Tells the architect to seed sprint_rules.txt (methodology under
    /// optimization), sprint-data.json (measured outcome rows), and a
    /// reference prepare.py scorer; then write a `## SPRINT RULES
    /// OPTIMIZATION` section in crafted.md.
    private static func eternalSprintArchitectAddendum(
        projectName: String,
        projectRoot: String,
        runDir: String,
        isSprintMode: Bool
    ) -> String {
        let modeNote = isSprintMode
            ? "Each sprint's TASK should drive ONE rule change in sprint_rules.txt. EVALUATE invokes sprint-gate.sh and stores the SprintSuccessScore + per-component contributions into metrics.jsonl. IMPROVE re-reads the last 5 metric lines + sprint-proposals.md and picks the next rule to refine, retire, or add."
            : "Mega's checklist should be ordered by rules-impact stratum — safest (hygiene, retire stale rules) first, most structural (introduce new ceremonies) last. Each checklist item ends in a sprint-gate.sh invocation that must clear before ticking the box."
        return """

        ═══════════════════════════════════════════════════════════
        SPRINT STEP MODE — additional architect responsibilities
        ═══════════════════════════════════════════════════════════
        This run was created with kind=sprint. The user wants their \
        sprint methodology turned into an engineering discipline with \
        measurable improvement per iteration. Your crafted.md must \
        include a `## SPRINT RULES OPTIMIZATION` section.

        STEP S0 — Seed the optimization artifacts in the project root:
          1. `\(projectRoot)/sprint_rules.txt` — the methodology under \
             optimization. If it exists, leave it alone. If not, write \
             a baseline of 4–6 rules covering planning, in-sprint \
             discipline, code review, retro hygiene.
          2. `\(projectRoot)/sprint-data.json` — measured outcomes per \
             sprint. Either array of objects or single object. Each \
             object has: tickets_completed, points_completed, \
             total_points_planned, bugs_found_after_sprint, \
             code_review_passes, developer_satisfaction_score (1–5), \
             optional `weights` override of \
             {velocity:1, code_review_passes:2, bugs_penalty:10, \
             satisfaction:5}. Seed with one row representing the current \
             sprint under existing rules — that becomes the baseline.
          3. `\(projectRoot)/prepare.py` — reference Python scorer the \
             user can run independently. Reads sprint-data.json, prints \
             SprintSuccessScore. Under 30 lines, no external deps. The \
             gate (sprint-suite) is authoritative; prepare.py is for \
             sanity checks.

        STEP S1 — Add a `## SPRINT RULES OPTIMIZATION` section to \
        crafted.md with:
          • **Methodology file:** `\(projectRoot)/sprint_rules.txt`
          • **Data file:** `\(projectRoot)/sprint-data.json`
          • **Reference scorer:** `\(projectRoot)/prepare.py`
          • **Formula:** \
            `score = (points_completed / total_points_planned * 100) \
            + (code_review_passes * 2) - (bugs_found_after_sprint * 10) \
            + (developer_satisfaction_score * 5)`
          • **Weights:** velocity 1, code_review_passes 2, bugs_penalty \
            10, satisfaction 5.
          • **Baseline composite:** read from \
            `\(projectRoot)/.tado/sprint-baselines/<safe-project-name>.json` \
            after the first SCORE: BASELINE-INIT.
          • **Per-component guards:** bugs_found_after_sprint cannot \
            rise above baseline; code_review_passes cannot drop below \
            baseline.
          • **Satisfaction threshold:** composite above which printing \
            `ETERNAL-DONE` is OK (default: `baseline_composite + 30`).
          • **Mode hint:** \(modeNote)

        STEP S2 — Add to the `## Hard rules` section:
          • Never edit `prepare.py` or the formula in the same iteration \
            where it produces the metric.
          • Never inflate sprint-data.json rows with unrealistic values.
          • Never print `\(isSprintMode ? "[SPRINT-DONE]" : "ETERNAL-DONE")` \
            without `[SCORE-OK]` already in the same turn's transcript.

        RULES-IMPACT STRATUM (rungs to recommend in IMPROVE, safest → \
        most structural):
          Stratum 0  Hygiene             (retire stale rules, fix typos, clarify wording)
          Stratum 1  Refinement          (tighten existing rules — add quantitative thresholds)
          Stratum 2  Coverage            (add a rule for an uncovered failure mode)
          Stratum 3  Reduction           (combine two overlapping rules)
          Stratum 4  Process             (new ceremony — async-review window, standup-only-for-blocked)
          Stratum 5  Structural          (replace one process with another — squad model, swarming)

        """
    }

    /// Engine-tailored "Hard rules" the architect bakes into crafted.md.
    /// Claude callers get the bypass-mode `.claude/`-protected-path
    /// warning; Codex callers get the equivalent reminders for
    /// `--ask-for-approval never --sandbox danger-full-access` (no
    /// interactive dev servers, no `vim`/`less`, etc.). The progress.md
    /// rule and the no-interactive-dialogs rule are the same for both.
    private static func eternalArchitectHardRules(engine: TerminalEngine, runDir: String) -> String {
        let firstRule: String
        switch engine {
        case .claude:
            firstRule = """
              1. BEFORE any `Write` or `Edit` on a new path, run `Bash(mkdir -p <dir>)` \
                 first. Always. Claude Code's `--dangerously-skip-permissions` skips \
                 every prompt EXCEPT writes to protected paths under `.claude/` \
                 when the parent directory has to be created. Prefer non-`.claude/` \
                 output locations whenever possible; `.tado/scratch/` and \
                 `\(runDir)/` are safe. If you must write under `.claude/`, \
                 mkdir the full subpath first.
            """
        case .codex:
            firstRule = """
              1. Codex runs with `--ask-for-approval never --sandbox \
                 danger-full-access`, so file edits and shell commands proceed \
                 without prompts. To keep the loop truly non-stop: do NOT \
                 invoke commands that block the PTY on an interactive UI \
                 (`vim`, `less`, `git rebase -i`, watch-mode dev servers in \
                 the foreground). Prefer non-interactive equivalents \
                 (`git rebase`, `cat`, the Edit tool). If you need a long-\
                 running server, background it with `& disown`. Prefer \
                 writing scratch files under `.tado/scratch/` or \
                 `\(runDir)/`.
            """
        case .cowork:
            // Eternal does not support Cowork — see the matching
            // branch in eternalNonStopHygiene above. This first-rule
            // string is dead code in normal operation; reuse the
            // Claude rule shape so the architect prompt parses if
            // someone hand-edits state.json.
            firstRule = """
              1. BEFORE any `Write` or `Edit` on a new path, run `Bash(mkdir -p <dir>)` \
                 first. (Note: Eternal does not support Cowork as an architect/worker \
                 engine. Stop the run and recreate with `engine = claude` or `engine = \
                 codex`.)
            """
        }
        return """
        \(firstRule)

          2. EVERY turn, BEFORE you end the turn, append at least one concrete \
             line to `\(runDir)/progress.md` in the format \
             `YYYY-MM-DD HH:MM: <one sentence describing what you did>`. This \
             survives compaction — it's the worker's memory across context \
             resets. The Stop hook shows you the last progress.md line on every \
             block; if that line doesn't advance between turns, you forgot to \
             append.

          3. NEVER use tools that open interactive dialogs or confirmations. \
             If a tool asks for input, abort that path and take a different one.
        """
    }

    /// Prompt for the v0.18 "Make Sure" verification agent.
    ///
    /// Invoked from Settings → Process hygiene → Make Sure. The
    /// agent runs in a fresh tile, reads the Rust zombie sweeper's
    /// source as ground truth for what SHOULD have died, then
    /// independently audits the live process table and kills any
    /// survivors. This is the operator's safety net for the case
    /// where the in-process sweeper missed something — for instance
    /// a process that forked between the enumeration and kill
    /// passes, or a pattern variant the sweeper's substring list
    /// doesn't yet cover.
    ///
    /// The protected set (the `make dev` ancestor chain plus the
    /// running Tado app's PID) is provided verbatim — the agent
    /// MUST treat it as a hard exclusion list. Loose pattern kills
    /// like `pkill node` are explicitly forbidden because they'd
    /// match unrelated user processes outside the Tado universe.
    ///
    /// - Parameters:
    ///   - tadoRepoPath: absolute path to the Tado repo root, so the
    ///     agent can find the sweeper source via a deterministic
    ///     relative path. Resolved by Settings as the spawn cwd.
    ///   - ourPid: the live Tado app's PID at sweep time.
    ///   - protectedPids: ancestor chain (Tado → swift run → make
    ///     dev → shell → Terminal → launchd) sourced from the same
    ///     Rust function the in-process sweeper uses. Pass exactly
    ///     what `ZombieSweepResult.protectedPids` returned.
    ///   - sweepSummary: human-readable line summarizing what the
    ///     in-process sweeper just did (or attempted), so the
    ///     verifier has context. e.g. "Killed 4 of 12 matched
    ///     processes; 8 protected, 0 survived".
    static func makeSurePrompt(
        tadoRepoPath: String,
        ourPid: Int32,
        protectedPids: [Int32],
        sweepSummary: String
    ) -> String {
        let protectedList = protectedPids.map(String.init).joined(separator: ", ")
        return """
        You are running as the Tado v0.18 "Make Sure" verifier.

        BACKGROUND
        ----------
        The user just clicked "Kill Zombies" in Tado's Settings → Process \
        hygiene panel. The in-process Rust sweeper at \
        `\(tadoRepoPath)/tado-core/crates/bt-core/src/zombie.rs` ran and \
        produced this summary: \(sweepSummary). They then clicked "Make Sure", \
        which spawned you (this tile) to independently verify nothing \
        Tado-related survived.

        GROUND TRUTH
        ------------
        Read the sweeper source FIRST so you understand exactly what it \
        kills and why. The constant `KILL_PATTERNS` near the top of that \
        file is the canonical list of substrings that identify a \
        Tado-related process. The function `build_protected_set` is the \
        canonical algorithm for what NOT to kill (the ancestor chain that \
        keeps the live Tado app alive).

        PROTECTED SET (DO NOT KILL — repeat, DO NOT KILL these PIDs)
        -----------------------------------------------------------
        Live Tado app PID: \(ourPid)
        Ancestor chain + sentinels: \(protectedList)

        These are the `make dev` tree (shell → make → swift run → Tado), \
        plus PID 1 (launchd) and the PGID-0 sentinel. Killing any of \
        them would close the user's Tado window and likely log them out. \
        If you find any of these PIDs in the live process table, leave \
        them alone — they are the user's hosting environment, not zombies.

        YOUR TASK
        ---------
        1. Read \
        `\(tadoRepoPath)/tado-core/crates/bt-core/src/zombie.rs` end-to-end. \
        Note the kill patterns and the protection algorithm.

        2. Enumerate Tado-related candidates in the live process table:
           ```
           ps -eo pid,pgid,ppid,command \\
             | grep -iE 'release/Tado|/Applications/Tado\\.app/|tado-mcp/dist|target/release/(tado-mcp|dome-mcp|tado-dome)|claude.*--output-format stream-json|codex.*--output-format stream-json' \\
             | grep -v grep
           ```

        3. For each row, decide one of:
           a. **PROTECTED** — PID is in the protected set above. Skip.
           b. **ZOMBIE** — matches a kill pattern AND not protected. Kill.
           c. **AMBIGUOUS** — looks suspicious but you're not sure. \
              Report and skip (do not kill anything you're unsure about).

        4. Kill each ZOMBIE via process-group SIGKILL:
           ```
           PGID=$(ps -o pgid= -p <PID> | tr -d ' ')
           if [ "$PGID" -gt 1 ] && ! echo " \(protectedList) " | grep -q " $PGID "; then
             kill -9 -$PGID
           fi
           ```
           Never use `pkill` with broad patterns like `pkill node` — that \
           would match unrelated user processes.

        5. Wait 500ms, then re-enumerate. Anything still alive that should \
        have died is a survivor. Report it and try once more (a second \
        SIGKILL to the PG, then to the PID directly if the PG is gone).

        6. Print a final report in this exact shape (the user reads this \
        verbatim):
           ```
           === Make Sure: Verification Report ===
           Killed: <N> processes
             - PID <pid> PGID <pgid> [<pattern>]: <command>
             - ...
           Protected (left alive): <M> processes
             - PID <pid> [<reason>]: <command>
             - ...
           Survivors after kill: <K> processes
             - PID <pid>: <command>
           Ambiguous (skipped, manual review): <A> processes
             - PID <pid>: <command>

           Verdict: <"✓ Tado is clean" | "⚠ <K> survivors need manual review">
           ```

        7. After printing the report, your job is done. Do not loop, do not \
        spawn other agents, do not make Dome notes — this tile is for the \
        user's eyes only.

        HARD RULES
        ----------
        - DO NOT kill any PID in {\(protectedList), \(ourPid)}.
        - DO NOT use broad pkill patterns. Match by the substrings in \
          `KILL_PATTERNS` only.
        - DO NOT touch processes whose command line doesn't match a \
          KILL_PATTERN substring, even if the name looks Tado-related.
        - DO NOT make any Dome / settings / file changes outside what \
          the kill commands require.
        - If a sudo prompt or interactive dialog appears, abort that \
          path and continue with the rest. The sweep should never need \
          sudo — every Tado-related process runs as the current user.
        """
    }
}
