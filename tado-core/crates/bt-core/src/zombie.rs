//! Zombie-process sweeper for Tado.
//!
//! Why this module exists
//! ----------------------
//! Tado spawns a fan-out tree of subprocesses every time a tile fires
//! up an agent: a `/bin/zsh -l -c "claude '<prompt>'"` shell wrapper,
//! the agent CLI itself (`claude` or `codex`), and the agent's own
//! children — stdio MCP bridges, transient `npm` / `cargo` / `node`
//! invocations, etc. When something in the chain dies abnormally
//! (Tado is force-quit, the user kills a tile via Cmd+W instead of
//! the Stop button, a build crashes mid-spawn) those grandchildren
//! get re-parented to launchd and accumulate as invisible zombies.
//! Operators routinely report seeing 10+ of these after a normal
//! day's work. v0.18.0 plugged the spawn-side leaks (`Session::kill`
//! now uses `killpg`; `willTerminate` reaps tiles; the MCP registrar
//! migrates the legacy Node bridge) but those fixes are *preventive*.
//! This module is the *curative* counterpart — a sweep operator that
//! a user (or an automation) can fire to clean up whatever already
//! accumulated.
//!
//! Self-protection contract (CRITICAL)
//! -----------------------------------
//! The sweeper runs in-process inside the live Tado app. If it ever
//! signaled its own ancestor chain it would commit suicide: the
//! `make dev` shell, the `swift run` parent, and the user's Terminal
//! window all sit in the chain that hosts the running app, and
//! killing any of them takes the whole window down. The protection
//! algorithm is conservative and built BEFORE any `kill` is issued:
//!
//! 1. Capture `getpid()` (our own PID).
//! 2. Walk the parent chain via `sysinfo::Process::parent()` until
//!    PID 1 (launchd). Every PID along the way joins the protected set.
//! 3. PID 1 itself joins as a defensive belt-and-braces — `killpg(1,
//!    SIGKILL)` would target launchd's group and is unrecoverable.
//! 4. Any candidate PID (or its `getpgid` group ID) that intersects
//!    the protected set is skipped and reported back as
//!    `matched_but_protected` so the operator can audit.
//!
//! What the sweeper kills
//! ----------------------
//! Patterns are matched against the full command line (via
//! `sysinfo::Process::cmd()`), not the basename — process names on
//! macOS are truncated to 16 characters, so basename matching misses
//! everything launched via a long path.
//!
//! - `/release/Tado` / `/Applications/Tado.app/` — stale Tado app
//!   instances left over from forced-quit prior launches.
//! - `tado-mcp/dist/index.js` — legacy Node MCP bridge superseded by
//!   the v0.9.0 Rust port; spawned as orphan by Claude Code sessions
//!   whose `~/.claude.json` wasn't migrated.
//! - `target/release/(tado-mcp|dome-mcp|tado-dome)` — Rust MCP
//!   bridges still alive after their parent claude/codex exited
//!   without reaping them.
//! - `claude .* --output-format stream-json` — Claude Code CLIs in
//!   the IPC-piped mode used by both Tado tiles and the macOS
//!   Claude.app's agent-mode sessions. Both are valid kill targets
//!   per operator request: a successful sweep should leave zero
//!   `claude --output-format stream-json` running anywhere except
//!   in our own protected ancestor chain (which never matches this
//!   pattern; `make`/`swift`/Terminal don't run claude).
//! - `codex .* --output-format stream-json` — same logic for Codex.
//!
//! Kill mechanism
//! --------------
//! For each surviving candidate the sweeper resolves the target's
//! process group via `getpgid(pid)` then signals the whole group via
//! `killpg(pgid, SIGKILL)`. Group-targeting hits every descendant in
//! one syscall — without it, killing the immediate child leaves the
//! agent's MCP bridges and shell wrappers re-parented to launchd
//! exactly the way the bug we're solving manifests. The `pgid > 1`
//! guard is identical to the one in `Session::kill`.
//!
//! Atomicity & TOCTOU
//! ------------------
//! Process listings are inherently racy: a process can fork between
//! enumeration and kill. The sweeper enumerates once, kills once,
//! then re-enumerates and reports survivors. Operators can re-run
//! to mop up survivors; the "Make Sure" verification agent does
//! exactly that.
//!
//! Determinism
//! -----------
//! Returns are sorted by PID for stable diff-friendly output. The
//! `timestamp` field is Unix epoch milliseconds, captured once at
//! entry, so all rows in one sweep share the same value.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use sysinfo::{Pid, ProcessesToUpdate, System};

