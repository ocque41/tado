use anyhow::{anyhow, Context, Result};
use clap::{Args, Parser, Subcommand};
use serde_json::{json, Value};
use tado_cli::engine::{normalize_session_engine, normalize_workflow_engine};
use tado_runtime::profile::profile_from_env;
use tado_runtime::{ensure_daemon, RuntimeClient};

#[derive(Parser, Debug)]
#[command(name = "tado")]
#[command(about = "CLI-first Tado runtime and Agent OS.")]
struct Cli {
    #[arg(long, global = true)]
    profile: Option<String>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Manage runtime profiles.
    Profile(ProfileCommand),
    /// Inspect or control the profile daemon.
    Daemon(DaemonCommand),
    /// Register and select projects for the active profile.
    Project(ProjectCommand),
    /// Spawn a runtime session.
    Spawn(SpawnArgs),
    /// List runtime sessions.
    List,
    /// Read a session screen/transcript.
    Read(ReadArgs),
    /// Send text to a live PTY session.
    Send(SendArgs),
    /// Stop or hard-kill a session.
    Kill(KillArgs),
    /// Kill and remove a session from the runtime list.
    Delete(KillArgs),
    /// Search persisted transcript chunks.
    Search(SearchArgs),
    /// Print Agent OS Kanban snapshot.
    Board(BoardCommand),
    /// Request bootstrap actions for the active runtime profile.
    Bootstrap(BootstrapArgs),
    /// Print recent runtime events.
    Events(EventsArgs),
}

#[derive(Subcommand, Debug)]
enum ProfileSubcommand {
    List,
    Create { name: String },
    Delete { name: String },
    Use { name: String },
}

#[derive(Args, Debug)]
struct ProfileCommand {
    #[command(subcommand)]
    command: ProfileSubcommand,
}

#[derive(Subcommand, Debug)]
enum DaemonSubcommand {
    Status,
    Start,
    Stop,
}

#[derive(Args, Debug)]
struct DaemonCommand {
    #[command(subcommand)]
    command: DaemonSubcommand,
}

#[derive(Subcommand, Debug)]
enum ProjectSubcommand {
    Status,
    List,
    Add {
        root: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        create: bool,
        #[arg(long, default_value_t = true)]
        activate: bool,
    },
    Use {
        target: String,
    },
}

#[derive(Args, Debug)]
struct ProjectCommand {
    #[command(subcommand)]
    command: ProjectSubcommand,
}

#[derive(Args, Debug)]
struct SpawnArgs {
    /// Session kind: codex, shell, or raw. Shell/raw are terminal utilities, not AI providers.
    #[arg(long, default_value = "codex")]
    engine: String,
    /// Working directory. Defaults to current directory.
    #[arg(long)]
    cwd: Option<String>,
    #[arg(long)]
    title: Option<String>,
    #[arg(long)]
    project_id: Option<String>,
    #[arg(long)]
    project_root: Option<String>,
    #[arg(long)]
    agent: Option<String>,
    #[arg(long)]
    team: Option<String>,
    /// Extra engine flags. Repeat once per token, e.g. --flag --model --flag opus.
    #[arg(long = "flag")]
    flags: Vec<String>,
    /// Prompt or shell command.
    text: Vec<String>,
}

#[derive(Args, Debug)]
struct ReadArgs {
    target: String,
    #[arg(long, default_value_t = 20)]
    limit: usize,
}

#[derive(Args, Debug)]
struct SendArgs {
    target: String,
    message: Vec<String>,
    #[arg(long)]
    no_enter: bool,
}

#[derive(Args, Debug)]
struct KillArgs {
    target: String,
    #[arg(long)]
    hard: bool,
}

#[derive(Args, Debug)]
struct SearchArgs {
    query: String,
    #[arg(long, default_value_t = 20)]
    limit: usize,
}

#[derive(Args, Debug)]
struct EventsArgs {
    #[arg(long, default_value_t = 80)]
    limit: usize,
}

#[derive(Subcommand, Debug)]
enum BoardSubcommand {
    Snapshot,
    Move { target: String, lane: String },
    AddColumn { key: String, title: String },
}

#[derive(Args, Debug)]
struct BoardCommand {
    #[command(subcommand)]
    command: Option<BoardSubcommand>,
}

