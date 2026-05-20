use anyhow::Result;
use clap::Parser;
use serde_json::{json, Value};
use tado_cli::{print_json, OutputMode};
use tado_runtime::{ensure_daemon, profile_from_env};

#[derive(Parser, Debug)]
#[command(name = "tado-list")]
#[command(about = "List sessions in the active Tado CLI runtime profile.")]
struct Cli {
    #[arg(long)]
    profile: Option<String>,
    #[arg(long)]
    human: bool,
    #[arg(long)]
    toon: bool,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let mode = OutputMode::from_flags(cli.human, cli.toon);
    let profile = profile_from_env(cli.profile);
    let client = ensure_daemon(&profile)?;
    let data = client
        .call("session.list", json!({}))?
        .data
        .unwrap_or_else(|| json!({ "sessions": [] }));
    if mode == OutputMode::Toon {
        print_json(
            data.get("sessions").unwrap_or(&Value::Array(Vec::new())),
            mode,
        );
    } else {
        print_json(&data, mode);
    }
    Ok(())
}