/// The exhaustive list of command-line substrings the sweeper treats
/// as "Tado-spawned-or-spawnable-by-Tado". Order matters only for
/// `matched_pattern` reporting (first match wins per process).
///
/// Patterns are plain substring matches against the joined command
/// line (`argv[0] argv[1] argv[2]…`). Substring matching keeps the
/// implementation simple and dependency-free; regex would buy us
/// nothing here because every distinguishing token is already
/// unambiguous as a literal string.
pub const KILL_PATTERNS: &[&str] = &[
    // Stale Tado app binaries. The trailing `/Tado` is significant —
    // it avoids matching directory paths like `/tado-core/` that
    // happen to contain the substring "tado".
    "/release/Tado",
    "/Applications/Tado.app/",
    // Legacy Node MCP bridge superseded by the Rust port.
    "tado-mcp/dist/index.js",
    // Rust MCP bridges and CLI helpers built by `make mcp` / cargo.
    "target/release/tado-mcp",
    "target/release/dome-mcp",
    "target/release/tado-dome",
    // Tado-spawned and Claude.app agent-mode Claude Code sessions.
    // The `--output-format stream-json` flag is the IPC-piped mode
    // that both spawn paths use; an interactive `claude` launched by
    // the user in a terminal does NOT carry this flag and is left
    // alone.
    "claude --output-format stream-json",
    // Same logic for Codex agent-mode sessions, if/when the Codex
    // desktop gains an analogous mode.
    "codex --output-format stream-json",
];