#[derive(Args, Debug)]
struct BootstrapArgs {
    /// Action: a2a, team, auto-mode, knowledge, or index.
    action: String,
    #[arg(long)]
    project_root: Option<String>,
    #[arg(long, default_value = "codex")]
    engine: String,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let profile = profile_from_env(cli.profile);

    match cli.command {
        None => {
            tado_tui_main(&profile)?;
        }
        Some(Command::Profile(cmd)) => profile_command(&profile, cmd)?,
        Some(Command::Daemon(cmd)) => daemon_command(&profile, cmd)?,
        Some(Command::Project(cmd)) => project_command(&profile, cmd)?,
        Some(Command::Spawn(args)) => {
            let payload = spawn_payload(args)?;
            let client = ensure_daemon(&profile)?;
            print_response(client.call("session.spawn", payload)?)?;
        }
        Some(Command::List) => {
            let client = ensure_daemon(&profile)?;
            print_response(client.call("session.list", json!({}))?)?;
        }
        Some(Command::Read(args)) => {
            let client = ensure_daemon(&profile)?;
            let response = client.call(
                "session.read",
                json!({ "target": args.target, "limit": args.limit }),
            )?;
            if let Some(text) = response
                .data
                .as_ref()
                .and_then(|d| d.get("text"))
                .and_then(Value::as_str)
            {
                println!("{text}");
            } else {
                print_response(response)?;
            }
        }
        Some(Command::Send(args)) => {
            let client = ensure_daemon(&profile)?;
            let message = args.message.join(" ");
            if message.trim().is_empty() {
                return Err(anyhow!("send requires a message"));
            }
            print_response(client.call(
                "session.send",
                json!({ "target": args.target, "message": message, "enter": !args.no_enter }),
            )?)?;
        }
        Some(Command::Kill(args)) => {
            let client = ensure_daemon(&profile)?;
            print_response(client.call(
                "session.kill",
                json!({ "target": args.target, "hard": args.hard }),
            )?)?;
        }
        Some(Command::Delete(args)) => {
            let client = ensure_daemon(&profile)?;
            print_response(client.call(
                "session.delete",
                json!({ "target": args.target, "hard": true }),
            )?)?;
        }
        Some(Command::Search(args)) => {
            let client = ensure_daemon(&profile)?;
            print_response(client.call(
                "transcript.search",
                json!({ "query": args.query, "limit": args.limit }),
            )?)?;
        }
        Some(Command::Board(args)) => {
            let client = ensure_daemon(&profile)?;
            let (kind, payload) = match args.command.unwrap_or(BoardSubcommand::Snapshot) {
                BoardSubcommand::Snapshot => ("kanban.snapshot", json!({})),
                BoardSubcommand::Move { target, lane } => {
                    ("kanban.move", json!({ "target": target, "lane": lane }))
                }
                BoardSubcommand::AddColumn { key, title } => {
                    ("kanban.add_column", json!({ "key": key, "title": title }))
                }
            };
            print_response(client.call(kind, payload)?)?;
        }
        Some(Command::Bootstrap(args)) => {
            let engine = normalize_workflow_engine(&args.engine)?;
            let client = ensure_daemon(&profile)?;
            print_response(client.call(
                "bootstrap.request",
                json!({
                    "action": args.action,
                    "project_root": args.project_root,
                    "engine": engine,
                }),
            )?)?;
        }
        Some(Command::Events(args)) => {
            let client = ensure_daemon(&profile)?;
            print_response(client.call("events.list", json!({ "limit": args.limit }))?)?;
        }
    }

    Ok(())
}

fn tado_tui_main(profile: &str) -> Result<()> {
    let current = std::env::current_exe()?;
    let tui = current
        .parent()
        .map(|dir| dir.join("tado-tui"))
        .filter(|path| path.exists())
        .unwrap_or_else(|| "tado-tui".into());
    let status = std::process::Command::new(tui)
        .arg("--profile")
        .arg(profile)
        .status()
        .context("launch tado-tui")?;
    if !status.success() {
        return Err(anyhow!("tado-tui exited with status {status}"));
    }
    Ok(())
}

