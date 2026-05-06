//! Shared runtime measurement primitives used by every stack adapter.
//!
//! Five things every adapter needs to do the same way:
//!
//! 1. **Spawn a long-lived target** (cold-start, RSS measurement).
//!    The target is project-defined: a [[bin]] for Rust, a `main`
//!    binary for Go, the entry script for Python/Node, the Swift
//!    executable target. Adapters detect and pass the binary path +
//!    args; we do the spawning + bookkeeping here.
//!
//! 2. **Count cold-start ops** — number of stdout lines printed
//!    until the target either prints a "ready" sentinel or quiesces
//!    for 1 second. Counted, not timed.
//!
//! 3. **Sample RSS at fixed offsets** — `ps -o rss= -p $pid` at
//!    second 1 and second N, return the ratio.
//!
//! 4. **dtrace IO syscall counter** (macOS) / **strace -c** (Linux).
//!    Returns total syscall count over the run.
//!
//! 5. **Run a command with a budget** — wraps `Command::output`
//!    with a wall-clock cap and a SIGKILL on timeout. Used by
//!    every adapter for bench commands.
//!
//! All functions are FAIL-SAFE — they return a neutral value + a
//! notes line on any error path so the gate doesn't crash on
//! environment surprises (missing dtrace, sudo prompt, binary that
//! exits before second 1, etc.).

use regex::Regex;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

/// Target for cold-start / RSS / dtrace measurements: a runnable
/// path + args to execute. Adapters build this from project state.
#[derive(Debug, Clone)]
pub struct SpawnTarget {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub working_dir: PathBuf,
    /// Env to pass; merged on top of inherited env.
    pub env: Vec<(String, String)>,
}

