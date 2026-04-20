import Foundation
import SwiftData

/// Stateless utility for the Eternal feature — single-agent non-stop sessions
/// kept alive by Claude Code hooks. Mirror of `DispatchPlanService` in shape
/// (enum with static methods, owns all `.tado/eternal/` I/O, `@MainActor`
/// spawn helper). No supervision, no watchdogs — the UI reads `state.json`
/// for observability only.
enum EternalService {
    // MARK: - Paths (project-scoped — single-run legacy)

    static func eternalRoot(_ project: Project) -> URL {
        URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".tado")
            .appendingPathComponent("eternal")
    }

    // MARK: - Paths (run-scoped — multi-run)

    /// Parent dir holding every run's on-disk state for a project:
    /// `<project>/.tado/eternal/runs/`. Callers should not read this directly;
    /// use `eternalRoot(_ run:)` for a specific run.
    static func runsRootURL(_ project: Project) -> URL {
        URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".tado")
            .appendingPathComponent("eternal")
            .appendingPathComponent("runs")
    }

    /// On-disk directory for one run: `<project>/.tado/eternal/runs/<uuid>/`.
    /// `run.project` is the SwiftData back-reference; it's never nil in
    /// practice (cascade-delete prevents orphans) but is modeled as optional
    /// by the `@Relationship` macro. A nil value here means SwiftData corrupted
    /// the inverse — hard crash is appropriate rather than silently writing
    /// under the wrong tree.
    static func eternalRoot(_ run: EternalRun) -> URL {
        guard let project = run.project else {
            fatalError(
                "EternalRun \(run.id) has nil project — cascade inverse corrupted."
            )
        }
        return runsRootURL(project).appendingPathComponent(run.id.uuidString)
    }

    static func userBriefFileURL(_ run: EternalRun) -> URL {
        eternalRoot(run).appendingPathComponent("user-brief.md")
    }

    static func craftedFileURL(_ run: EternalRun) -> URL {
        eternalRoot(run).appendingPathComponent("crafted.md")
    }

    static func progressFileURL(_ run: EternalRun) -> URL {
        eternalRoot(run).appendingPathComponent("progress.md")
    }

    static func metricsFileURL(_ run: EternalRun) -> URL {
        eternalRoot(run).appendingPathComponent("metrics.jsonl")
    }

    static func stateFileURL(_ run: EternalRun) -> URL {
        eternalRoot(run).appendingPathComponent("state.json")
    }

    static func activeFlagURL(_ run: EternalRun) -> URL {
        eternalRoot(run).appendingPathComponent("active")
    }

    static func stopFlagURL(_ run: EternalRun) -> URL {
        eternalRoot(run).appendingPathComponent("stop-flag")
    }

    static func inboxDirURL(_ run: EternalRun) -> URL {
        eternalRoot(run).appendingPathComponent("inbox")
    }

    static func inboxProcessedDirURL(_ run: EternalRun) -> URL {
        eternalRoot(run).appendingPathComponent("inbox-processed")
    }

    // MARK: - Paths (project-scoped — hooks + settings, shared across runs)

    /// Project-level hooks directory, holding the six bash scripts all
    /// concurrent runs share. `<project>/.tado/eternal/hooks/`.
    static func hooksDirURL(_ project: Project) -> URL {
        eternalRoot(project).appendingPathComponent("hooks")
    }

    static func claudeSettingsURL(_ project: Project) -> URL {
        URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }

    /// `.claude/settings.local.json` under the project root — the gitignored
    /// "local" scope. Per Claude Code docs, `skipDangerousModePermissionPrompt`
    /// is ignored when set in the shared `settings.json` but IS honored when
    /// set here, so this file is where we plant the flag that actually
    /// silences the "Are you sure you want to enter bypass mode?" dialog.
    static func claudeLocalSettingsURL(_ project: Project) -> URL {
        URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.local.json")
    }

    /// `~/.claude/settings.json` — the USER scope. Resolved via
    /// FileManager rather than `NSHomeDirectory()` so it works inside the
    /// app sandbox if we ever enable it. Merging here is a one-shot per
    /// launch so every Claude Code process (not just Tado spawns) inherits
    /// bypassPermissions + a wide allowlist.
    static func userClaudeSettingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }

    // MARK: - State I/O (run-scoped)

    /// Reads `state.json`. Tolerant: returns `nil` on any error (file missing,
    /// hook mid-write, malformed JSON). The dashboard treats `nil` as
    /// "transient, wait one more tick" rather than an error condition.
    static func readState(_ run: EternalRun) -> EternalState? {
        guard let data = try? Data(contentsOf: stateFileURL(run)) else { return nil }
        return try? JSONDecoder().decode(EternalState.self, from: data)
    }

    /// Writes initial `state.json` at spawn time. The hooks mutate the file
    /// in-place afterwards; Swift never writes again.
    static func writeInitialState(_ state: EternalState, run: EternalRun) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: eternalRoot(run),
            withIntermediateDirectories: true
        )
        try data.write(to: stateFileURL(run), options: .atomic)
    }

    /// Parses `metrics.jsonl` — one JSON object per line. Tolerant: rows that
    /// fail to decode are filtered out. Used by the dashboard sparkline.
    static func readMetrics(_ run: EternalRun) -> [EternalMetricSample] {
        guard let text = try? String(contentsOf: metricsFileURL(run), encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        return text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(EternalMetricSample.self, from: data)
        }
    }

    // MARK: - Flag files (user → hook signalling)

    /// Touch `active` so the hooks stop being no-ops.
    static func markActive(_ run: EternalRun) throws {
        try FileManager.default.createDirectory(
            at: eternalRoot(run),
            withIntermediateDirectories: true
        )
        try Data().write(to: activeFlagURL(run))
    }

    /// Touch `stop-flag` so the next Stop hook firing exits the session cleanly.
    static func requestStop(_ run: EternalRun) {
        try? FileManager.default.createDirectory(
            at: eternalRoot(run),
            withIntermediateDirectories: true
        )
        try? Data().write(to: stopFlagURL(run))
    }

    /// Is there a live eternal running (from the hooks' POV)?
    static func isActive(_ run: EternalRun) -> Bool {
        FileManager.default.fileExists(atPath: activeFlagURL(run).path)
    }

    /// Has the architect finished and written the crafted brief? Used by
    /// ProjectEternalSection's state machine to flip planning → ready.
    static func craftedExistsOnDisk(_ run: EternalRun) -> Bool {
        FileManager.default.fileExists(atPath: craftedFileURL(run).path)
    }

    /// Full body of the architect's crafted.md. Nil if missing. Used by the
    /// ready-state preview and the worker spawn.
    static func readCrafted(_ run: EternalRun) -> String? {
        try? String(contentsOf: craftedFileURL(run), encoding: .utf8)
    }

    // MARK: - Reset / clear

    /// Wipe the run's on-disk state so a new architect/worker pair can start
    /// clean. Deletes the entire run dir's contents except `hooks.log` and
    /// the user-brief; callers that want the user-brief to survive a redo
    /// write it back after calling this.
    static func resetEternal(_ run: EternalRun) {
        let fm = FileManager.default
        let root = eternalRoot(run)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        for url in [
            craftedFileURL(run),
            progressFileURL(run),
            metricsFileURL(run),
            stateFileURL(run),
            activeFlagURL(run),
            stopFlagURL(run),
        ] {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Delete

    /// Irreversibly drop an Eternal run: kill any live tiles attached to it,
    /// wipe its on-disk `.tado/eternal/runs/<id>/` dir, and remove the
    /// SwiftData row. Matches user-initiated delete from the project detail
    /// page.
    ///
    /// A running worker is stopped by `terminateSession` (sends SIGINT to
    /// the PTY); we do NOT write `stop-flag` first because the wrapper
    /// process and all its hooks die with the tile, so there's no one
    /// left to read the flag. The run dir goes with the tile.
    ///
    /// Project-level hooks (`.tado/eternal/hooks/`) stay — other runs in
    /// this project still need them.
    @MainActor
    static func deleteRun(
        _ run: EternalRun,
        modelContext: ModelContext,
        terminalManager: TerminalManager
    ) {
        let runDir = eternalRoot(run)

        // Kill any sessions linked to this run — worker, architect,
        // interventor, or anything else the spawn paths tagged with the
        // run id. Iterate on a snapshot because terminateSession mutates
        // `sessions`. `hard: true` sends SIGKILL (not SIGTERM): we're
        // about to remove the run dir, so open file descriptors need to
        // be gone NOW. SIGKILL can't be caught, so the kernel reaps the
        // process before we attempt `removeItem`.
        let linked = terminalManager.sessions.filter { $0.eternalRunID == run.id }
        for session in linked {
            terminalManager.terminateSession(session.id, hard: true)
        }

        // The SwiftData row goes away synchronously — the UI should
        // update immediately, regardless of how the on-disk cleanup ends
        // up. Orphan run dirs are harmless (they're gitignored and not
        // referenced by anything after the row is gone).
        modelContext.delete(run)
        try? modelContext.save()

        // Remove the on-disk dir asynchronously with retries. Even after
        // SIGKILL the kernel needs a moment to close the process's
        // open fds; calling `removeItem` within the same run-loop tick
        // can hit a race where the PTY's log file is still open in the
        // dying process and the recursive delete fails on the parent
        // rmdir. A 200 ms delay + one retry after 1 s covers practically
        // every machine.
        Task { @MainActor in
            await Self.removeRunDirWithRetry(runDir, label: "EternalService")
        }
    }

    /// Async directory-removal with backoff retry. Factored out so
    /// Dispatch's parallel delete flow can reuse the same policy.
    /// Logs NSError userInfo on the final failure so a future repro
    /// surfaces the actual underlying code (permission denied, busy,
    /// etc.) instead of just "couldn't be removed."
    private static func removeRunDirWithRetry(_ runDir: URL, label: String) async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runDir.path) else { return }

        // First attempt after the kernel reaps the SIGKILL'd process.
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200 ms
        do {
            try fm.removeItem(at: runDir)
            return
        } catch {
            NSLog("\(label): first removeItem attempt on \(runDir.path) failed: \(error). Retrying after 1s.")
        }

        // Retry after a longer delay — covers slow fd-close races or
        // a hook that briefly reopened a file in the dir.
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 s
        do {
            try fm.removeItem(at: runDir)
        } catch let error as NSError {
            NSLog("\(label): deleteRun failed to remove \(runDir.path) after retry. code=\(error.code) domain=\(error.domain) userInfo=\(error.userInfo)")
        } catch {
            NSLog("\(label): deleteRun failed to remove \(runDir.path) after retry: \(error)")
        }
    }

    // MARK: - Hook installation

    /// Write the four hook scripts (chmod +x) and merge the hook registrations
    /// into `.claude/settings.json`. Idempotent: re-running is a no-op aside
    /// from overwriting the scripts with their latest text.
    ///
    /// Also pre-creates the four `.claude/` subdirectories on Claude Code's
    /// "protected-path exception" list (agents/commands/skills/worktrees).
    /// Bypass mode does NOT skip the permission prompt for writes under
    /// `.claude/` when the parent directory has to be created — creating
    /// them up-front sidesteps that race for agents that legitimately need
    /// to write skills/agents. Also writes `.claude/settings.local.json`
    /// with `skipDangerousModePermissionPrompt: true` so the one-time
    /// "are you sure?" dialog never appears for this project.
    static func installHooks(_ project: Project) throws {
        let fm = FileManager.default
        let hooks = hooksDirURL(project)
        try fm.createDirectory(at: hooks, withIntermediateDirectories: true)

        for (name, body) in hookScripts {
            let url = hooks.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            _ = try? fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: url.path
            )
        }

        // Pre-create the exception subdirs. Claude Code's protected-path
        // rule exempts these four, so writes under them don't prompt —
        // BUT creating the parent `.claude/` itself does. Creating
        // everything up-front here means the agent never needs to.
        let projectRoot = URL(fileURLWithPath: project.rootPath)
        for subdir in ["agents", "commands", "skills", "worktrees"] {
            let url = projectRoot
                .appendingPathComponent(".claude")
                .appendingPathComponent(subdir)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }

        try mergeClaudeSettings(project)
        writeProjectLocalSettings(project)
    }

    /// The four hook scripts as file-name → body pairs. Stored inline so the
    /// app binary carries them — no disk template lookup at runtime. Each
    /// script is presence-gated by the `active` marker in its wrapper command
    /// (see `mergeClaudeSettings`), so installing hooks is safe even when no
    /// eternal is running.
    private static let hookScripts: [(String, String)] = [
        ("stop.sh", stopScript),
        ("session-start-compact.sh", sessionStartCompactScript),
        ("pre-compact.sh", preCompactScript),
        ("post-tool.sh", postToolScript),
        ("eternal-loop.sh", workerLoopScript),
    ]

    // MARK: - Hook bodies
    // (Plain bash. `jq` is required — documented as a prereq.)

    // IMPORTANT: all hook bodies below are FAIL-SAFE. No `set -e` / `pipefail`.
    // The Stop hook in particular: if it ever exits with a non-zero code that
    // isn't 2, Claude Code logs "Stop hook error: Failed with non-blocking
    // status code" and ALLOWS the Stop — ending the eternal session. That's
    // precisely what happened to the user's first real Sprint run (screenshot
    // 2026-04-18 20:19). Keep it paranoid. Every continuation path must emit
    // JSON + exit 0, or fall through to exit 2.
    private static let stopScript = ##"""
    #!/bin/bash
    # FAIL-SAFE. Do not add `set -e` or `pipefail`. See comment in
    # EternalService.swift for why.

    ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
    RUN_ID="${TADO_ETERNAL_RUN_ID:-}"

    # Architect, interventor, or ad-hoc claude tiles inherit this hook
    # definition but leave the env var empty. The wrapper already short-
    # circuited via `[ -n "$RUN" ] && [ -f ...active ]` — reaching here
    # without a run id means the presence-gate let us through on some
    # other path (tampering, old wrapper). Exit clean.
    if [ -z "$RUN_ID" ]; then
        exit 0
    fi

    RUN_DIR="$ROOT/.tado/eternal/runs/$RUN_ID"
    STATE="$RUN_DIR/state.json"
    STOP_FLAG="$RUN_DIR/stop-flag"
    LOG="$RUN_DIR/hooks.log"

    mkdir -p "$RUN_DIR" 2>/dev/null || true
    { echo "---"; date -u +"%FT%TZ stop hook invoked (run=$RUN_ID)"; } >> "$LOG" 2>/dev/null || true

    emit_block_and_exit() {
        local reason="$1"
        if jq -n --arg r "$reason" '{decision:"block", reason:$r}' 2>/dev/null; then
            exit 0
        fi
        exit 2   # JSON emission failed — block via exit code as a safety net.
    }

    INPUT="$(cat 2>/dev/null || echo '{}')"
    { echo "$INPUT" | head -c 4096; echo ""; } >> "$LOG" 2>/dev/null || true

    ACTIVE="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")"
    TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")"

    # External loop mode — the eternal-loop.sh wrapper owns continuation.
    # Each `claude -p` invocation is a fresh session; Stop hook runs at the
    # end of each, but we must NOT block here, or Claude Code's in-session
    # recursion guard will trip and end the session prematurely. Update
    # bookkeeping and allow the stop; the wrapper re-spawns on next tick.
    if [ "$TADO_ETERNAL_LOOP_MODE" = "1" ]; then
        tmp="$(mktemp 2>/dev/null)" && jq '.iterations += 1 | .lastActivityAt = (now|floor)' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
        echo "exit path: loop mode allow" >> "$LOG" 2>/dev/null || true
        exit 0
    fi

    # Recursion guard — allow stop cleanly.
    if [ "$ACTIVE" = "true" ]; then
        echo "exit path: recursion guard" >> "$LOG" 2>/dev/null || true
        exit 0
    fi

    # User pressed Stop — allow.
    if [ -f "$STOP_FLAG" ]; then
        rm -f "$STOP_FLAG" "$RUN_DIR/active" 2>/dev/null || true
        tmp="$(mktemp 2>/dev/null)" && jq '.phase = "stopped"' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
        echo "exit path: user stop" >> "$LOG" 2>/dev/null || true
        exit 0
    fi

    MODE="$(jq -r '.mode // "mega"' "$STATE" 2>/dev/null || echo "mega")"
    DONE_MARKER="$(jq -r '.completionMarker // "ETERNAL-DONE"' "$STATE" 2>/dev/null || echo "ETERNAL-DONE")"
    SPRINT_MARKER="$(jq -r '.sprintMarker // "[SPRINT-DONE]"' "$STATE" 2>/dev/null || echo "[SPRINT-DONE]")"

    LAST=""
    if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
        LAST="$(tail -200 "$TRANSCRIPT" 2>/dev/null | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null | tail -c 8192 || echo "")"
    fi

    # Completion marker — whole-line match only. Substring matches are
    # false-positives ("ETERNAL-DONE only after all phases" shouldn't stop).
    if [ -n "$LAST" ] && echo "$LAST" | grep -qFx -- "$DONE_MARKER" 2>/dev/null; then
        rm -f "$RUN_DIR/active" 2>/dev/null || true
        tmp="$(mktemp 2>/dev/null)" && jq '.phase = "completed"' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
        echo "exit path: completion marker" >> "$LOG" 2>/dev/null || true
        exit 0
    fi

    # Last non-empty line of progress.md — anchors every nudge in real
    # context instead of a generic "continue the sprint". Capped so the
    # reason stays small enough not to eat into the agent's context budget.
    last_progress_line() {
        local raw
        raw="$(tail -20 "$RUN_DIR/progress.md" 2>/dev/null | awk 'NF' | tail -1 | head -c 280 2>/dev/null || echo "")"
        if [ -z "$raw" ]; then
            echo "(none yet)"
        else
            echo "$raw"
        fi
    }

    # Sprint marker — Sprint mode only. Block and continue.
    if [ "$MODE" = "sprint" ] && [ -n "$LAST" ] && echo "$LAST" | grep -qFx -- "$SPRINT_MARKER" 2>/dev/null; then
        tmp="$(mktemp 2>/dev/null)" && jq '.sprints += 1 | .phase = "working" | .lastActivityAt = (now|floor)' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
        SPRINT_N="$(jq -r '.sprints // 0' "$STATE" 2>/dev/null || echo '?')"
        LAST_PROGRESS="$(last_progress_line)"
        echo "exit path: sprint marker" >> "$LOG" 2>/dev/null || true
        emit_block_and_exit "[Tado Eternal · starting sprint $SPRINT_N] Previous sprint closed. Last progress.md note: \"$LAST_PROGRESS\". MANDATORY every turn: append at least one concrete line to $RUN_DIR/progress.md (format: 'YYYY-MM-DD HH:MM: <one sentence>'). The last progress note in the nudge should advance each turn. Begin sprint $SPRINT_N now — APPLY (implement the improvement chosen last sprint) → EVAL (run the evaluation from crafted.md, append one line to $RUN_DIR/metrics.jsonl) → IMPROVE (read the last 5 metric lines, decide next knob, log one line to progress.md). End this sprint with $SPRINT_MARKER. Only $DONE_MARKER if the metric is clearly satisfactory AND I've indicated satisfaction."
    fi

    # Default: block and continue. Mode-specific nudge with live context.
    tmp="$(mktemp 2>/dev/null)" && jq '.iterations += 1 | .phase = "working" | .lastActivityAt = (now|floor)' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
    ITER_N="$(jq -r '.iterations // 0' "$STATE" 2>/dev/null || echo '?')"
    SPRINT_N="$(jq -r '.sprints // 0' "$STATE" 2>/dev/null || echo '?')"
    LAST_PROGRESS="$(last_progress_line)"

    if [ "$MODE" = "sprint" ]; then
        echo "exit path: default sprint continue" >> "$LOG" 2>/dev/null || true
        emit_block_and_exit "[Tado Eternal · sprint $SPRINT_N · turn $ITER_N in-sprint] Continue the current sprint. Last progress.md note: \"$LAST_PROGRESS\". MANDATORY: before you end this turn, APPEND at least one concrete progress line to $RUN_DIR/progress.md describing what you did (format: 'YYYY-MM-DD HH:MM: <one sentence>'). The last progress note in this nudge should advance between turns; if it doesn't, you forgot to append. Re-read crafted.md if you're unsure which phase you're in (APPLY → EVAL → IMPROVE). End the sprint with $SPRINT_MARKER. Only output $DONE_MARKER if the metric is explicitly satisfactory AND I've indicated satisfaction."
    fi

    echo "exit path: default mega continue" >> "$LOG" 2>/dev/null || true
    emit_block_and_exit "[Tado Eternal · iter $ITER_N] Continue the task. Last progress.md note: \"$LAST_PROGRESS\". MANDATORY: before you end this turn, APPEND at least one concrete progress line to $RUN_DIR/progress.md describing what you did (format: 'YYYY-MM-DD HH:MM: <one sentence>'). The last progress note in this nudge should advance between turns; if it doesn't, you forgot to append. Do the next unit of work. Output $DONE_MARKER exactly when (and only when) the entire task is finished."

    # Unreachable, but if we somehow fall through: block via exit code.
    exit 2
    """##

    private static let sessionStartCompactScript = ##"""
    #!/bin/bash
    # FAIL-SAFE. No set -e.

    ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
    RUN_ID="${TADO_ETERNAL_RUN_ID:-}"
    [ -n "$RUN_ID" ] || exit 0
    RUN_DIR="$ROOT/.tado/eternal/runs/$RUN_ID"

    INPUT="$(cat 2>/dev/null || echo '{}')"
    SOURCE="$(echo "$INPUT" | jq -r '.source // ""' 2>/dev/null || echo "")"
    [ "$SOURCE" = "compact" ] || exit 0

    STATE="$RUN_DIR/state.json"
    tmp="$(mktemp 2>/dev/null)" && jq '.compactions += 1' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null

    # crafted.md is the architect's output; fall back to user-brief.md then
    # the legacy eternal.md (pre-architect sessions still have that file).
    BRIEF=""
    for candidate in "$RUN_DIR/crafted.md" "$RUN_DIR/user-brief.md" "$RUN_DIR/eternal.md"; do
        if [ -f "$candidate" ]; then
            BRIEF="$(cat "$candidate" 2>/dev/null || echo "")"
            [ -n "$BRIEF" ] && break
        fi
    done
    [ -n "$BRIEF" ] || BRIEF="(brief missing)"
    PROGRESS="$(tail -80 "$RUN_DIR/progress.md" 2>/dev/null || echo "(no progress yet)")"
    MARKER="$(jq -r '.completionMarker // "ETERNAL-DONE"' "$STATE" 2>/dev/null || echo "ETERNAL-DONE")"

    # Stdout is injected as context after compaction (up to 10k chars).
    cat <<EOF
    [TADO ETERNAL — context restored after compaction]

    Original brief:

    $BRIEF

    Recent progress (tail of $RUN_DIR/progress.md):

    $PROGRESS

    Continue iterating. Output exactly "$MARKER" when finished.
    EOF
    exit 0
    """##

    private static let preCompactScript = ##"""
    #!/bin/bash
    # FAIL-SAFE. No set -e.
    RUN_ID="${TADO_ETERNAL_RUN_ID:-}"
    [ -n "$RUN_ID" ] || exit 0
    STATE="${CLAUDE_PROJECT_DIR:-$PWD}/.tado/eternal/runs/$RUN_ID/state.json"
    tmp="$(mktemp 2>/dev/null)" && jq '.phase = "compacting"' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
    exit 0
    """##

    private static let postToolScript = ##"""
    #!/bin/bash
    # FAIL-SAFE. No set -e.
    RUN_ID="${TADO_ETERNAL_RUN_ID:-}"
    [ -n "$RUN_ID" ] || exit 0
    STATE="${CLAUDE_PROJECT_DIR:-$PWD}/.tado/eternal/runs/$RUN_ID/state.json"
    tmp="$(mktemp 2>/dev/null)" && jq '.lastActivityAt = (now|floor)' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
    exit 0
    """##

    // External-loop driver. Spawned by MetalTerminalTileView for Eternal
    // workers in place of invoking `claude` directly. Solves the Stop-hook
    // recursion guard: Claude Code's internal per-session block counter
    // trips after ~20-30 Stop-block cycles and forces a clean exit. By
    // running `claude -p "..."` in a shell loop, each iteration is a
    // fresh session with the counter reset — genuinely eternal.
    //
    // Contract:
    //   - Reads .tado/eternal/crafted.md as the authoritative brief each
    //     iteration.
    //   - Tails .tado/eternal/progress.md for memory across iterations.
    //   - Exports TADO_ETERNAL_LOOP_MODE=1 so stop.sh knows to allow
    //     stop cleanly (the wrapper owns continuation).
    //   - Exits when .tado/eternal/stop-flag exists, ETERNAL-DONE appears
    //     in claude stdout, or TADO_ETERNAL_MAX_ITER is reached.
    //
    // Env knobs set by Swift at spawn time (MetalTerminalTileView):
    //   TADO_DONE_MARKER    — completion marker, default ETERNAL-DONE
    //   TADO_SPRINT_MARKER  — sprint-end marker, default [SPRINT-DONE]
    //   TADO_ETERNAL_MODE   — "mega" | "sprint"
    //   TADO_MODEL          — optional `--model` value
    //   TADO_EFFORT         — optional `--effort` value
    //   TADO_SKIP_PERMISSIONS — "1" to pass --dangerously-skip-permissions
    //   TADO_ETERNAL_MAX_ITER — 0 = unlimited
    private static let workerLoopScript = ##"""
    #!/bin/bash
    # Tado Eternal — external loop driver. FAIL-SAFE: don't `set -e`.

    ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
    RUN_ID="${TADO_ETERNAL_RUN_ID:-}"
    if [ -z "$RUN_ID" ]; then
        echo "ERROR: eternal-loop.sh requires TADO_ETERNAL_RUN_ID env var" >&2
        echo "This script is run-scoped; the spawning process (ProcessSpawner.eternalWorkerEnv)" >&2
        echo "must set TADO_ETERNAL_RUN_ID to the EternalRun's UUID string." >&2
        exit 1
    fi
    TADO_DIR="$ROOT/.tado/eternal/runs/$RUN_ID"
    BRIEF="$TADO_DIR/crafted.md"
    PROGRESS="$TADO_DIR/progress.md"
    STATE="$TADO_DIR/state.json"
    STOP_FLAG="$TADO_DIR/stop-flag"
    ACTIVE_FLAG="$TADO_DIR/active"
    LOG="$TADO_DIR/loop.log"

    DONE_MARKER="${TADO_DONE_MARKER:-ETERNAL-DONE}"
    SPRINT_MARKER="${TADO_SPRINT_MARKER:-[SPRINT-DONE]}"
    MODE="${TADO_ETERNAL_MODE:-mega}"
    MAX_ITER="${TADO_ETERNAL_MAX_ITER:-0}"

    mkdir -p "$TADO_DIR" 2>/dev/null || true
    touch "$ACTIVE_FLAG" 2>/dev/null || true

    # Critical: stop.sh checks this to skip its block-and-continue logic.
    # Claude Code inherits env vars from the parent shell into hooks.
    export TADO_ETERNAL_LOOP_MODE=1
    export CLAUDE_CODE_AUTO_UPDATE_DISABLED=1

    { echo "---"; date -u +"%FT%TZ eternal-loop.sh start (pid=$$, mode=$MODE)"; } >> "$LOG" 2>/dev/null || true

    echo "════════════════════════════════════════════════════════════"
    echo " Tado Eternal — external loop driver"
    echo " mode: $MODE"
    echo " brief: $BRIEF"
    echo " progress: $PROGRESS"
    echo " exit on: stop-flag | $DONE_MARKER | max-iter"
    echo "════════════════════════════════════════════════════════════"

    ITER=0
    while true; do
        ITER=$((ITER + 1))

        # Stop conditions.
        if [ -f "$STOP_FLAG" ]; then
            rm -f "$STOP_FLAG" "$ACTIVE_FLAG" 2>/dev/null || true
            tmp="$(mktemp 2>/dev/null)" && jq '.phase = "stopped"' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
            echo "[$(date -u +%FT%TZ)] iter $ITER: user stop" >> "$LOG" 2>/dev/null || true
            echo ""
            echo "=== Tado Eternal: stopped by user ==="
            break
        fi

        if [ "$MAX_ITER" -gt 0 ] && [ "$ITER" -gt "$MAX_ITER" ]; then
            echo "[$(date -u +%FT%TZ)] iter $ITER: max iter reached" >> "$LOG" 2>/dev/null || true
            echo ""
            echo "=== Tado Eternal: max iterations ($MAX_ITER) reached ==="
            break
        fi

        # Build the prompt for this iteration. Use a temp file so shell
        # arg-length limits don't clip long crafted.md briefs.
        PROMPT_FILE="$(mktemp 2>/dev/null)"
        if [ -z "$PROMPT_FILE" ]; then
            echo "[$(date -u +%FT%TZ)] iter $ITER: mktemp failed" >> "$LOG" 2>/dev/null || true
            sleep 5
            continue
        fi

        BRIEF_TEXT="$(cat "$BRIEF" 2>/dev/null)"
        [ -z "$BRIEF_TEXT" ] && BRIEF_TEXT="(brief missing at $BRIEF — did the architect run?)"
        PROGRESS_TEXT="$(tail -30 "$PROGRESS" 2>/dev/null)"
        [ -z "$PROGRESS_TEXT" ] && PROGRESS_TEXT="(no progress yet — this is your first iteration)"

        # Drain any user interventions dropped into the inbox since the
        # last iteration. Each file is one distilled directive written by
        # the Interventor tile (see EternalService.spawnInterventor).
        # Move processed files aside so we never include them twice.
        INBOX_DIR="$TADO_DIR/inbox"
        PROCESSED_DIR="$TADO_DIR/inbox-processed"
        mkdir -p "$INBOX_DIR" "$PROCESSED_DIR" 2>/dev/null || true
        INTERVENTIONS_TEXT=""
        if [ -d "$INBOX_DIR" ]; then
            for f in "$INBOX_DIR"/*.md; do
                [ -f "$f" ] || continue
                INTERVENTIONS_TEXT="$INTERVENTIONS_TEXT"$'\n'"--- $(basename "$f") ---"$'\n'
                INTERVENTIONS_TEXT="$INTERVENTIONS_TEXT$(cat "$f" 2>/dev/null)"$'\n\n'
                mv "$f" "$PROCESSED_DIR/" 2>/dev/null || rm -f "$f" 2>/dev/null || true
            done
        fi

        {
            printf '%s\n' "[TADO ETERNAL · loop iteration $ITER · mode=$MODE]"
            printf '%s\n' ""
            printf '%s\n' "You have been spawned in a FRESH non-interactive Claude Code session by"
            printf '%s\n' "the Tado Eternal loop driver. Your context is empty except for this"
            printf '%s\n' "prompt. After your turn ends, the driver will spawn you again with an"
            printf '%s\n' "updated prompt; this continues indefinitely until you output"
            printf '%s\n' "\"$DONE_MARKER\" on its own line, or the user presses Stop."
            printf '%s\n' ""
            printf '%s\n' "Your full brief is below — re-read it every iteration because you have"
            printf '%s\n' "no memory of prior iterations except what is in progress.md."
            printf '%s\n' ""
            printf '%s\n' "═══════════════════════════════════════════════════════════"
            printf '%s\n' "CRAFTED BRIEF"
            printf '%s\n' "═══════════════════════════════════════════════════════════"
            printf '%s\n' "$BRIEF_TEXT"
            printf '%s\n' ""
            printf '%s\n' "═══════════════════════════════════════════════════════════"
            printf '%s\n' "RECENT PROGRESS (tail of progress.md — your memory across sessions)"
            printf '%s\n' "═══════════════════════════════════════════════════════════"
            printf '%s\n' "$PROGRESS_TEXT"
            printf '%s\n' ""
            if [ -n "$INTERVENTIONS_TEXT" ]; then
                printf '%s\n' "═══════════════════════════════════════════════════════════"
                printf '%s\n' "USER INTERVENTIONS (process BEFORE anything else this turn)"
                printf '%s\n' "═══════════════════════════════════════════════════════════"
                printf '%s\n' "The user has dropped one or more directives into your inbox"
                printf '%s\n' "since the last iteration. These are authoritative — they"
                printf '%s\n' "override your current plan. Read each note, decide how it"
                printf '%s\n' "changes THIS iteration's work (pivot the priority, fix a"
                printf '%s\n' "mistake, answer a question, add a constraint), and log"
                printf '%s\n' "what you decided to progress.md so the user sees it."
                printf '%s\n' ""
                printf '%s\n' "$INTERVENTIONS_TEXT"
            fi
            printf '%s\n' "═══════════════════════════════════════════════════════════"
            printf '%s\n' "DO ONE ITERATION NOW"
            printf '%s\n' "═══════════════════════════════════════════════════════════"
            printf '%s\n' "MANDATORY:"
            printf '%s\n' "  1. BEFORE any Write or Edit on a new path, run Bash(mkdir -p <dir>)."
            printf '%s\n' "  2. BEFORE ending this iteration, APPEND ONE concrete line to"
            printf '%s\n' "     $PROGRESS in the format \"YYYY-MM-DD HH:MM: <one sentence>\"."
            printf '%s\n' "  3. Do one productive unit of work. Don't try to do the whole task —"
            printf '%s\n' "     the loop runs forever, use future iterations."
            printf '%s\n' "  4. End your turn naturally. The driver re-spawns you automatically."
            printf '%s\n' "  5. Output \"$DONE_MARKER\" on its own line ONLY if the entire task is"
            printf '%s\n' "     complete and I've indicated satisfaction."
            if [ "$MODE" = "sprint" ]; then
                printf '%s\n' "  6. Sprint mode: end a sprint by outputting \"$SPRINT_MARKER\" on its"
                printf '%s\n' "     own line. The driver increments the sprint counter automatically."
                printf '%s\n' "     A single iteration may be one phase of a sprint (APPLY, EVAL, or"
                printf '%s\n' "     IMPROVE) — don't force all three into one turn."
            fi
            printf '%s\n' ""
            printf '%s\n' "Iteration $ITER begins now."
        } > "$PROMPT_FILE"

        # Build claude flags from env.
        CLAUDE_FLAGS=(
            "--permission-mode" "bypassPermissions"
            "--setting-sources" "user,project,local"
        )
        [ "${TADO_SKIP_PERMISSIONS:-1}" = "1" ] && CLAUDE_FLAGS+=("--dangerously-skip-permissions")
        [ -n "$TADO_MODEL" ] && CLAUDE_FLAGS+=("--model" "$TADO_MODEL")
        [ -n "$TADO_EFFORT" ] && CLAUDE_FLAGS+=("--effort" "$TADO_EFFORT")

        echo ""
        echo "────────── iteration $ITER (started $(date -u +%H:%M:%SZ)) ──────────"
        echo ""
        echo "[$(date -u +%FT%TZ)] iter $ITER: invoking claude" >> "$LOG" 2>/dev/null || true

        # Streaming strategy:
        #
        # `claude -p` in the default "text" output format emits NOTHING
        # until the whole turn finishes. The tile sits blank for minutes.
        # `script -q /dev/null` doesn't help — claude intentionally
        # buffers the complete assistant response before printing in
        # text mode.
        #
        # Fix: `--output-format stream-json --include-partial-messages
        # --verbose` makes claude emit one JSON event per line as work
        # progresses (session init → thinking → tool_use start → text
        # deltas → result). We tee the raw NDJSON to a file (for marker
        # detection afterward) and pipe it through jq to pretty-print a
        # human-readable stream in the tile: tool-use names, text
        # deltas, etc. Every event flushes immediately because jq's
        # stdout is the terminal (line-buffered) and claude writes one
        # JSON object per line.
        RAW_OUTPUT="$(mktemp 2>/dev/null)"
        OUTPUT_FILE="$(mktemp 2>/dev/null)"
        claude -p "$(cat "$PROMPT_FILE")" \
            --output-format stream-json \
            --include-partial-messages \
            --verbose \
            "${CLAUDE_FLAGS[@]}" 2>&1 \
          | tee "$RAW_OUTPUT" \
          | jq -Rr --unbuffered '
              try fromjson catch null
              | select(. != null)
              | if .type == "system" and .subtype == "init" then
                    "▸ session ready (model: " + (.model // "?") + ")\n"
                elif .type == "stream_event" then
                    if .event.type == "content_block_start"
                       and .event.content_block.type == "tool_use" then
                        "\n🔧 " + (.event.content_block.name // "tool") + "\n"
                    elif .event.type == "content_block_delta"
                         and .event.delta.type == "text_delta" then
                        .event.delta.text
                    else empty end
                elif .type == "result" then
                    "\n✓ turn complete (" + ((.duration_ms // 0 | tostring) + "ms, $" + (.total_cost_usd // 0 | tostring)) + ")\n"
                else empty end'
        RC=${PIPESTATUS[0]}

        # Extract the assembled assistant text (every `assistant` event
        # carries .message.content[] with fully-built text blocks). Used
        # below for whole-line marker matching.
        jq -r '
            select(.type == "assistant")
            | .message.content[]?
            | select(.type == "text")
            | .text
        ' < "$RAW_OUTPUT" 2>/dev/null > "$OUTPUT_FILE"
        rm -f "$RAW_OUTPUT" 2>/dev/null || true
        rm -f "$PROMPT_FILE" 2>/dev/null || true

        echo "[$(date -u +%FT%TZ)] iter $ITER: claude exit=$RC" >> "$LOG" 2>/dev/null || true

        # Update state.json iteration + lastActivityAt (hook may have already,
        # but this guarantees it even if hooks were disabled).
        tmp="$(mktemp 2>/dev/null)" && \
            jq ".iterations = $ITER | .phase = \"working\" | .lastActivityAt = (now|floor)" \
            "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null

        # Sprint marker: increment sprints counter for the UI.
        # $OUTPUT_FILE was built by jq above from the assembled assistant
        # .message.content[].text blocks, so whole-line matching works
        # cleanly — no PTY CRLF to strip.
        if [ "$MODE" = "sprint" ] && [ -s "$OUTPUT_FILE" ] && \
           grep -qFx -- "$SPRINT_MARKER" "$OUTPUT_FILE" 2>/dev/null; then
            tmp="$(mktemp 2>/dev/null)" && \
                jq '.sprints += 1' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
            echo "[$(date -u +%FT%TZ)] iter $ITER: sprint marker detected" >> "$LOG" 2>/dev/null || true
        fi

        # Completion marker: exit the loop.
        if [ -s "$OUTPUT_FILE" ] && \
           grep -qFx -- "$DONE_MARKER" "$OUTPUT_FILE" 2>/dev/null; then
            rm -f "$ACTIVE_FLAG" "$OUTPUT_FILE" 2>/dev/null || true
            tmp="$(mktemp 2>/dev/null)" && \
                jq '.phase = "completed"' "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null
            echo "[$(date -u +%FT%TZ)] iter $ITER: $DONE_MARKER detected" >> "$LOG" 2>/dev/null || true
            echo ""
            echo "=== Tado Eternal: task complete ($DONE_MARKER) ==="
            break
        fi

        rm -f "$OUTPUT_FILE" 2>/dev/null || true

        # Brief pause to let disk I/O settle and yield CPU. Also gives the
        # watchdog a chance to see lastActivityAt move.
        sleep 2
    done

    { date -u +"%FT%TZ eternal-loop.sh exit"; echo ""; } >> "$LOG" 2>/dev/null || true
    exit 0
    """##

    // MARK: - .claude/settings.json merge

    /// Hook command strings are presence-gated by the per-run `active` marker
    /// so they're no-ops unless the invoking worker is live. Dispatches on the
    /// `TADO_ETERNAL_RUN_ID` env var that `ProcessSpawner.eternalWorkerEnv`
    /// sets on every worker spawn — architect + interventor tiles leave it
    /// empty, so their hook invocations short-circuit to `exit 0`.
    ///
    /// Wrapper shape (run-scoped):
    /// `[ -n "$RUN" ] && [ -f ".tado/eternal/runs/$RUN/active" ] && exec <script>; exit 0`.
    ///   • `exec` replaces the bash wrapper with the hook script, so the
    ///     hook's real exit code (0 / 2 for block) propagates unchanged.
    ///   • If `TADO_ETERNAL_RUN_ID` is empty OR the run's active flag is
    ///     missing, we skip to `exit 0` — idle tiles never show "hook error:
    ///     non-blocking status code" noise.
    ///   • Hook scripts themselves live project-level under
    ///     `.tado/eternal/hooks/` (one copy per project, shared across all
    ///     concurrent runs) and read `$TADO_ETERNAL_RUN_ID` to resolve
    ///     per-run file paths. The env-var is the ONLY thing that differs
    ///     between concurrent workers' hook invocations.
    private static let stopHookCmd = #"bash -c 'RUN="${TADO_ETERNAL_RUN_ID:-}"; [ -n "$RUN" ] && [ -f ".tado/eternal/runs/$RUN/active" ] && exec .tado/eternal/hooks/stop.sh; exit 0'"#
    private static let sessionStartHookCmd = #"bash -c 'RUN="${TADO_ETERNAL_RUN_ID:-}"; [ -n "$RUN" ] && [ -f ".tado/eternal/runs/$RUN/active" ] && exec .tado/eternal/hooks/session-start-compact.sh; exit 0'"#
    private static let preCompactHookCmd = #"bash -c 'RUN="${TADO_ETERNAL_RUN_ID:-}"; [ -n "$RUN" ] && [ -f ".tado/eternal/runs/$RUN/active" ] && exec .tado/eternal/hooks/pre-compact.sh; exit 0'"#
    private static let postToolHookCmd = #"bash -c 'RUN="${TADO_ETERNAL_RUN_ID:-}"; [ -n "$RUN" ] && [ -f ".tado/eternal/runs/$RUN/active" ] && exec .tado/eternal/hooks/post-tool.sh; exit 0'"#

    /// Baseline allowlist merged into `permissions.allow`. Idempotent — we
    /// check membership by exact string match before appending.
    ///
    /// Wildcarded on purpose for Eternal — a ralph-loop style session stalls
    /// on any prompt, so the allowlist intentionally covers everything.
    /// `--dangerously-skip-permissions` already neuters prompts at runtime;
    /// this list is a belt-and-suspenders layer so even without the flag
    /// (e.g. if the user turns Full Auto off) the session rarely halts.
    ///
    /// MCP patterns use `mcp__*` which matches any MCP server's tools.
    /// Patterns merged into the project-scoped `.claude/settings.json`'s
    /// `permissions.allow` list. These are the tools Tado-spawned Claude
    /// Code sessions should never be prompted about.
    ///
    /// Expanded for auto-mode: each entry in `protectedPathAllowList`
    /// auto-approves writes that bypassPermissions used to prompt on.
    /// Under auto mode there is no hard-coded protected-path exception —
    /// anything not explicitly allow-listed goes through the classifier.
    private static let baselineAllowList = [
        "Bash(*)",
        "Edit",
        "Write",
        "Read",
        "Glob",
        "Grep",
        "WebFetch",
        "WebSearch",
        "NotebookEdit",
        "TodoWrite",
        "Task",
        "mcp__*",
    ] + protectedPathAllowList

    /// Writes that bypass mode's exception list forced prompts on —
    /// `.git`, `.claude`, `.vscode`, `.idea`, `.husky`. Under auto mode
    /// we pre-allow them deterministically so an Eternal worker that
    /// routinely touches them (e.g. updating `.claude/agents/<name>.md`,
    /// writing git hooks, or pre-creating VS Code / JetBrains project
    /// metadata) never stalls on a dialog.
    private static let protectedPathAllowList = [
        "Edit(./.git/**)",
        "Write(./.git/**)",
        "Edit(./.claude/**)",
        "Write(./.claude/**)",
        "Edit(./.vscode/**)",
        "Write(./.vscode/**)",
        "Edit(./.idea/**)",
        "Write(./.idea/**)",
        "Edit(./.husky/**)",
        "Write(./.husky/**)",
    ]

    /// Natural-language trust descriptors for Claude Code's auto-mode
    /// classifier. The classifier reads these as prose when deciding
    /// whether an action is "external" (potential exfiltration) or
    /// "routine local work". See
    /// https://code.claude.com/docs/en/permissions#configure-the-auto-mode-classifier
    /// for the full spec. These descriptors get merged into both the
    /// user-scope and project-local settings at install time.
    private static let autoModeEnvironment = [
        "Organization: local developer machine. Primary use: software development driven by the Tado macOS app, which spawns long-lived `claude` sessions as terminal tiles.",
        "Trusted source control: this project's git remote (typically GitHub / GitLab over HTTPS or SSH). Pushing to the project's own origin is routine, not exfiltration.",
        "Trusted local filesystem: the project root and everything under it — including `.git`, `.claude`, `.vscode`, `.idea`, `.husky`, `node_modules`, `.venv`, and `.build`. Tado agents routinely edit these as part of normal workflow.",
        "Trusted MCP servers: any tool matching `mcp__*`. The user wires MCP servers explicitly in `~/.claude/settings.json`; anything exposed there is trusted.",
        "Trusted package managers and build tools: npm, pnpm, yarn, bun, pip, uv, cargo, swift, brew, gem, go. Package install, update, audit, and build operations are routine.",
        "Additional context: Tado's Eternal feature runs unattended for hours or days. Err on the side of autonomy for reversible, in-scope operations. Bash commands like `rm -rf <path-under-project>` are legitimate cleanup within the project; Bash commands that reach outside the project root (into `/usr`, `/System`, user home outside the project) are NOT routine and should still be gated.",
    ]

    private static func mergeClaudeSettings(_ project: Project) throws {
        let fm = FileManager.default
        let settingsURL = claudeSettingsURL(project)
        try fm.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        // Merge hooks. Strip any existing entries whose inner command
        // points at .tado/eternal/hooks/ — those are ours from previous
        // installs, possibly with an out-of-date wrapper pattern. Removing
        // them before merge lets us evolve the wrapper over time without
        // leaving stale entries that fire in parallel and log errors.
        // (The original bug: old "test -f active && hook.sh" wrappers
        // exited 1 when active was absent, showing "hook error: non-
        // blocking status code" on every tool call during architect runs.)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in ["Stop", "SessionStart", "PreCompact", "PostToolUse"] {
            let raw = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = stripTadoHookEntries(from: raw)
        }
        hooks["Stop"] = mergedHookArray(
            existing: hooks["Stop"] as? [[String: Any]] ?? [],
            command: stopHookCmd,
            timeout: 30,
            matcher: nil
        )
        hooks["SessionStart"] = mergedHookArray(
            existing: hooks["SessionStart"] as? [[String: Any]] ?? [],
            command: sessionStartHookCmd,
            timeout: 30,
            matcher: "compact"
        )
        hooks["PreCompact"] = mergedHookArray(
            existing: hooks["PreCompact"] as? [[String: Any]] ?? [],
            command: preCompactHookCmd,
            timeout: 10,
            matcher: nil
        )
        hooks["PostToolUse"] = mergedHookArray(
            existing: hooks["PostToolUse"] as? [[String: Any]] ?? [],
            command: postToolHookCmd,
            timeout: 10,
            matcher: nil
        )
        root["hooks"] = hooks

        // Merge allowlist
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        for pattern in baselineAllowList where !allow.contains(pattern) {
            allow.append(pattern)
        }
        permissions["allow"] = allow
        root["permissions"] = permissions

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Broader permissions allowlist used for user + project-local scopes.
    /// Wider than `baselineAllowList` because those two files are entirely
    /// under the user's control — they live in the user's home / local
    /// project and are not committed. We can afford to wildcard more
    /// aggressively here since the purpose is "Tado sessions never prompt".
    ///
    /// Still includes the protected-path entries from
    /// `protectedPathAllowList` so even a user who deleted the project-
    /// scope `.claude/settings.json` keeps auto-approval on `.git` /
    /// `.claude` writes.
    private static let autoModeAllowList = [
        "Bash(*)",
        "Edit(**)",
        "Write(**)",
        "Read(**)",
        "Glob",
        "Grep",
        "WebFetch",
        "WebSearch",
        "NotebookEdit",
        "TodoWrite",
        "Task",
        "mcp__*",
    ] + protectedPathAllowList

    /// Merge Tado's auto-mode keys into an existing settings JSON object.
    /// Non-destructive: existing user keys we don't own are left alone,
    /// existing entries in `permissions.allow` and `autoMode.environment`
    /// are preserved and extended, `defaultMode` is upgraded to `"auto"`.
    ///
    /// Auto mode replaces the old `bypassPermissions` + skip-danger flag
    /// combo. It's the official Claude Code autonomy mode as of late
    /// Apr 2026 — each tool call runs through a safety classifier, with
    /// the `autoMode.environment` prose + `permissions.allow` rules
    /// teaching the classifier what's routine vs. out-of-scope.
    private static func mergeAutoModeKeys(into root: inout [String: Any]) {
        var permissions = root["permissions"] as? [String: Any] ?? [:]

        // `defaultMode`: set to "auto" unconditionally. Users who
        // deliberately picked a stricter scope can override in their
        // own settings, which take precedence for their own sessions;
        // Tado spawns always pass `--permission-mode auto` on the CLI
        // anyway, so this key is mostly for bare `claude` invocations.
        permissions["defaultMode"] = "auto"

        var allow = permissions["allow"] as? [String] ?? []
        for pattern in autoModeAllowList where !allow.contains(pattern) {
            allow.append(pattern)
        }
        permissions["allow"] = allow
        root["permissions"] = permissions

        // Seed the auto-mode classifier with Tado's trust context. The
        // classifier reads these as natural language; entries get
        // de-duplicated case-sensitively before merge.
        var autoMode = root["autoMode"] as? [String: Any] ?? [:]
        var environment = autoMode["environment"] as? [String] ?? []
        for line in autoModeEnvironment where !environment.contains(line) {
            environment.append(line)
        }
        autoMode["environment"] = environment
        root["autoMode"] = autoMode
    }

    /// Write/merge `~/.claude/settings.json` so every Claude Code session on
    /// this machine inherits bypass + the wide allowlist + the no-prompt
    /// flag. Idempotent: reads existing JSON, merges, writes atomically,
    /// never deletes keys we don't own.
    static func writeUserScopeSettings() {
        let fm = FileManager.default
        let url = userClaudeSettingsURL()
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        mergeAutoModeKeys(into: &root)

        if let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Write/merge `<projectRoot>/.claude/settings.local.json` — the
    /// gitignored "local" scope. Belt-and-suspenders on top of
    /// `writeUserScopeSettings`: even if the user blows away their user
    /// settings, each project Tado touches retains local coverage.
    static func writeProjectLocalSettings(_ project: Project) {
        let fm = FileManager.default
        let url = claudeLocalSettingsURL(project)
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        mergeAutoModeKeys(into: &root)

        if let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Remove any entry whose inner `hooks[].command` references our
    /// `.tado/eternal/hooks/` scripts. Used by `mergeClaudeSettings` to
    /// clear out previous installs before writing the current wrapper
    /// pattern — otherwise changes to the wrapper syntax (e.g. moving
    /// from `test -f …` to `[ -f …] && exec …; exit 0`) leave stale
    /// entries that continue firing alongside the new one.
    ///
    /// Match is substring-based on the tado-owned path fragment so we
    /// match both past and future wrapper shapes without false positives
    /// against the user's own hooks.
    private static func stripTadoHookEntries(
        from existing: [[String: Any]]
    ) -> [[String: Any]] {
        existing.filter { entry in
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            for h in inner {
                if let cmd = h["command"] as? String,
                   cmd.contains(".tado/eternal/hooks/") {
                    return false
                }
            }
            return true
        }
    }

    /// Merge one hook entry into the existing array for an event. Idempotent
    /// by exact command-string match — we only append if no existing entry
    /// already runs the same command.
    ///
    /// The hook-object shape follows Claude Code's settings.json schema:
    /// `[{ "matcher"?: "...", "hooks": [{ "type": "command", "command": "...", "timeout": N }] }]`
    private static func mergedHookArray(
        existing: [[String: Any]],
        command: String,
        timeout: Int,
        matcher: String?
    ) -> [[String: Any]] {
        // Already present?
        for entry in existing {
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            for h in inner {
                if (h["command"] as? String) == command {
                    return existing
                }
            }
        }

        var entry: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": timeout,
            ]]
        ]
        if let matcher {
            entry["matcher"] = matcher
        }

        var merged = existing
        merged.append(entry)
        return merged
    }

    // MARK: - Spawn architect (stage 1)

    /// Spawn the Eternal Architect tile. Reads `user-brief.md` the modal
    /// wrote, produces `.tado/eternal/crafted.md` (the worker's authoritative
    /// brief), then naturally exits. Pinned to Opus 4.7 / max effort — this
    /// is the one-shot planning pass that the whole infinite loop hinges on.
    ///
    /// Called from the modal's Accept path. Sets `eternalState = "planning"`
    /// so the section flips to the planning card. The section polls for
    /// `crafted.md` and flips to `ready` when it appears.
    @MainActor
    static func spawnArchitect(
        run: EternalRun,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        guard let project = run.project else { return }

        resetEternal(run)

        // Write the raw user brief to user-brief.md so the architect has
        // something concrete to read. If the brief is empty we still write
        // an empty file — the architect prompt handles missing content.
        try? FileManager.default.createDirectory(
            at: eternalRoot(run),
            withIntermediateDirectories: true
        )
        let rawBrief = run.userBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        try? rawBrief.write(to: userBriefFileURL(run), atomically: true, encoding: .utf8)

        // Install hooks + allowlist now so the architect's own sessions don't
        // get prompted to death. Architect sessions don't set
        // TADO_ETERNAL_RUN_ID so their hook invocations short-circuit; the
        // allowlist is the thing that actually matters for architect tool use.
        try? installHooks(project)

        // Build the architect prompt. Mode carries through so the architect
        // knows whether to emit Sprint or Mega crafted.md. The prompt uses
        // `.tado/eternal/runs/<id>/user-brief.md` and writes
        // `.tado/eternal/runs/<id>/crafted.md` — see ProcessSpawner.
        let prompt = ProcessSpawner.eternalArchitectPrompt(
            projectName: project.name,
            projectRoot: project.rootPath,
            mode: run.mode,
            runID: run.id
        )

        // Allocate grid + spawn.
        let index = nextAvailableGridIndex(modelContext: modelContext)
        let settings = fetchOrCreateSettings(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        modelContext.insert(todo)

        // Save state BEFORE handing off to the spawn pipeline so any observer
        // that re-renders on session append sees `planning`, not a stale
        // `drafted`. Same rationale for `architectTodoID`: it needs to be
        // on the run before the tile's first render.
        run.state = "planning"
        run.architectTodoID = todo.id
        // Clear the worker-todo id — we're starting fresh. If the user is
        // redoing from a previous ready/completed state, old worker refs
        // shouldn't leak into the new run.
        run.workerTodoID = nil
        try? modelContext.save()

        // Pin Opus 4.7 + max effort for the architect. Permission mode comes
        // from the run's Full-Auto toggle (default on).
        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: project.rootPath,
            projectName: project.name,
            modeFlagsOverride: ProcessSpawner.eternalPermissionFlags(
                skipPermissions: run.skipPermissions
            ),
            modelFlagsOverride: ["--model", ClaudeModel.opus47.rawValue],
            effortFlagsOverride: ["--effort", ClaudeEffort.max.rawValue],
            eternalRunID: run.id,
            runRole: "architect"
        )

        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    // MARK: - Spawn interventor (ad-hoc, while worker is running)

    /// Spawn the Eternal Interventor tile. Takes the user's raw message
    /// (from the Intervene modal), asks a short-lived Haiku agent to
    /// ground it in the worker's current state and write a distilled
    /// directive to `.tado/eternal/inbox/intervene-<ts>.md`. The running
    /// worker drains that inbox at the top of its next iteration and
    /// incorporates the directive.
    ///
    /// Called from the modal's Accept path while the worker is running.
    /// Does NOT reset any state or touch crafted.md. Does NOT mark active —
    /// `active` is already present (worker is running). The interventor's
    /// own hooks are presence-gated no-ops because they're not the worker.
    @MainActor
    static func spawnInterventor(
        run: EternalRun,
        userMessage: String,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        guard let project = run.project else { return }

        // Make sure the inbox directory exists before the interventor
        // spawns — saves one round trip of "the file doesn't exist" and
        // avoids any chance of a permission prompt on protected paths.
        try? FileManager.default.createDirectory(
            at: inboxDirURL(run),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: inboxProcessedDirURL(run),
            withIntermediateDirectories: true
        )

        // installHooks is idempotent and cheap; re-running it makes sure
        // settings + permission allowlist are fresh for the interventor's
        // session. Worker's `active` marker stays intact.
        try? installHooks(project)

        // Pass the run UUID through the prompt so the interventor writes to
        // the correct run's inbox. The interventor is a Haiku tile that
        // doesn't set TADO_ETERNAL_RUN_ID (so its own hooks no-op); instead
        // it reads the run id from its prompt text.
        let prompt = ProcessSpawner.eternalInterventorPrompt(
            projectName: project.name,
            projectRoot: project.rootPath,
            userMessage: userMessage,
            runID: run.id
        )

        let index = nextAvailableGridIndex(modelContext: modelContext)
        let settings = fetchOrCreateSettings(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        modelContext.insert(todo)
        try? modelContext.save()

        // Pin Haiku 4.5 / high. This is a note-distillation job, not
        // planning — no need for Opus. Same permission-mode flags as the
        // worker so the interventor can Write to the inbox without
        // prompts.
        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: project.rootPath,
            projectName: project.name,
            modeFlagsOverride: ProcessSpawner.eternalPermissionFlags(
                skipPermissions: run.skipPermissions
            ),
            modelFlagsOverride: ["--model", ClaudeModel.haiku45.rawValue],
            effortFlagsOverride: ["--effort", ClaudeEffort.high.rawValue],
            eternalRunID: run.id,
            runRole: "interventor"
        )

        // Nav to canvas so the user sees the interventor tile confirming
        // their message was captured. Worker tile stays alive below it.
        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    // MARK: - Spawn worker (stage 2)

    /// Spawn the Eternal worker after the architect has produced `crafted.md`.
    /// The worker reads crafted.md each iteration as the source of truth;
    /// the user's raw brief is preserved in `user-brief.md` for audit but
    /// isn't what the worker runs against.
    ///
    /// Called from the section's Start button in `ready` state. Writes the
    /// initial state.json, markActive, spawns the tile.
    ///
    /// The spawn uses Tado's external-loop wrapper
    /// (`.tado/eternal/hooks/eternal-loop.sh`) rather than invoking
    /// `claude` directly. That's what makes the session truly eternal:
    /// Claude Code has an in-session Stop-hook recursion counter that
    /// caps at ~20-30 block cycles and forces a clean exit. By
    /// relaunching `claude -p "..."` in a shell loop, each iteration is
    /// a fresh session with the counter reset — the wrapper can run for
    /// days without tripping that safety.
    ///
    /// No in-process supervision after spawn — the `EternalWatchdog`
    /// timer polls state.json every 15 min and respawns if the wrapper
    /// appears wedged.
    @MainActor
    static func spawnWorker(
        run: EternalRun,
        modelContext: ModelContext,
        terminalManager: TerminalManager,
        appState: AppState
    ) {
        guard let project = run.project else { return }

        // Seed the progress log with a starting line so the compaction hook
        // has something to re-inject even on a very short first iteration.
        let now = ISO8601DateFormatter().string(from: Date())
        let seed = "\(now): Eternal worker started — mode=\(run.mode)\n"
        try? FileManager.default.createDirectory(
            at: eternalRoot(run),
            withIntermediateDirectories: true
        )
        try? seed.write(to: progressFileURL(run), atomically: true, encoding: .utf8)

        if run.mode == "sprint" {
            // Empty metrics file so `tail` doesn't error on first read.
            try? Data().write(to: metricsFileURL(run))
        }

        // Initial state.json
        let started = Date().timeIntervalSince1970
        let initial = EternalState(
            mode: run.mode,
            startedAt: started,
            lastActivityAt: started,
            iterations: 0,
            sprints: 0,
            compactions: 0,
            phase: "working",
            lastProgressNote: nil,
            lastMetric: nil,
            completionMarker: run.completionMarker,
            sprintMarker: "[SPRINT-DONE]"
        )
        try? writeInitialState(initial, run: run)

        try? installHooks(project)
        try? markActive(run)

        // Build the worker prompt. Both builders now reference crafted.md as
        // the source brief — the worker reads that file every iteration. The
        // run id is embedded so the prompt can point the agent at the correct
        // per-run paths (`.tado/eternal/runs/<id>/...`).
        let prompt: String
        if run.mode == "sprint" {
            prompt = ProcessSpawner.eternalSprintPrompt(
                projectName: project.name,
                projectRoot: project.rootPath,
                marker: run.completionMarker,
                sprintMarker: "[SPRINT-DONE]",
                runID: run.id
            )
        } else {
            prompt = ProcessSpawner.eternalMegaPrompt(
                projectName: project.name,
                projectRoot: project.rootPath,
                marker: run.completionMarker,
                runID: run.id
            )
        }

        let index = nextAvailableGridIndex(modelContext: modelContext)
        let settings = fetchOrCreateSettings(modelContext: modelContext)
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)

        let todo = TodoItem(text: prompt, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        modelContext.insert(todo)

        // Save state BEFORE spawning so the section observer sees `running`
        // in the first body evaluation.
        run.state = "running"
        run.workerTodoID = todo.id
        try? modelContext.save()

        // Worker spawns depending on the run's loopKind:
        //   - "external" (default): goes through the eternal-loop.sh
        //     wrapper, which respawns `claude -p "..."` every turn.
        //     Fresh context per iteration, cheap tokens, recursion
        //     counter resets each cycle.
        //   - "internal": spawns `claude --permission-mode auto`
        //     directly (no wrapper), with a continuation prompt Tado
        //     re-injects every time the session goes `.needsInput`.
        //     The initial `todo.text` holds the eternal prompt that
        //     kicks off the first turn; `eternalContinuePrompt` is
        //     what Tado types for every subsequent iteration.
        //
        // Model/effort come from the user's AppSettings default, EXCEPT for
        // internal-mode workers. Internal mode ran via `claude
        // --permission-mode auto`, which gates its classifier on Opus 4.7 +
        // a Max/Teams/Enterprise plan per the official announcement. Sending
        // `--permission-mode auto --model haiku` silently no-ops the
        // classifier and stalls on the first permission prompt — the exact
        // "babysitting" failure auto mode was built to remove. Hard-override
        // to Opus 4.7 here so a non-Opus default in Settings doesn't footgun
        // a Continuous run. External mode still honors the user's pick
        // because its per-turn `claude -p` wrapper doesn't need auto mode.
        let loopKind = (run.loopKind == "internal") ? "internal" : "external"
        let workerModelID: String = (loopKind == "internal")
            ? ClaudeModel.opus47.rawValue
            : settings.claudeModel.rawValue
        let continuePrompt: String? = loopKind == "internal"
            ? internalContinuePrompt(run: run, runDir: eternalRoot(run).path)
            : nil
        terminalManager.spawnAndWire(
            todo: todo,
            engine: .claude,
            cwd: project.rootPath,
            projectName: project.name,
            isEternalWorker: true,
            eternalLoopKind: loopKind,
            eternalMode: run.mode,
            eternalDoneMarker: run.completionMarker,
            eternalModelID: workerModelID,
            eternalEffortLevel: settings.claudeEffort.rawValue,
            eternalSkipPermissionsFlag: run.skipPermissions,
            eternalContinuePrompt: continuePrompt,
            eternalRunID: run.id,
            runRole: "worker"
        )

        appState.pendingNavigationID = todo.id
        // No currentView flip — user is on the project detail page when they
        // click Start. The section re-renders as the running card. They can
        // click "Watch on Canvas" for the tile stream.
    }

    // MARK: - Internal-mode continuation helpers

    /// The prompt Tado re-injects into an internal-mode session every
    /// time it goes `.needsInput`. Grounded in the run's files so the
    /// agent knows exactly what to read and what to append — no
    /// guessing.
    ///
    /// The same text is passed to Claude Code's built-in `/loop` as the
    /// secondary driver (see `internalLoopCommand`), so both layers
    /// deliver identical instructions.
    static func internalContinuePrompt(run: EternalRun, runDir: String) -> String {
        let marker = run.completionMarker
        let sprintFragment = run.mode == "sprint"
            ? " End a sprint by outputting `[SPRINT-DONE]` on its own line; the loop then starts the next sprint."
            : ""
        return """
        [TADO ETERNAL · continue] Read \(runDir)/crafted.md, tail \(runDir)/progress.md \
        for your last state, then do the NEXT unit of work. Before ending this turn, \
        append ONE line to \(runDir)/progress.md in the format `YYYY-MM-DD HH:MM: <one sentence>`. \
        The last progress.md line in the next iteration's prompt should advance from this one. \
        Output `\(marker)` on its own line ONLY when the entire task is fully complete.\(sprintFragment)
        """
    }

    /// Slash-command Tado types into an internal-mode session once the
    /// first user turn completes, as the secondary continuation driver
    /// (primary is Tado's own idle-injection).
    ///
    /// Uses Claude Code's built-in `/loop <interval> <prompt>` feature,
    /// which fires `<prompt>` on the given interval for up to 1 week.
    /// If the user's Claude Code build doesn't support `/loop`, typing
    /// it is a harmless no-op (Claude Code treats unknown slash commands
    /// as plain text, which the agent can ignore) — Tado's idle-
    /// injection primary driver handles continuation either way.
    static func internalLoopCommand(run: EternalRun, runDir: String) -> String {
        let payload = internalContinuePrompt(run: run, runDir: runDir)
        return "/loop 30s \(payload)"
    }

    // MARK: - Startup migrations / reconciliation

    /// One-shot pass: for every Project with non-idle legacy eternal or
    /// dispatch state (or with legacy on-disk state files), create the
    /// corresponding `EternalRun` / `DispatchRun` row and move the legacy
    /// files into `.tado/eternal/runs/<id>/` / `.tado/dispatch/runs/<id>/`.
    /// Running workers demote to `stopped` (their in-memory bash wrappers
    /// reference the pre-move paths and can't be hot-migrated; restart
    /// manually).
    ///
    /// Gated by `AppSettings.didMigrateToMultipleRuns`. Idempotent after
    /// the first successful run — subsequent launches return immediately.
    @MainActor
    static func migrateToMultipleRuns(modelContext: ModelContext) {
        let settingsDescriptor = FetchDescriptor<AppSettings>()
        let settings: AppSettings
        if let existing = try? modelContext.fetch(settingsDescriptor).first {
            settings = existing
        } else {
            let fresh = AppSettings()
            modelContext.insert(fresh)
            settings = fresh
        }
        if settings.didMigrateToMultipleRuns { return }

        let projectDescriptor = FetchDescriptor<Project>()
        let projects = (try? modelContext.fetch(projectDescriptor)) ?? []
        let fm = FileManager.default

        for project in projects {
            migrateLegacyEternalState(project: project, modelContext: modelContext, fileManager: fm)
            migrateLegacyDispatchState(project: project, modelContext: modelContext, fileManager: fm)
        }

        settings.didMigrateToMultipleRuns = true
        try? modelContext.save()
    }

    /// Move one project's legacy `.tado/eternal/{state.json,…}` into
    /// `.tado/eternal/runs/<new-run-uuid>/` and create the EternalRun row.
    /// Called from `migrateToMultipleRuns`.
    @MainActor
    private static func migrateLegacyEternalState(
        project: Project,
        modelContext: ModelContext,
        fileManager fm: FileManager
    ) {
        let legacyRoot = URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".tado")
            .appendingPathComponent("eternal")
        let legacyStateFile = legacyRoot.appendingPathComponent("state.json")
        let legacyCrafted = legacyRoot.appendingPathComponent("crafted.md")
        let legacyUserBrief = legacyRoot.appendingPathComponent("user-brief.md")
        let hasLegacyFiles =
            fm.fileExists(atPath: legacyStateFile.path) ||
            fm.fileExists(atPath: legacyCrafted.path) ||
            fm.fileExists(atPath: legacyUserBrief.path)
        let hasLegacyDbState =
            project.eternalState != "idle" && !project.eternalState.isEmpty

        guard hasLegacyFiles || hasLegacyDbState else { return }

        // Compose the new run from whatever legacy state we have. Every
        // optional falls back to the sensible default on EternalRun's init.
        let run = EternalRun(
            id: UUID(),
            project: project,
            label: EternalRun.defaultLabel(
                mode: project.eternalMode.isEmpty ? "mega" : project.eternalMode,
                createdAt: project.createdAt
            ),
            createdAt: project.createdAt,
            state: project.eternalState.isEmpty ? "idle" : project.eternalState,
            mode: project.eternalMode.isEmpty ? "mega" : project.eternalMode,
            loopKind: project.eternalLoopKind.isEmpty ? "external" : project.eternalLoopKind,
            completionMarker: project.eternalCompletionMarker.isEmpty
                ? "ETERNAL-DONE" : project.eternalCompletionMarker,
            sprintEval: project.eternalSprintEval,
            sprintImprove: project.eternalSprintImprove,
            skipPermissions: project.eternalSkipPermissions,
            userBrief: project.eternalMarkdown,
            workerTodoID: project.eternalTodoID,
            architectTodoID: project.eternalArchitectTodoID
        )
        modelContext.insert(run)

        // Move the files. `hooks/` STAYS at project-level — don't touch it.
        // Same for `trials/` which is per-project forensic data.
        let runDir = eternalRoot(run)
        try? fm.createDirectory(at: runDir, withIntermediateDirectories: true)

        let movables = [
            "state.json", "progress.md", "metrics.jsonl",
            "active", "stop-flag",
            "user-brief.md", "crafted.md", "eternal.md",
            "hooks.log", "loop.log",
            "inbox", "inbox-processed",
        ]
        for name in movables {
            let from = legacyRoot.appendingPathComponent(name)
            let to = runDir.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }

        // In-flight bash wrappers reference the old paths. Demote and tell
        // the user to restart. The active flag has just moved into the run
        // dir; wipe it so the next spawn starts clean.
        if run.state == "running" {
            run.state = "stopped"
            try? fm.removeItem(at: activeFlagURL(run))
        }

        NSLog("EternalService: migrated \(project.name) legacy eternal → run \(run.id)")
    }

    /// Move one project's legacy `.tado/dispatch/{dispatch.md,plan.json,phases/}`
    /// into `.tado/dispatch/runs/<new-run-uuid>/` and create the DispatchRun row.
    @MainActor
    private static func migrateLegacyDispatchState(
        project: Project,
        modelContext: ModelContext,
        fileManager fm: FileManager
    ) {
        let legacyRoot = URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".tado")
            .appendingPathComponent("dispatch")
        let legacyDispatch = legacyRoot.appendingPathComponent("dispatch.md")
        let legacyPlan = legacyRoot.appendingPathComponent("plan.json")
        let legacyPhases = legacyRoot.appendingPathComponent("phases")
        let hasLegacyFiles =
            fm.fileExists(atPath: legacyDispatch.path) ||
            fm.fileExists(atPath: legacyPlan.path) ||
            fm.fileExists(atPath: legacyPhases.path)
        let hasLegacyDbState =
            project.dispatchState != "idle" && !project.dispatchState.isEmpty

        guard hasLegacyFiles || hasLegacyDbState else { return }

        let run = DispatchRun(
            id: UUID(),
            project: project,
            label: DispatchRun.defaultLabel(createdAt: project.createdAt),
            createdAt: project.createdAt,
            state: project.dispatchState.isEmpty ? "idle" : project.dispatchState,
            brief: project.dispatchMarkdown
        )
        modelContext.insert(run)

        let runDir = DispatchPlanService.dispatchRoot(run)
        try? fm.createDirectory(at: runDir, withIntermediateDirectories: true)

        for name in ["dispatch.md", "plan.json", "phases"] {
            let from = legacyRoot.appendingPathComponent(name)
            let to = runDir.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }

        // Dispatch has no mid-run concept to demote — phases run in their
        // own tiles and don't depend on file paths after the architect
        // wrote them.

        NSLog("DispatchPlanService: migrated \(project.name) legacy dispatch → run \(run.id)")
    }

    /// One-shot pass: flip every Project's `eternalSkipPermissions` to true
    /// if the migration flag is still false. Catches projects created before
    /// the default was flipped. Safe to call on every launch — returns
    /// immediately once the flag is true.
    @MainActor
    static func migrateEternalDefaults(modelContext: ModelContext) {
        let settingsDescriptor = FetchDescriptor<AppSettings>()
        let settings: AppSettings
        if let existing = try? modelContext.fetch(settingsDescriptor).first {
            settings = existing
        } else {
            let fresh = AppSettings()
            modelContext.insert(fresh)
            settings = fresh
        }
        if settings.didMigrateEternalDefaults { return }

        let projectDescriptor = FetchDescriptor<Project>()
        if let projects = try? modelContext.fetch(projectDescriptor) {
            for project in projects where !project.eternalSkipPermissions {
                project.eternalSkipPermissions = true
            }
        }
        settings.didMigrateEternalDefaults = true
        try? modelContext.save()
    }

    /// Every-launch pass: for every project whose `.tado/eternal/hooks/`
    /// exists, rewrite the on-disk wrapper + hook scripts from the current
    /// in-binary templates. Idempotent — it's a pure overwrite.
    ///
    /// Rationale: once a worker's bash loop is running, it has its copy of
    /// `eternal-loop.sh` loaded in memory and can't pick up source-code
    /// improvements we ship in a later Tado build. The already-running
    /// worker is stuck on the old wrapper until Stop + Start, which
    /// re-spawns and re-runs `installHooks()`. But if we rewrite the
    /// on-disk file at launch, the user only has to Stop + Start once to
    /// get the latest — they don't have to wait for a re-spawn *after*
    /// upgrading.
    @MainActor
    static func refreshAllHookScripts(modelContext: ModelContext) {
        let fm = FileManager.default
        let descriptor = FetchDescriptor<Project>()
        guard let projects = try? modelContext.fetch(descriptor) else { return }
        for project in projects {
            let hooksDir = hooksDirURL(project)
            guard fm.fileExists(atPath: hooksDir.path) else { continue }
            for (name, body) in hookScripts {
                let url = hooksDir.appendingPathComponent(name)
                try? body.write(to: url, atomically: true, encoding: .utf8)
                _ = try? fm.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o755))],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    /// Staleness threshold (seconds) beyond which state.json is treated as
    /// evidence of a live hook. The wrapper writes `lastActivityAt` every
    /// post-tool firing (at least once per agent turn); 90 s covers the
    /// longest legitimate Read/Write/Bash chains without resurrecting a
    /// truly dead wrapper.
    static let hookLivenessThreshold: TimeInterval = 90

    /// Phases that indicate the hook is doing work. `stopped` and `completed`
    /// are explicitly excluded so a cleanly-terminated sprint isn't
    /// resurrected by the freshness check — once the hook writes one of
    /// those, we honor it.
    static let activeHookPhases: Set<String> = ["working", "evaluating", "compacting"]

    /// Does state.json show the hook is alive AND the user hasn't asked to
    /// stop? Three gates, top-down:
    ///
    ///   1. **stop-flag absent** — `requestStop` creates this file when the
    ///      user clicks Stop. The wrapper only processes it on its next
    ///      iteration (which can be minutes out if a claude turn is long),
    ///      so during the window between click and processing state.json
    ///      still looks fresh. Honoring the flag here makes the UI stop
    ///      responding instantly; the wrapper will flip phase to "stopped"
    ///      eventually, by which point this short-circuit is redundant.
    ///   2. **lastActivityAt fresh** — the post-tool hook stamps this
    ///      every agent tool call; anything older than 90 s is treated as
    ///      silent (wrapper dead, orphaned, or user walked away).
    ///   3. **phase is active** — "working | evaluating | compacting".
    ///      The wrapper explicitly writes "stopped" or "completed" on its
    ///      terminal transitions; if we see those, respect them even if
    ///      the timestamp is fresh.
    ///
    /// Callers: `reconcileActiveFlagsOnLaunch`, `EternalWatchdog.tick`,
    /// `ProjectEternalSection.currentState`. All three use this as the
    /// single "is the wrapper really running" predicate so the three
    /// observers stay consistent.
    static func isHookFresh(_ run: EternalRun) -> Bool {
        if FileManager.default.fileExists(atPath: stopFlagURL(run).path) {
            return false
        }
        guard let state = readState(run),
              let staleness = state.secondsSinceActivity,
              staleness < hookLivenessThreshold else { return false }
        return activeHookPhases.contains(state.phase)
    }

    /// Scan the live session list for a terminal tile that belongs to this
    /// run. Matches on `eternalRunID` (set at spawn time by `spawnAndWire`).
    /// Used to rebind `run.workerTodoID` when reconciliation finds the old
    /// pointer stale but a matching tile is still running — avoids marking
    /// the run stopped just because the todo/session mapping drifted.
    @MainActor
    static func reattachIfAlive(
        run: EternalRun,
        terminalManager: TerminalManager
    ) -> Bool {
        guard let match = terminalManager.sessions.first(where: {
            $0.isEternalWorker
                && $0.eternalRunID == run.id
                && $0.isRunning
        }) else { return false }
        if run.workerTodoID != match.todoID {
            run.workerTodoID = match.todoID
        }
        return true
    }

    /// Every-launch pass: detect runs with `state == "running"` but no live
    /// TerminalSession for their `workerTodoID`. Mark those as `stopped`,
    /// remove the stale `active` marker, flip state.json phase to `stopped`.
    /// Solves the "Tado crashed mid-run → active flag poisons the next Claude
    /// session" problem.
    ///
    /// Soften: if state.json shows the hook is still writing fresh activity,
    /// the wrapper is alive even if the in-memory session mapping drifted.
    /// In that case we rebind `workerTodoID` when we can find a matching
    /// tile and leave the run running — state.json is the source of truth
    /// for liveness, not the Swift field.
    @MainActor
    static func reconcileActiveFlagsOnLaunch(
        modelContext: ModelContext,
        terminalManager: TerminalManager
    ) {
        let descriptor = FetchDescriptor<EternalRun>()
        guard let runs = try? modelContext.fetch(descriptor) else { return }
        var mutated = false
        for run in runs where run.state == "running" {
            let todoID = run.workerTodoID
            let hasLiveSession: Bool = {
                guard let todoID else { return false }
                return terminalManager.session(forTodoID: todoID) != nil
            }()
            if hasLiveSession { continue }

            if isHookFresh(run) {
                let rebound = reattachIfAlive(run: run, terminalManager: terminalManager)
                NSLog(
                    "EternalService: run \(run.label) session missing but state.json fresh — trusting hook (rebind: \(rebound))"
                )
                if rebound { mutated = true }
                continue
            }

            // The tile is gone and the hook has gone quiet — clean up.
            NSLog(
                "EternalService: reconcile run \(run.label) → stopped (no session, state.json stale or terminal)"
            )
            try? FileManager.default.removeItem(at: activeFlagURL(run))
            try? FileManager.default.removeItem(at: stopFlagURL(run))
            if let data = try? Data(contentsOf: stateFileURL(run)),
               var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obj["phase"] = "stopped"
                if let updated = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                    try? updated.write(to: stateFileURL(run), options: .atomic)
                }
            }
            run.state = "stopped"
            run.workerTodoID = nil
            mutated = true
        }
        if mutated {
            try? modelContext.save()
        }
    }

    @MainActor
    private static func nextAvailableGridIndex(modelContext: ModelContext) -> Int {
        let descriptor = FetchDescriptor<TodoItem>()
        let allTodos = (try? modelContext.fetch(descriptor)) ?? []
        let usedIndices = Set(allTodos.filter { $0.listState == .active }.map(\.gridIndex))
        var index = 0
        while usedIndices.contains(index) { index += 1 }
        return index
    }

    @MainActor
    private static func fetchOrCreateSettings(modelContext: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? modelContext.fetch(descriptor).first { return existing }
        let settings = AppSettings()
        modelContext.insert(settings)
        try? modelContext.save()
        return settings
    }
}
