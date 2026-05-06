//! tado-system — app + vault status snapshot.
//!
//! Subcommands:
//!   status — pid, version, storage root, vault path, vault
//!            existence. Reads through the IPC socket so a clean
//!            "Tado is not running" diagnosis is possible.
//!   vault  — alias of status that omits non-vault fields.

use clap::{Parser, Subcommand};
use serde_json::json;
use tado_cli::{control_client, print_response, OutputMode};

#[derive(Parser)]
#[command(name = "tado-system")]
#[command(about = "Coordinator-driven Tado system + vault status.", long_about = None)]
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
    Status,
    Vault,
}

fn main() {
    let cli = Cli::parse();
    let mode = OutputMode::from_flags(cli.human, cli.toon);

    let result = control_client::call("system.status", json!({}));

    let exit = match (cli.command, result) {
        (_, Err(e)) => {
            eprintln!("{e}");
            1
        }
        (Command::Status, Ok(resp)) => print_response(resp, mode),
        (Command::Vault, Ok(resp)) => {
            // Filter to vault-related fields only.
            let resp_filtered = if let Some(data) = resp.data {
                let vault_only = json!({
                    "vault_path": data.get("vault_path"),
                    "vault_exists": data.get("vault_exists"),
                });
                control_client::Response {
                    request_id: resp.request_id,
                    ok: true,
                    data: Some(vault_only),
                    error: None,
                }
            } else {
                resp
            };
            print_response(resp_filtered, mode)
        }
    };
    std::process::exit(exit);
}