/// Spawn the target, count stdout lines until either:
///   - a regex matches a ready-sentinel line (`ready|listening|started|server|bound|up`)
///   - the budget elapses
///   - 10,000 lines have been read (overflow guard)
///   - stdout closes (process exited)
///
/// Returns `(line_count, notes)`. Falls back to neutral on spawn
/// failure.
pub fn cold_start_lines(target: &SpawnTarget, budget: Duration) -> (f64, Option<String>) {
    use std::io::BufRead;

    let mut cmd = Command::new(&target.program);
    cmd.args(&target.args)
        .current_dir(&target.working_dir)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    for (k, v) in &target.env {
        cmd.env(k, v);
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return (0.0, Some(format!("cold_start_ops: spawn failed ({e})"))),
    };

    let stdout = match child.stdout.take() {
        Some(s) => s,
        None => {
            let _ = child.kill();
            return (0.0, Some("cold_start_ops: no stdout pipe".into()));
        }
    };

    let start = Instant::now();
    let mut line_count: u64 = 0;
    let ready_re = Regex::new(r"(?i)\b(ready|listening|started|server|bound|up)\b").unwrap();
    let reader = std::io::BufReader::new(stdout);
    for line in reader.lines() {
        if start.elapsed() > budget {
            break;
        }
        line_count += 1;
        let Ok(text) = line else { continue };
        if ready_re.is_match(&text) {
            break;
        }
        if line_count > 10_000 {
            break;
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    if line_count == 0 {
        return (0.0, Some("cold_start_ops: target produced no stdout in budget".into()));
    }
    (
        line_count as f64,
        Some(format!("cold_start_ops: counted {line_count} lines from target")),
    )
}

/// Spawn the target, sample RSS at second 1 and second N (capped at
/// budget - 1), return ratio. Neutral if the target exits before
/// second 1 (CLI tools that complete quickly aren't candidates).
pub fn rss_ratio(target: &SpawnTarget, budget: Duration) -> (f64, Option<String>) {
    if budget < Duration::from_secs(3) {
        return (1.0, Some("steady_state_rss_ratio: budget too small (need ≥3s)".into()));
    }

    let mut cmd = Command::new(&target.program);
    cmd.args(&target.args)
        .current_dir(&target.working_dir)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    for (k, v) in &target.env {
        cmd.env(k, v);
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return (1.0, Some(format!("steady_state_rss_ratio: spawn failed ({e})"))),
    };
    let pid = child.id();

    std::thread::sleep(Duration::from_secs(1));
    let rss1 = sample_rss(pid);

    let wait = std::cmp::min(budget, Duration::from_secs(60)) - Duration::from_secs(1);
    std::thread::sleep(wait);
    let rss2 = sample_rss(pid);

    let _ = child.kill();
    let _ = child.wait();

    match (rss1, rss2) {
        (Some(r1), Some(r2)) if r1 > 0.0 => {
            let ratio = r2 / r1;
            (ratio, Some(format!("steady_state_rss_ratio: rss@1s={r1}KB rss@end={r2}KB ratio={ratio:.3}")))
        }
        _ => (
            1.0,
            Some("steady_state_rss_ratio: ps sampling failed (target may have exited early)".into()),
        ),
    }
}

/// `ps -o rss= -p <pid>` returns RSS in KB on macOS + Linux. Returns
/// None if the process doesn't exist.
pub fn sample_rss(pid: u32) -> Option<f64> {
    let output = Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&output.stdout);
    s.trim().parse::<f64>().ok()
}

/// Wrap a target in dtrace (macOS) or strace -c (Linux) and count
/// IO syscalls. Returns `(syscalls_per_op, notes)` — per-op
/// approximated as syscalls / 1 logical op.
///
/// Requires dtrace authorization on macOS (`csrutil disable` or
/// sudo) — the caller opts in via `TADO_PERF_DTRACE=1`. Falls back
/// to neutral with an explanatory notes line on any other path.
pub fn io_syscalls(target: &SpawnTarget, budget: Duration) -> (f64, Option<String>) {
    #[cfg(target_os = "macos")]
    {
        if std::env::var("TADO_PERF_DTRACE").as_deref() != Ok("1") {
            return (0.0, Some("io_syscalls_per_op: dtrace mode opt-in (set TADO_PERF_DTRACE=1)".into()));
        }
        return io_syscalls_dtrace(target, budget);
    }
    #[cfg(target_os = "linux")]
    {
        if which("strace").is_none() {
            return (0.0, Some("io_syscalls_per_op: strace not installed".into()));
        }
        return io_syscalls_strace(target, budget);
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = (target, budget);
        (0.0, Some("io_syscalls_per_op: unsupported platform".into()))
    }
}

#[cfg(target_os = "macos")]
fn io_syscalls_dtrace(target: &SpawnTarget, budget: Duration) -> (f64, Option<String>) {
    // Write a tiny D script that prints one line per syscall.
    let script_path = std::env::temp_dir().join(format!(
        "perf-suite-dtrace-{}.d",
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let script = "syscall:::entry /pid == $target/ { @c = count(); }\n\
                  END { printa(\"PERF_SYSCALL_COUNT=%@d\\n\", @c); }\n";
    let _ = std::fs::write(&script_path, script);

    // dtrace -c <command> -s script will run the command and report
    // counts on exit. We use -q to suppress the dtrace banner.
    let cmd_str = std::iter::once(target.program.display().to_string())
        .chain(target.args.iter().cloned())
        .collect::<Vec<_>>()
        .join(" ");
    let mut cmd = Command::new("sudo");
    cmd.args(["-n", "dtrace", "-q", "-s"])
        .arg(&script_path)
        .args(["-c", &cmd_str])
        .current_dir(&target.working_dir);

    let output = run_with_budget(cmd, Some(budget));
    let _ = std::fs::remove_file(&script_path);
    let Ok(out) = output else {
        return (0.0, Some("io_syscalls_per_op: dtrace invocation failed (sudo prompt? not authorized?)".into()));
    };
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let re = Regex::new(r"PERF_SYSCALL_COUNT=(\d+)").unwrap();
    if let Some(cap) = re.captures(&combined) {
        if let Ok(n) = cap.get(1).unwrap().as_str().parse::<f64>() {
            return (n, Some(format!("io_syscalls_per_op: dtrace counted {n} syscalls")));
        }
    }
    (0.0, Some("io_syscalls_per_op: dtrace produced no count".into()))
}

#[cfg(target_os = "linux")]
fn io_syscalls_strace(target: &SpawnTarget, budget: Duration) -> (f64, Option<String>) {
    let mut cmd = Command::new("strace");
    cmd.args(["-c", "-f", "-e", "trace=read,write,open,openat,close,lseek,mmap"])
        .arg(&target.program)
        .args(&target.args)
        .current_dir(&target.working_dir);
    let output = run_with_budget(cmd, Some(budget));
    let Ok(out) = output else {
        return (0.0, Some("io_syscalls_per_op: strace timed out".into()));
    };
    let stderr = String::from_utf8_lossy(&out.stderr);
    let re = Regex::new(r"^\s*\d+\.\d+\s+\d+\.\d+\s+\d+\s+(\d+)\s+\w+").unwrap();
    let mut total: u64 = 0;
    for line in stderr.lines() {
        if let Some(cap) = re.captures(line) {
            if let Ok(n) = cap.get(1).unwrap().as_str().parse::<u64>() {
                total = total.saturating_add(n);
            }
        }
    }
    (total as f64, Some(format!("io_syscalls_per_op: strace counted {total} syscalls")))
}

/// Run a command with an optional time budget. Returns the output on
/// success, an error string on timeout / spawn failure. Used by
/// every adapter for bench commands.
pub fn run_with_budget(mut cmd: Command, budget: Option<Duration>) -> Result<std::process::Output, String> {
    let cap = budget.unwrap_or(Duration::from_secs(120));
    let mut child = cmd
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn failed: {e}"))?;
    let pid = child.id();

    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => {
                return child
                    .wait_with_output()
                    .map_err(|e| format!("wait_with_output failed: {e}"));
            }
            Ok(None) => {
                if start.elapsed() > cap {
                    let _ = libc_kill(pid, 9);
                    let _ = child.wait();
                    return Err(format!("timed out after {}s", cap.as_secs()));
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(e) => return Err(format!("try_wait failed: {e}")),
        }
    }
}

#[cfg(unix)]
pub(crate) fn libc_kill(pid: u32, sig: i32) -> i32 {
    extern "C" {
        fn kill(pid: i32, sig: i32) -> i32;
    }
    unsafe { kill(pid as i32, sig) }
}

#[cfg(not(unix))]
pub(crate) fn libc_kill(_pid: u32, _sig: i32) -> i32 {
    0
}

pub fn which(cmd: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths).find_map(|dir| {
            let candidate = dir.join(cmd);
            if candidate.is_file() {
                Some(candidate)
            } else {
                None
            }
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_with_budget_captures_output() {
        let mut cmd = Command::new("sh");
        cmd.args(["-c", "echo hello"]);
        let out = run_with_budget(cmd, Some(Duration::from_secs(2))).unwrap();
        assert!(String::from_utf8_lossy(&out.stdout).contains("hello"));
    }

    #[test]
    fn run_with_budget_kills_on_timeout() {
        let mut cmd = Command::new("sh");
        cmd.args(["-c", "sleep 30"]);
        let result = run_with_budget(cmd, Some(Duration::from_millis(500)));
        assert!(result.is_err());
    }

    #[test]
    fn cold_start_counts_lines() {
        let target = SpawnTarget {
            program: PathBuf::from("sh"),
            args: vec!["-c".into(), "for i in 1 2 3; do echo line$i; done; sleep 5".into()],
            working_dir: std::env::temp_dir(),
            env: vec![],
        };
        let (count, _note) = cold_start_lines(&target, Duration::from_secs(3));
        assert!(count >= 3.0, "got count={count}");
    }

    #[test]
    fn cold_start_stops_at_ready_sentinel() {
        let target = SpawnTarget {
            program: PathBuf::from("sh"),
            args: vec!["-c".into(), "echo init; echo loading; echo ready; sleep 5".into()],
            working_dir: std::env::temp_dir(),
            env: vec![],
        };
        let (count, _note) = cold_start_lines(&target, Duration::from_secs(3));
        // Should stop at "ready" — count is 3 (init, loading, ready).
        assert!(count <= 3.0, "got count={count}, expected ≤3");
    }
}
