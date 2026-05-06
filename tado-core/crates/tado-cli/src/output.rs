//! Output formatting. The coordinator agent and other LLMs
//! consume CLI output as their next-step input — keep it
//! machine-readable by default. Human-friendly modes are flag-gated.

use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputMode {
    /// Single-line JSON. Default; what the coordinator agent reads.
    Json,
    /// `serde_json` pretty-printed. `--human`. Two spaces / newlines.
    Human,
    /// AXI-style compact: tab-separated key=value lines, one record
    /// per line for arrays. `--toon`. Roughly 45% fewer tokens than
    /// pretty JSON for the same data — the coordinator can pick
    /// this when its context budget is tight.
    Toon,
}

impl OutputMode {
    pub fn from_flags(human: bool, toon: bool) -> Self {
        if toon { return Self::Toon; }
        if human { return Self::Human; }
        Self::Json
    }
}

pub fn print_json(value: &Value, mode: OutputMode) {
    match mode {
        OutputMode::Json => {
            println!("{}", value);
        }
        OutputMode::Human => {
            println!("{}", serde_json::to_string_pretty(value).unwrap_or_default());
        }
        OutputMode::Toon => {
            print_toon(value);
        }
    }
}

/// Pretty-print a `Response` envelope. CLI-shaped: success returns
/// the inner data; failure prints the error code + message and
/// exits with non-zero.
pub fn print_response(resp: crate::control_client::Response, mode: OutputMode) -> i32 {
    if resp.ok {
        if let Some(data) = resp.data {
            print_json(&data, mode);
        } else {
            print_json(&serde_json::json!({"ok": true}), mode);
        }
        0
    } else {
        let code = resp.error.unwrap_or_else(|| "unknown".into());
        let msg = resp
            .data
            .as_ref()
            .and_then(|d| d.get("message"))
            .and_then(|m| m.as_str())
            .unwrap_or("(no message)")
            .to_string();
        eprintln!("error [{code}]: {msg}");
        if let Some(data) = resp.data {
            // Echo the full data block so machine-parseable error
            // shapes (state_mismatch with actual state, no_match with
            // candidate list, etc.) reach the coordinator's eyes.
            eprintln!("{}", serde_json::to_string(&data).unwrap_or_default());
        }
        1
    }
}

fn print_toon(value: &Value) {
    match value {
        Value::Array(items) => {
            for item in items {
                print_toon_record(item);
                println!("---");
            }
        }
        _ => print_toon_record(value),
    }
}

fn print_toon_record(value: &Value) {
    if let Value::Object(map) = value {
        for (k, v) in map {
            let display = match v {
                Value::String(s) => s.clone(),
                Value::Null => "(null)".to_string(),
                Value::Bool(b) => b.to_string(),
                Value::Number(n) => n.to_string(),
                _ => v.to_string(),
            };
            println!("{}\t{}", k, display);
        }
    } else {
        println!("{}", value);
    }
}
