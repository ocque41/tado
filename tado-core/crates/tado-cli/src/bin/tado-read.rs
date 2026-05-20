use std::thread;
use std::time::Duration;

use anyhow::Result;
use clap::Parser;
use serde_json::{json, Value};
use tado_runtime::{ensure_daemon, profile_from_env};

#[derive(Parser, Debug)]
#[command(name = "tado-read")]
#[command(about = "Read session output from the active Tado CLI runtime profile.")]
struct Cli {
    #[arg(long)]
    profile: Option<String>,
    #[arg(long)]
    tail: Option<usize>,
    #[arg(long)]
    follow: bool,
    #[arg(long)]
    raw: bool,
    target: String,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let profile = profile_from_env(cli.profile);
    let client = ensure_daemon(&profile)?;
    let limit = cli.tail.unwrap_or(80).min(500);

    if !cli.follow {
        let data = client
            .call(
                "session.read",
                json!({ "target": cli.target, "limit": limit }),
            )?
            .data
            .unwrap_or_else(|| json!({}));
        let text = data.get("text").and_then(Value::as_str).unwrap_or("");
        print!("{}", maybe_strip_ansi(text, cli.raw));
        return Ok(());
    }

    let initial = client
        .call(
            "transcript.tail",
            json!({
                "target": cli.target,
                "limit": limit,
            }),
        )?
        .data
        .unwrap_or_else(|| json!({}));
    let mut cursor = initial.get("cursor").and_then(Value::as_i64).unwrap_or(0);
    if let Some(chunks) = initial.get("chunks").and_then(Value::as_array) {
        for chunk in chunks {
            let text = chunk.get("chunk").and_then(Value::as_str).unwrap_or("");
            print!("{}", maybe_strip_ansi(text, cli.raw));
        }
    }

    loop {
        let data = client
            .call(
                "transcript.read",
                json!({
                    "target": cli.target,
                    "after_cursor": cursor,
                    "limit": limit,
                }),
            )?
            .data
            .unwrap_or_else(|| json!({}));
        cursor = data.get("cursor").and_then(Value::as_i64).unwrap_or(cursor);
        if let Some(chunks) = data.get("chunks").and_then(Value::as_array) {
            for chunk in chunks {
                let text = chunk.get("chunk").and_then(Value::as_str).unwrap_or("");
                print!("{}", maybe_strip_ansi(text, cli.raw));
            }
        }
        thread::sleep(Duration::from_millis(500));
    }
}

fn maybe_strip_ansi(text: &str, raw: bool) -> String {
    if raw {
        text.to_string()
    } else {
        strip_ansi(text)
    }
}

fn strip_ansi(text: &str) -> String {
    let mut out = Vec::with_capacity(text.len());
    let mut bytes = text.bytes().peekable();
    while let Some(byte) = bytes.next() {
        if byte != 0x1B {
            out.push(byte);
            continue;
        }
        if matches!(bytes.peek(), Some(b'[' | b']' | b'(' | b')')) {
            let introducer = bytes.next();
            while let Some(next) = bytes.next() {
                if introducer == Some(b']') && next == 0x07 {
                    break;
                }
                if introducer != Some(b']') && (0x40..=0x7E).contains(&next) {
                    break;
                }
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}