fn profile_command(active_profile: &str, cmd: ProfileCommand) -> Result<()> {
    match cmd.command {
        ProfileSubcommand::List => {
            let paths = tado_runtime::ProfilePaths::resolve(active_profile)?;
            let root = paths.runtime_root.join("profiles");
            let mut profiles = Vec::new();
            if let Ok(entries) = std::fs::read_dir(root) {
                for entry in entries.flatten() {
                    if entry.path().is_dir() {
                        if let Some(name) = entry.file_name().to_str() {
                            profiles.push(name.to_string());
                        }
                    }
                }
            }
            profiles.sort();
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "active": active_profile,
                    "profiles": profiles,
                }))?
            );
        }
        ProfileSubcommand::Create { name } => {
            let paths = tado_runtime::ProfilePaths::resolve(&name)?;
            paths.create_dirs()?;
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "created": paths.profile,
                    "root": paths.profile_root,
                }))?
            );
        }
        ProfileSubcommand::Delete { name } => {
            let paths = tado_runtime::ProfilePaths::resolve(&name)?;
            if paths.socket_path.exists() {
                return Err(anyhow!(
                    "profile {} has a runtime socket; stop the daemon before deleting it",
                    paths.profile
                ));
            }
            if paths.profile_root.exists() {
                std::fs::remove_dir_all(&paths.profile_root)?;
            }
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({ "deleted": paths.profile }))?
            );
        }
        ProfileSubcommand::Use { name } => {
            let paths = tado_runtime::ProfilePaths::resolve(&name)?;
            paths.create_dirs()?;
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "profile": paths.profile,
                    "next": format!("export TADO_PROFILE={}", paths.profile),
                }))?
            );
        }
    }
    Ok(())
}

fn daemon_command(profile: &str, cmd: DaemonCommand) -> Result<()> {
    match cmd.command {
        DaemonSubcommand::Status => {
            let client = RuntimeClient::new(profile)?;
            match client.call("runtime.status", json!({})) {
                Ok(response) => print_response(response)?,
                Err(err) => {
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&json!({
                            "profile": profile,
                            "running": false,
                            "error": err.to_string(),
                        }))?
                    );
                }
            }
        }
        DaemonSubcommand::Start => {
            let client = ensure_daemon(profile)?;
            print_response(client.call("runtime.status", json!({}))?)?;
        }
        DaemonSubcommand::Stop => {
            let client = RuntimeClient::new(profile)?;
            print_response(client.call("daemon.shutdown", json!({}))?)?;
        }
    }
    Ok(())
}

fn project_command(profile: &str, cmd: ProjectCommand) -> Result<()> {
    let client = ensure_daemon(profile)?;
    match cmd.command {
        ProjectSubcommand::Status => print_response(client.call("project.status", json!({}))?)?,
        ProjectSubcommand::List => print_response(client.call("project.list", json!({}))?)?,
        ProjectSubcommand::Add {
            root,
            name,
            create,
            activate,
        } => print_response(client.call(
            "project.add",
            json!({ "root": root, "name": name, "create": create, "activate": activate }),
        )?)?,
        ProjectSubcommand::Use { target } => {
            print_response(client.call("project.use", json!({ "target": target }))?)?
        }
    }
    Ok(())
}

fn spawn_payload(args: SpawnArgs) -> Result<Value> {
    let engine = normalize_session_engine(Some(args.engine.clone()))?;
    let text = args.text.join(" ");
    let cwd = args.cwd.or_else(|| {
        std::env::current_dir()
            .ok()
            .map(|p| p.display().to_string())
    });
    let payload = match engine.as_str() {
        "raw" => json!({
            "engine": "raw",
            "command": text,
            "args": [],
            "title": args.title,
            "cwd": cwd,
            "project_id": args.project_id,
            "project_root": args.project_root,
            "agent_name": args.agent,
            "team_name": args.team,
            "flags": args.flags,
        }),
        "shell" => json!({
            "engine": "shell",
            "command": text,
            "title": args.title,
            "cwd": cwd,
            "project_id": args.project_id,
            "project_root": args.project_root,
            "agent_name": args.agent,
            "team_name": args.team,
            "flags": args.flags,
        }),
        "codex" => json!({
            "engine": "codex",
            "prompt": text,
            "title": args.title,
            "cwd": cwd,
            "project_id": args.project_id,
            "project_root": args.project_root,
            "agent_name": args.agent,
            "team_name": args.team,
            "flags": args.flags,
        }),
        _ => unreachable!("normalize_session_engine only returns known session kinds"),
    };
    Ok(payload)
}

fn print_response(response: tado_runtime::RuntimeResponse) -> Result<()> {
    println!(
        "{}",
        serde_json::to_string_pretty(&response.data.unwrap_or(json!({})))?
    );
    Ok(())
}
