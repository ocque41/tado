//! tado-deploy — deploy a new agent session.
//!
//! In CLI-runtime mode (`TADO_PROFILE`, `TADO_RUNTIME_SOCKET`, or no desktop
//! IPC root), this talks to `tadod` and spawns the session directly. In desktop
//! mode it preserves the existing behavior: drop a SpawnRequest envelope into
//! the running Tado app's `<ipcRoot>/spawn-requests/` so the broker spawns a
//! visible canvas tile.
//!
//! Replaces the legacy 80-line bash + Python heredoc that
//! `IPCBroker.writeExternalTadoDeploy` used to materialize on
//! every cold launch (see "smooth-software pass: terminal refactor
//! + startup debug" — this binary is its Rust replacement).
//!
//! When run from inside a Tado tile, `TADO_PROJECT_NAME` /
//! `TADO_PROJECT_ROOT` / `TADO_TEAM_NAME` / `TADO_ENGINE` /
//! `TADO_SESSION_ID` are inherited from the parent session's env;
//! flags fall back to those values when the corresponding `--*`
//! is unset. When run from a plain terminal outside Tado, just
//! pass `--project` / `--cwd` explicitly.

use chrono::Utc;
use clap::Parser;
use serde_json::json;
use std::env;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::ExitCode;
use tado_cli::engine::normalize_session_engine;
use tado_runtime::{ensure_daemon, profile_from_env};
use uuid::Uuid;

#[derive(Parser)]
#[command(name = "tado-deploy")]
#[command(
    about = "Deploy a new agent session on the Tado canvas.",
    long_about = "Deploys a new agent session on the Tado canvas.\n\
                  Run from any terminal; defaults are inherited from\n\
                  TADO_PROJECT_NAME / TADO_PROJECT_ROOT / TADO_TEAM_NAME /\n\
                  TADO_ENGINE / TADO_SESSION_ID when set."
)]
struct Cli {
    /// The prompt the agent will be spawned with. The first
    /// positional argument; quote it so the shell doesn't split it.
    prompt: String,

    /// Agent definition name from `.codex/agents/<name>.md`.
    #[arg(long)]
    agent: Option<String>,

    /// Team name. Defaults to `$TADO_TEAM_NAME` when unset.
    #[arg(long)]
    team: Option<String>,

    /// Project name. Defaults to `$TADO_PROJECT_NAME` when unset.
    #[arg(long)]
    project: Option<String>,

    /// Session kind in CLI-runtime mode: `codex`, `shell`, or `raw`.
    /// Defaults to `$TADO_ENGINE`, then `codex`.
    #[arg(long)]
    engine: Option<String>,

    /// Working directory for the spawned tile. Defaults to
    /// `$TADO_PROJECT_ROOT`.
    #[arg(long)]
    cwd: Option<String>,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    let team = cli.team.or_else(|| env::var("TADO_TEAM_NAME").ok());
    let project = cli.project.or_else(|| env::var("TADO_PROJECT_NAME").ok());
    let engine = match normalize_session_engine(cli.engine.or_else(|| env::var("TADO_ENGINE").ok()))
    {
        Ok(engine) => Some(engine),
        Err(err) => {
            eprintln!("tado-deploy: {err}");
            return ExitCode::from(1);
        }
    };
    let cwd = cli.cwd.or_else(|| env::var("TADO_PROJECT_ROOT").ok());
    let requested_by = env::var("TADO_SESSION_ID").ok();

    let ipc_root_str = env::var("TADO_IPC_ROOT").unwrap_or_else(|_| "/tmp/tado-ipc".to_string());
    let runtime_preferred = env::var_os("TADO_RUNTIME_SOCKET").is_some()
        || env::var_os("TADO_RUNTIME_ID").is_some()
        || env::var_os("TADO_PROFILE").is_some();
    let desktop_ipc_exists = PathBuf::from(&ipc_root_str).exists();
    if runtime_preferred || !desktop_ipc_exists {
        match deploy_runtime(
            &cli.prompt,
            &project,
            &team,
            &engine,
            &cwd,
            &requested_by,
            &cli.agent,
        ) {
            Ok(session_id) => {
                println!("Deploy request submitted to Tado runtime: {}", session_id);
                if let Some(a) = &cli.agent {
                    println!("  Agent: {}", a);
                }
                if let Some(p) = &project {
                    println!("  Project: {}", p);
                }
                return ExitCode::SUCCESS;
            }
            Err(err) if runtime_preferred => {
                eprintln!("tado-deploy: runtime deploy failed: {err}");
                return ExitCode::from(1);
            }
            Err(_) => {
                // Fall through to the desktop IPC path when the user did not
                // explicitly select a runtime profile.
            }
        }
    }

