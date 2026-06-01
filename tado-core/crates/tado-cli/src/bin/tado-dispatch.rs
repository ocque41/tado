//! tado-dispatch — drive the Dispatch lifecycle from the CLI.
//!
//! Same surface as tado-eternal, less complex: no completion marker.

use clap::{Parser, Subcommand};
use serde_json::{json, Value};
use tado_cli::{control_client, print_response, OutputMode};
use tado_runtime::{ensure_daemon, profile_from_env};

#[derive(Parser)]
#[command(name = "tado-dispatch")]
#[command(about = "Coordinator-driven Dispatch lifecycle CLI.", long_about = None)]
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
    Propose {
        #[arg(long)]
        project: String,
        #[arg(long)]
        feature: String,
        #[arg(long)]
        task: String,
        #[arg(long = "coordinator-todo-id")]
        coordinator_todo_id: String,
        #[arg(long)]
        label: Option<String>,
        #[arg(long, default_value = "codex")]
        engine: String,
        #[arg(long = "type", default_value = "sequential", value_parser = ["sequential", "wave"])]
        execution_type: String,
        #[arg(long = "layout", default_value = "grid", value_parser = ["grid", "kanban"])]
        dispatch_mode: String,
    },
    Status {
        run_id: String,
    },
    Crafted {
        run_id: String,
    },
    Accept {
        run_id: String,
        #[arg(long)]
        note: Option<String>,
    },
    Reject {
        run_id: String,
        #[arg(long)]
        reason: String,
        #[arg(long)]
        rebrief: Option<String>,
    },
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

    if runtime_selected() {
        let exit = match runtime_dispatch(cli.command) {
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
            coordinator_todo_id,
            label,
            engine: _,
            execution_type,
            dispatch_mode,
        } => {
            let mut payload = json!({
                "project": project,
                "feature": feature,
                "task": task,
                "coordinator_todo_id": coordinator_todo_id,
                "brief": task,
                "execution_type": execution_type,
                "dispatch_mode": dispatch_mode,
            });
            if let Some(l) = label {
                payload["label"] = json!(l);
            }
            control_client::call("dispatch.propose", payload)
        }
        Command::Status { run_id } => {
            control_client::call("dispatch.status", json!({ "run_id": run_id }))
        }
        Command::Crafted { run_id } => {
            control_client::call("dispatch.crafted", json!({ "run_id": run_id }))
        }
        Command::Accept { run_id, note } => {
            let mut payload = json!({ "run_id": run_id });
            if let Some(n) = note {
                payload["note"] = json!(n);
            }
            control_client::call("dispatch.accept", payload)
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
            control_client::call("dispatch.reject", payload)
        }
        Command::List { project, state } => {
            let mut payload = json!({});
            if let Some(p) = project {
                payload["project"] = json!(p);
            }
            if let Some(s) = state {
                payload["state"] = json!(s);
            }
            control_client::call("dispatch.list", payload)
        }
    };

    let exit = match result {
        Ok(resp) => print_response(resp, mode),
        Err(e) => {
            eprintln!("{e}");
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

fn runtime_dispatch(command: Command) -> anyhow::Result<Value> {
    let client = ensure_daemon(&profile_from_env(None))?;
    let response = match command {
        Command::Propose {
            project,
            feature,
            task,
            coordinator_todo_id,
            label,
            engine,
            execution_type,
            dispatch_mode,
        } => client.call(
            "workflow.propose",
            json!({
                "kind": "dispatch",
                "project": project,
                "feature": feature,
                "task": task,
                "mode": execution_type,
                "layout": dispatch_mode,
                "engine": engine,
                "coordinator_todo_id": coordinator_todo_id,
                "label": label,
            }),
        )?,
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
        Command::List { project, state } => client.call(
            "workflow.list",
            json!({ "kind": "dispatch", "project": project, "state": state }),
        )?,
    };
    Ok(response.data.unwrap_or_else(|| json!({})))
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
