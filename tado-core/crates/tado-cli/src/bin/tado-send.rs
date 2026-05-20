use anyhow::{anyhow, Result};
use clap::Parser;
use serde_json::json;
use tado_cli::{print_json, OutputMode};
use tado_runtime::{ensure_daemon, profile_from_env};

#[derive(Parser, Debug)]
#[command(name = "tado-send")]
#[command(about = "Send text to a live session in the active Tado CLI runtime profile.")]
struct Cli {
    #[arg(long)]
    profile: Option<String>,
    #[arg(long)]
    human: bool,
    #[arg(long)]
    toon: bool,
    #[arg(long)]
    no_enter: bool,
    target: String,
    message: Vec<String>,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let message = cli.message.join(" ");
    if message.trim().is_empty() {
        return Err(anyhow!("tado-send requires a message"));
    }
    let mode = OutputMode::from_flags(cli.human, cli.toon);
    let profile = profile_from_env(cli.profile);
    let client = ensure_daemon(&profile)?;
    let data = client
        .call(
            "session.send",
            json!({
                "target": cli.target,
                "message": message,
                "enter": !cli.no_enter,
            }),
        )?
        .data
        .unwrap_or_else(|| json!({ "ok": true }));
    print_json(&data, mode);
    Ok(())
}