    let ipc_root = PathBuf::from(&ipc_root_str);
    let ipc_root_dir = if ipc_root.is_symlink() {
        match fs::read_link(&ipc_root) {
            Ok(target) => target,
            Err(_) => ipc_root,
        }
    } else if ipc_root.is_dir() {
        ipc_root
    } else {
        eprintln!("Tado is not running (no IPC root at {})", ipc_root_str);
        return ExitCode::from(1);
    };

    let spawn_dir = ipc_root_dir.join("spawn-requests");
    if let Err(e) = fs::create_dir_all(&spawn_dir) {
        eprintln!(
            "tado-deploy: failed to create spawn-requests directory at {}: {}",
            spawn_dir.display(),
            e
        );
        return ExitCode::from(1);
    }

    let req_id = Uuid::new_v4();
    // RFC 3339 / ISO 8601 with second precision — matches the
    // Swift `JSONEncoder.dateEncodingStrategy = .iso8601`
    // round-trip the broker uses on read, byte-compatible with
    // the legacy bash heredoc (which also emitted second-only
    // precision).
    let timestamp = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let envelope = json!({
        "id": req_id,
        "prompt": cli.prompt,
        "agentName": cli.agent,
        "teamName": team,
        "projectName": project,
        "projectRoot": cwd,
        "engine": engine,
        "requestedBy": requested_by,
        "timestamp": timestamp,
        "status": "pending",
    });

    // Atomic write: spool to a temp file, fsync, rename. The
    // broker's DispatchSource watcher fires on the rename's
    // `vnode_event_create` so a half-written `.spawn` file can't
    // surface to the broker mid-write.
    let final_path = spawn_dir.join(format!("{}.spawn", req_id));
    let temp_path = spawn_dir.join(format!(".{}.spawn.tmp", req_id));
    let pretty = match serde_json::to_string_pretty(&envelope) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("tado-deploy: serializing envelope failed: {}", e);
            return ExitCode::from(1);
        }
    };
    let write_result = (|| -> std::io::Result<()> {
        let mut f = fs::File::create(&temp_path)?;
        f.write_all(pretty.as_bytes())?;
        f.sync_all()?;
        fs::rename(&temp_path, &final_path)?;
        Ok(())
    })();
    if let Err(e) = write_result {
        let _ = fs::remove_file(&temp_path);
        eprintln!(
            "tado-deploy: writing spawn request to {} failed: {}",
            final_path.display(),
            e
        );
        return ExitCode::from(1);
    }

    println!("Deploy request submitted: {}", req_id);
    if let Some(a) = &cli.agent {
        println!("  Agent: {}", a);
    }
    if let Some(p) = &project {
        println!("  Project: {}", p);
    }
    ExitCode::SUCCESS
}

fn deploy_runtime(
    prompt: &str,
    project: &Option<String>,
    team: &Option<String>,
    engine: &Option<String>,
    cwd: &Option<String>,
    requested_by: &Option<String>,
    agent: &Option<String>,
) -> Result<String, String> {
    let profile = profile_from_env(None);
    let client = ensure_daemon(&profile).map_err(|e| e.to_string())?;
    let selected_engine = engine.as_deref().unwrap_or("codex");
    let mut env_pairs = Vec::new();
    if let Some(project) = project {
        env_pairs.push(json!(["TADO_PROJECT_NAME", project]));
    }
    if let Some(team) = team {
        env_pairs.push(json!(["TADO_TEAM_NAME", team]));
    }
    if let Some(requested_by) = requested_by {
        env_pairs.push(json!(["TADO_REQUESTED_BY", requested_by]));
    }
    if let Some(agent) = agent {
        env_pairs.push(json!(["TADO_AGENT_NAME", agent]));
    }
    let response = client
        .call(
            "session.spawn",
            json!({
                "engine": selected_engine,
                "prompt": prompt,
                "command": prompt,
                "title": agent.as_deref().unwrap_or(prompt),
                "cwd": cwd,
                "project_id": project,
                "project_root": cwd,
                "agent_name": agent,
                "team_name": team,
                "env": env_pairs,
            }),
        )
        .map_err(|e| e.to_string())?;
    response
        .data
        .and_then(|data| data.get("session")?.get("id")?.as_str().map(str::to_string))
        .ok_or_else(|| "runtime response did not include session.id".to_string())
}
