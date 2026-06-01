//! tado-eternal — drive the Eternal lifecycle from the CLI.
//!
//! Subcommands:
//!   propose --project <name> --feature <feature> --task "<text>"
//!           [--mode mega|sprint] [--engine codex]
//!           --coordinator-todo-id <uuid> [--label <text>]
//!   status <run_id>
//!   crafted <run_id>
//!   accept <run_id> [--note "<text>"]
//!   reject <run_id> --reason "<text>" [--rebrief "<new brief>"]
//!   stop <run_id>
//!   list [--project <name>] [--state <state>]

use clap::{Parser, Subcommand};
use serde_json::{json, Value};
use tado_cli::{control_client, engine::normalize_workflow_engine, print_response, OutputMode};
use tado_runtime::{ensure_daemon, profile_from_env};

#[derive(Parser)]
#[command(name = "tado-eternal")]
#[command(about = "Coordinator-driven Eternal lifecycle CLI.", long_about = None)]
struct Cli {
    #[arg(long, global = true)]
    human: bool,
    #[arg(long, global = true)]
    toon: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Create a new EternalRun, spawn the architect.
    Propose {
        #[arg(long)]
        project: String,
        #[arg(long)]
        feature: String,
        #[arg(long)]
        task: String,
        #[arg(long, default_value = "sprint")]
        mode: String,
        #[arg(long, default_value = "codex")]
        engine: String,
        #[arg(long = "coordinator-todo-id")]
        coordinator_todo_id: String,
        #[arg(long)]
        label: Option<String>,
    },
    /// Inspect a run's state.
    Status { run_id: String },
    /// Print the architect's `crafted.md`.
    Crafted { run_id: String },
    /// Accept the architect's plan and spawn the worker.
    Accept {
        run_id: String,
        #[arg(long)]
        note: Option<String>,
    },
    /// Reject the architect's plan, optionally rebriefing.
    Reject {
        run_id: String,
        #[arg(long)]
        reason: String,
        #[arg(long)]
        rebrief: Option<String>,
    },
    /// Request the worker to stop at the next sprint boundary.
    Stop { run_id: String },
    /// List runs.
    List {
        #[arg(long)]
        project: Option<String>,
        #[arg(long)]
        state: Option<String>,
    },
}

fn main() {
    let cli = Cli::parse();
    let mode = OutputMode::from_flags(cli.human, cli.toon);
    if let Err(err) = validate_eternal_engines(&cli.command) {
        eprintln!("tado-eternal: {err}");
        std::process::exit(1);
    }

    if runtime_selected() {
        let exit = match runtime_eternal(cli.command) {
            Ok(data) => {
                match mode {
                    OutputMode::Human => println!(
                        "{}",
                        serde_json::to_string_pretty(&data).unwrap_or_default()
                    ),
                    _ => println!("{data}"),
                }
                0
            }
            Err(err) => {
                eprintln!("{err}");
                1
            }
        };
        std::process::exit(exit);
    }

    let result = match cli.command {
        Command::Propose {
            project,
            feature,
            task,
            mode: run_mode,
            engine,
            coordinator_todo_id,
            label,
        } => {
            let engine = normalize_workflow_engine(&engine).unwrap_or("codex");
            let mut payload = json!({
                "project": project,
                "feature": feature,
                "task": task,
                "mode": run_mode,
                "engine": engine,
                "coordinator_todo_id": coordinator_todo_id,
                "brief": task,
            });
            if let Some(l) = label {
                payload["label"] = json!(l);
            }
            control_client::call("eternal.propose", payload)
        }
        Command::Status { run_id } => {
            control_client::call("eternal.status", json!({ "run_id": run_id }))
        }
        Command::Crafted { run_id } => {
            control_client::call("eternal.crafted", json!({ "run_id": run_id }))
        }
        Command::Accept { run_id, note } => {
            let mut payload = json!({ "run_id": run_id });
            if let Some(n) = note {
                payload["note"] = json!(n);
            }
            control_client::call("eternal.accept", payload)
        }
        Command::Reject {
            run_id,
            reason,
            rebrief,
        } => {
            let mut payload = json!({ "run_id": run_id, "reason": reason });
            if let Some(r) = rebrief {
                payload["rebrief"] = json!(r);
            }
            control_client::call("eternal.reject", payload)
        }
        Command::Stop { run_id } => {
            control_client::call("eternal.stop", json!({ "run_id": run_id }))
        }
        Command::List { project, state } => {
            let mut payload = json!({});
            if let Some(p) = project {
                payload["project"] = json!(p);
            }
            if let Some(s) = state {
                payload["state"] = json!(s);
            }
            control_client::call("eternal.list", payload)
        }
    };

    let exit = match result {
        Ok(resp) => print_response(resp, mode),
        Err(e) => {
            eprintln!("{e}");
            // Surface server-side error data when present so callers
            // can pattern-match on shape (state_mismatch + actual,
            // no_project + candidates, etc.).
            if let control_client::ControlClientError::Server {
                data: Some(data), ..
            } = &e
            {
                eprintln!("{}", serde_json::to_string(data).unwrap_or_default());
            }
            1
        }
    };
    std::process::exit(exit);
}

fn runtime_eternal(command: Command) -> anyhow::Result<Value> {
    let client = ensure_daemon(&profile_from_env(None))?;
    let response = match command {
        Command::Propose {
            project,
            feature,
            task,
            mode,
            engine,
            coordinator_todo_id,
            label,
        } => {
            let engine = normalize_workflow_engine(&engine)?;
            client.call(
                "workflow.propose",
                json!({
                    "kind": "eternal",
                    "project": project,
                    "feature": feature,
                    "task": task,
                    "mode": mode,
                    "engine": engine,
                    "coordinator_todo_id": coordinator_todo_id,
                    "label": label,
                }),
            )?
        }
        Command::Status { run_id } => {
            client.call("workflow.status", json!({ "run_id": run_id }))?
        }
        Command::Crafted { run_id } => {
            client.call("workflow.crafted", json!({ "run_id": run_id }))?
        }
        Command::Accept { run_id, note } => {
            client.call("workflow.accept", json!({ "run_id": run_id, "note": note }))?
        }
        Command::Reject {
            run_id,
            reason,
            rebrief,
        } => client.call(
            "workflow.reject",
            json!({ "run_id": run_id, "reason": reason, "rebrief": rebrief }),
        )?,
        Command::Stop { run_id } => client.call("workflow.stop", json!({ "run_id": run_id }))?,
        Command::List { project, state } => client.call(
            "workflow.list",
            json!({ "kind": "eternal", "project": project, "state": state }),
        )?,
    };
    Ok(response.data.unwrap_or_else(|| json!({})))
}

fn validate_eternal_engines(command: &Command) -> Result<(), String> {
    if let Command::Propose { engine, .. } = command {
        normalize_workflow_engine(engine)
            .map(|_| ())
            .map_err(|err| err.to_string())?;
    }
    Ok(())
}

fn runtime_selected() -> bool {
    ["TADO_PROFILE", "TADO_RUNTIME_SOCKET", "TADO_RUNTIME_ID"]
        .iter()
        .any(|key| {
            std::env::var_os(key)
                .map(|value| !value.is_empty())
                .unwrap_or(false)
        })
        || !std::path::Path::new("/tmp/tado-ipc/active-pid").exists()
}