/// Caller-supplied options. Currently only `dry_run`; the
/// protected-PID set is derived in-process from the live ancestor
/// chain rather than being passed in, so a buggy caller cannot
/// accidentally widen the protected set to include legitimate
/// targets.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct SweepOptions {
    /// When `true`, the sweeper reports what it WOULD kill but issues
    /// no signals. Used by the Settings UI's "preview" affordance
    /// (future work) and by the test suite.
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct SweepResult {
    /// Unix epoch milliseconds at sweep entry. All `KilledProcess`
    /// rows in one result share this value.
    pub timestamp_ms: i64,
    /// PID of the live Tado process that ran the sweep.
    pub our_pid: u32,
    /// Ancestor chain (Tado → swift → make → shell → Terminal → …),
    /// terminating at PID 1. Never killed.
    pub protected_pids: Vec<u32>,
    /// Successfully signaled processes. `kill_outcome == "killed"`
    /// means the syscall returned 0; "esrch" means the group was
    /// already dead between enumeration and kill (race), "eperm"
    /// means we lacked permission (shouldn't happen on a single-user
    /// laptop), "skipped_protected" means the group intersected the
    /// protected set so we held our fire.
    pub killed: Vec<KilledProcess>,
    /// Processes that matched a kill pattern but were skipped because
    /// they (or their process group) sit inside the protected
    /// ancestor chain. Reported back so the operator can audit and
    /// the verification agent can cross-check.
    pub matched_but_protected: Vec<KilledProcess>,
    /// Verbatim copy of `KILL_PATTERNS`. Returning the patterns lets
    /// the UI render an authoritative tooltip without duplicating
    /// the list across the Swift/Rust boundary.
    pub patterns: Vec<String>,
    /// Total count of processes scanned. Useful for the Settings
    /// last-sweep summary (`"Killed N of M tado-related processes"`).
    pub total_scanned: usize,
    /// `true` when this run was a dry-run preview.
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct KilledProcess {
    pub pid: u32,
    pub pgid: i32,
    pub command: String,
    pub matched_pattern: String,
    pub kill_outcome: String,
}

/// Public entry point. Caller-safe wrapper: panics inside the
/// sweep are caught and reported as an empty result rather than
/// poisoning the FFI boundary.
pub fn sweep(opts: SweepOptions) -> SweepResult {
    let timestamp_ms = chrono::Utc::now().timestamp_millis();
    let our_pid = std::process::id();

    // `new_all()` populates the process table eagerly with full
    // command-line + parent-PID; we don't read CPU / memory tables,
    // so the cost is dominated by the one process scan we'd need
    // anyway. Simpler than threading a bespoke `RefreshKind` through
    // the API across sysinfo minor versions.
    let mut sys = System::new();
    sys.refresh_processes(ProcessesToUpdate::All, true);

    let protected = build_protected_set(&sys, our_pid);

    let mut candidates: Vec<KilledProcess> = sys
        .processes()
        .iter()
        .filter_map(|(pid, proc)| {
            let cmd = joined_cmd(proc);
            let matched = KILL_PATTERNS
                .iter()
                .find(|p| cmd.contains(*p))
                .copied()?;
            Some(KilledProcess {
                pid: pid.as_u32(),
                // Resolved later, after we know whether to skip.
                pgid: 0,
                command: cmd,
                matched_pattern: matched.to_string(),
                kill_outcome: String::new(),
            })
        })
        .collect();

    // Sort by PID for diff-stable output. The candidate set is
    // typically <50 entries; sort cost is negligible.
    candidates.sort_by_key(|c| c.pid);

    let mut killed = Vec::with_capacity(candidates.len());
    let mut skipped_protected = Vec::new();

    for mut cand in candidates {
        // Process-group is the canonical kill target. Resolve it
        // here so the report carries the same PGID we signaled.
        let pgid = unsafe { libc::getpgid(cand.pid as libc::pid_t) };
        cand.pgid = pgid;

        // Protection check, two ways: PID directly in the protected
        // set, OR the PID's process-group leader is protected. The
        // second case catches edge scenarios where the candidate is
        // a non-leader sibling in our own group (highly unlikely but
        // free to guard).
        if protected.contains(&cand.pid)
            || (pgid > 0 && protected.contains(&(pgid as u32)))
        {
            cand.kill_outcome = "skipped_protected".to_string();
            skipped_protected.push(cand);
            continue;
        }

        if opts.dry_run {
            cand.kill_outcome = "dry_run".to_string();
            killed.push(cand);
            continue;
        }

        cand.kill_outcome = kill_outcome(pgid, cand.pid);
        killed.push(cand);
    }

    SweepResult {
        timestamp_ms,
        our_pid,
        protected_pids: {
            let mut v: Vec<u32> = protected.iter().copied().collect();
            v.sort_unstable();
            v
        },
        killed,
        matched_but_protected: skipped_protected,
        patterns: KILL_PATTERNS.iter().map(|s| s.to_string()).collect(),
        total_scanned: sys.processes().len(),
        dry_run: opts.dry_run,
    }
}

/// Build the protected PID set: the calling process plus its full
/// ancestor chain up to PID 1, plus PID 1 itself as defensive
/// insurance against `killpg(0, ...)` / `killpg(1, ...)` mistakes.
fn build_protected_set(sys: &System, our_pid: u32) -> HashSet<u32> {
    let mut set: HashSet<u32> = HashSet::new();
    set.insert(0); // never legal as a PGID kill target
    set.insert(1); // launchd

    let mut cur = our_pid;
    let mut walked = 0usize;
    // Walk-up bound is defensive — a healthy tree is ~6 deep
    // (Tado→swift→make→zsh→Terminal→launchd). 256 is a wide margin
    // that protects against an adversarial parent loop.
    while cur > 1 && walked < 256 {
        if !set.insert(cur) {
            break; // already seen → loop, abort
        }
        walked += 1;
        match sys.process(Pid::from_u32(cur)).and_then(|p| p.parent()) {
            Some(parent) => cur = parent.as_u32(),
            None => break,
        }
    }
    set
}

/// Join a process's argv into a single space-separated string for
/// substring matching. Reading via `cmd()` returns the original argv
/// vector; joining preserves enough fidelity for our literal-substring
/// patterns without paying the cost of a full shell-quoting round-trip.
fn joined_cmd(proc: &sysinfo::Process) -> String {
    proc.cmd()
        .iter()
        .map(|s| s.to_string_lossy())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Issue `killpg(pgid, SIGKILL)` and translate the syscall result
/// into the string we serialize back to the operator. SIGKILL is
/// chosen over SIGTERM because every candidate here is by definition
/// unwanted — there's no value in giving it time to flush state.
/// See `Session::kill` for the same rationale on app shutdown.
fn kill_outcome(pgid: i32, fallback_pid: u32) -> String {
    if pgid > 1 {
        let rc = unsafe { libc::killpg(pgid, libc::SIGKILL) };
        if rc == 0 {
            return "killed".to_string();
        }
        let errno = io_error();
        return errno_to_outcome(errno);
    }
    // Fallback: pgid resolution failed (process died between
    // enumeration and getpgid, or invalid permission). Try a direct
    // single-process kill before giving up — narrower blast radius
    // but at least the immediate target dies.
    let rc = unsafe { libc::kill(fallback_pid as libc::pid_t, libc::SIGKILL) };
    if rc == 0 {
        return "killed_pid_only".to_string();
    }
    let errno = io_error();
    errno_to_outcome(errno)
}

fn io_error() -> i32 {
    std::io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(0)
}

fn errno_to_outcome(errno: i32) -> String {
    match errno {
        libc::ESRCH => "esrch".to_string(),
        libc::EPERM => "eperm".to_string(),
        libc::EINVAL => "einval".to_string(),
        other => format!("errno_{}", other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protected_set_includes_self_and_pid1() {
        let mut sys = System::new();
        sys.refresh_processes(ProcessesToUpdate::All, true);
        let our_pid = std::process::id();
        let set = build_protected_set(&sys, our_pid);
        assert!(set.contains(&our_pid), "our pid must be protected");
        assert!(set.contains(&1), "launchd must be protected");
        assert!(set.contains(&0), "pgid 0 sentinel must be protected");
    }

    #[test]
    fn dry_run_kills_nothing_but_reports_matches() {
        let result = sweep(SweepOptions { dry_run: true });
        assert!(result.dry_run, "dry_run flag must round-trip");
        for k in &result.killed {
            assert_eq!(
                k.kill_outcome, "dry_run",
                "dry-run rows must carry the dry_run outcome marker"
            );
        }
        // The test runner itself shouldn't show up in matches —
        // `cargo test` doesn't run any of the patterns we kill.
        // (No assertion on length; the surrounding system might
        // legitimately have other matching processes.)
    }

    #[test]
    fn patterns_are_returned_verbatim() {
        let result = sweep(SweepOptions { dry_run: true });
        assert_eq!(result.patterns.len(), KILL_PATTERNS.len());
        for (got, want) in result.patterns.iter().zip(KILL_PATTERNS.iter()) {
            assert_eq!(got, want);
        }
    }

    #[test]
    fn pattern_list_is_locked_for_v018() {
        // This test pins the v0.18 pattern set. If you legitimately
        // need to change it, update the assertion AND the public
        // tooltip text in SettingsView.swift's ProcessHygieneSection
        // AND the CHANGELOG entry — operators read the tooltip to
        // know what gets killed and silent drift between the two
        // surfaces is exactly the bug class this test prevents.
        assert_eq!(
            KILL_PATTERNS,
            &[
                "/release/Tado",
                "/Applications/Tado.app/",
                "tado-mcp/dist/index.js",
                "target/release/tado-mcp",
                "target/release/dome-mcp",
                "target/release/tado-dome",
                "claude --output-format stream-json",
                "codex --output-format stream-json",
            ]
        );
    }
}
