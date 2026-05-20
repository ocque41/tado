use std::os::unix::net::UnixStream;

use anyhow::Result;
use clap::Parser;
use serde_json::{json, Value};
use tado_cli::{print_json, OutputMode};
use tado_runtime::protocol::{read_json_frame, write_json_frame, RuntimeRequest, RuntimeResponse};
use tado_runtime::{ensure_daemon, profile_from_env};

#[derive(Parser, Debug)]
#[command(name = "tado-events")]
#[command(about = "Read or follow events from the active Tado CLI runtime profile.")]
struct Cli {
    #[arg(long)]
    profile: Option<String>,
    #[arg(long)]
    human: bool,
    #[arg(long)]
    toon: bool,
    #[arg(long)]
    follow: bool,
    #[arg(long, default_value_t = 80)]
    tail: usize,
    filter: Option<String>,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let mode = OutputMode::from_flags(cli.human, cli.toon);
    let profile = profile_from_env(cli.profile);
    let client = ensure_daemon(&profile)?;
    let filter = cli.filter.unwrap_or_else(|| "*".to_string());

    let data = client
        .call("events.list", json!({ "limit": cli.tail.min(500) }))?
        .data
        .unwrap_or_else(|| json!({ "events": [] }));
    let events = filter_events(
        data.get("events").and_then(Value::as_array),
        filter.as_str(),
    );
    let mut cursor = events
        .iter()
        .filter_map(|event| event.get("id")?.as_i64())
        .max()
        .unwrap_or(0);

    if !cli.follow {
        if mode == OutputMode::Toon {
            print_json(&Value::Array(events), mode);
        } else {
            print_json(&json!({ "events": events }), mode);
        }
        return Ok(());
    }

    for event in &events {
        print_event(event, mode);
    }

    let request = RuntimeRequest::new(
        "events.stream",
        json!({
            "after_id": cursor,
            "limit": 100,
            "poll_ms": 250,
        }),
    );
    let mut stream = UnixStream::connect(&client.paths.socket_path)?;
    write_json_frame(&mut stream, &request)?;

    loop {
        let response: RuntimeResponse = read_json_frame(&mut stream)?;
        if !response.ok {
            if let Some(err) = response.error {
                anyhow::bail!("event stream error [{}]: {}", err.code, err.message);
            }
            anyhow::bail!("event stream error");
        }
        let Some(data) = response.data else {
            continue;
        };
        cursor = data.get("cursor").and_then(Value::as_i64).unwrap_or(cursor);
        let events = filter_events(
            data.get("events").and_then(Value::as_array),
            filter.as_str(),
        );
        for event in &events {
            print_event(event, mode);
        }
    }
}

fn filter_events(events: Option<&Vec<Value>>, filter: &str) -> Vec<Value> {
    let Some(events) = events else {
        return Vec::new();
    };
    if filter == "*" || filter.trim().is_empty() {
        return events.clone();
    }
    events
        .iter()
        .filter(|event| event_matches(event, filter))
        .cloned()
        .collect()
}

fn event_matches(event: &Value, filter: &str) -> bool {
    let kind = event.get("kind").and_then(Value::as_str).unwrap_or("");
    let subject = event
        .get("subject_id")
        .and_then(Value::as_str)
        .unwrap_or("");
    let message = event.get("message").and_then(Value::as_str).unwrap_or("");
    if let Some(kind_filter) = filter.strip_prefix("kind:") {
        return kind.starts_with(kind_filter);
    }
    if let Some(session_filter) = filter.strip_prefix("session:") {
        return subject.starts_with(session_filter);
    }
    kind.contains(filter) || subject.contains(filter) || message.contains(filter)
}

fn print_event(event: &Value, mode: OutputMode) {
    match mode {
        OutputMode::Json => println!("{}", event),
        OutputMode::Human => println!(
            "{}",
            serde_json::to_string_pretty(event).unwrap_or_default()
        ),
        OutputMode::Toon => {
            let id = event.get("id").and_then(Value::as_i64).unwrap_or_default();
            let kind = event.get("kind").and_then(Value::as_str).unwrap_or("");
            let subject = event
                .get("subject_id")
                .and_then(Value::as_str)
                .unwrap_or("");
            let message = event.get("message").and_then(Value::as_str).unwrap_or("");
            println!("{id}\t{kind}\t{subject}\t{message}");
        }
    }
}
