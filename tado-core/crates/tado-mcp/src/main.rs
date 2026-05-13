//! tado-mcp — stdio MCP server for Tado's A2A + settings + events surface.
//!
//! Ported from `tado-mcp/src/index.ts` + `tools/*.ts`. The JSON-RPC
//! framing mirrors `dome-mcp` at `tado-core/crates/dome-mcp/` byte-for-
//! byte (protocol version, capability shape, tool-call response
//! envelope) so an agent wired up with either server sees the same
//! stdio behavior.
//!
//! Ships 12 tools, matching the Node server surface one-for-one:
//!
//! - `tado_list` — read the session registry, optionally filter by
//!   `project` / `team`. Delegates to `tado_ipc::read_registry`.
//! - `tado_send` — resolve a target by UUID / grid coordinates / name
//!   substring, drop an envelope into `a2a-inbox/`.
//! - `tado_read` — tail a session's log file, ANSI-stripped.
//! - `tado_broadcast` — send to every session in a project/team.
//! - `tado_notify` — append a `user.broadcast` event to the NDJSON log.
//! - `tado_events_query` — tail + filter the NDJSON log.
//! - `tado_config_{get,set,list}` — scoped JSON config.
//! - `tado_memory_{read,append,search}` — scoped markdown memory.

use anyhow::{anyhow, Result};
use chrono::Utc;
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};
use uuid::Uuid;

const PROTOCOL_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "tado";
const SERVER_VERSION: &str = "0.1.0";

#[tokio::main]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("tado-mcp error: {err}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let stdin = io::stdin();
    let mut reader = BufReader::new(stdin).lines();
    let mut stdout = io::stdout();

    while let Some(line) = reader.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }

        let req: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(err) => {
                let resp = rpc_error(
                    Value::Null,
                    "ERR_PARSE",
                    &format!("invalid json: {err}"),
                );
                write_line(&mut stdout, &resp).await?;
                continue;
            }
        };

        let id = req.get("id").cloned().unwrap_or(Value::Null);
        let method = req
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let params = req.get("params").cloned().unwrap_or_else(|| json!({}));

        let response = match method {
            "initialize" => json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": { "tools": {} },
                    "serverInfo": {
                        "name": SERVER_NAME,
                        "version": SERVER_VERSION,
                    }
                }
            }),
            "tools/list" => json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "tools": tool_definitions(),
                }
            }),
            "tools/call" => {
                let tool_name = params
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let args = params
                    .get("arguments")
                    .cloned()
                    .unwrap_or_else(|| json!({}));
                match call_tool(tool_name, args).await {
                    Ok(text) => json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": {
                            "content": [{ "type": "text", "text": text }],
                            "isError": false,
                        }
                    }),
                    Err(err) => json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": {
                            "content": [{ "type": "text", "text": err.to_string() }],
                            "isError": true,
                        }
                    }),
                }
            }
            "notifications/initialized" => continue,
            _ => rpc_error(
                id,
                "ERR_METHOD_NOT_FOUND",
                &format!("unknown method: {method}"),
            ),
        };

        write_line(&mut stdout, &response).await?;
    }

    Ok(())
}

async fn write_line(stdout: &mut tokio::io::Stdout, value: &Value) -> Result<()> {
    stdout
        .write_all((value.to_string() + "\n").as_bytes())
        .await?;
    stdout.flush().await?;
    Ok(())
}

fn rpc_error(id: Value, code: &str, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message }
    })
}

// ── Tool catalog ────────────────────────────────────────────────

fn tool_definitions() -> Value {
    json!([
        {
            "name": "tado_list",
            "description": "List every active Tado terminal session. Optional filter by project or team name.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": { "type": "string", "description": "Filter by project name (case-insensitive exact match)." },
                    "team": { "type": "string", "description": "Filter by team name (case-insensitive exact match)." }
                }
            }
        },
        {
            "name": "tado_send",
            "description": "Send a message to another Tado terminal. Target can be a UUID, grid coordinates (e.g. '1,1'), or a name substring.",
            "inputSchema": {
                "type": "object",
                "required": ["target", "message"],
                "properties": {
                    "target": { "type": "string" },
                    "message": { "type": "string" },
                    "project": { "type": "string", "description": "Scope name resolution to a single project." }
                }
            }
        },
        {
            "name": "tado_notify",
            "description": "Publish a user-broadcast event to Tado's global event log. Shows up in Notifications + system banner.",
            "inputSchema": {
                "type": "object",
                "required": ["title"],
                "properties": {
                    "title": { "type": "string" },
                    "body": { "type": "string" },
                    "severity": { "type": "string", "enum": ["info", "success", "warning", "error"] }
                }
            }
        },
        {
            "name": "tado_events_query",
            "description": "Tail Tado's event log. Optional filters: since (ISO 8601), type (exact), severity (exact), limit (1-500).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "since": { "type": "string" },
                    "type": { "type": "string" },
                    "severity": { "type": "string" },
                    "limit": { "type": "integer", "minimum": 1, "maximum": 500 }
                }
            }
        },
        {
            "name": "tado_read",
            "description": "Read a Tado session's terminal output log (ANSI-stripped).",
            "inputSchema": {
                "type": "object",
                "required": ["target"],
                "properties": {
                    "target": { "type": "string" },
                    "tail": { "type": "integer", "description": "If set, return only the last N lines." },
                    "project": { "type": "string" }
                }
            }
        },
        {
            "name": "tado_broadcast",
            "description": "Send the same message to every session in a project and/or team.",
            "inputSchema": {
                "type": "object",
                "required": ["message"],
                "properties": {
                    "message": { "type": "string" },
                    "project": { "type": "string" },
                    "team": { "type": "string" }
                }
            }
        },
        {
            "name": "tado_config_get",
            "description": "Read one key from a scoped config file (global | project | project-local).",
            "inputSchema": {
                "type": "object",
                "required": ["scope", "key"],
                "properties": {
                    "scope": { "type": "string" },
                    "key": { "type": "string" }
                }
            }
        },
        {
            "name": "tado_config_set",
            "description": "Set one key in a scoped config file. String values are best-effort JSON-parsed (so \"42\" → 42).",
            "inputSchema": {
                "type": "object",
                "required": ["scope", "key", "value"],
                "properties": {
                    "scope": { "type": "string" },
                    "key": { "type": "string" },
                    "value": {}
                }
            }
        },
        {
            "name": "tado_config_list",
            "description": "Return the full JSON contents of a scoped config file.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "scope": { "type": "string", "description": "Defaults to 'global'." }
                }
            }
        },
        {
            "name": "tado_memory_read",
            "description": "Read the whole markdown memory file for a scope (user | project). Defaults to project.",
            "inputSchema": {
                "type": "object",
                "properties": { "scope": { "type": "string" } }
            }
        },
        {
            "name": "tado_memory_append",
            "description": "Append a dated + optionally tagged block to a scoped markdown memory file.",
            "inputSchema": {
                "type": "object",
                "required": ["text"],
                "properties": {
                    "text": { "type": "string" },
                    "scope": { "type": "string" },
                    "tags": { "type": "array", "items": { "type": "string" } }
                }
            }
        },
        {
            "name": "tado_memory_search",
            "description": "Grep (case-insensitive) across memory files. Scope: user | project | all (default).",
            "inputSchema": {
                "type": "object",
                "required": ["query"],
                "properties": {
                    "query": { "type": "string" },
                    "scope": { "type": "string" }
                }
            }
        }
    ])
}

async fn call_tool(name: &str, args: Value) -> Result<String> {
    match name {
        "tado_list" => tado_list(args),
        "tado_send" => tado_send(args),
        "tado_notify" => tado_notify(args),
        "tado_events_query" => tado_events_query(args),
        "tado_read" => tado_read(args),
        "tado_broadcast" => tado_broadcast(args),
        "tado_config_get" => tado_config_get(args),
        "tado_config_set" => tado_config_set(args),
        "tado_config_list" => tado_config_list(args),
        "tado_memory_read" => tado_memory_read(args),
        "tado_memory_append" => tado_memory_append(args),
        "tado_memory_search" => tado_memory_search(args),
        other => Err(anyhow!("unknown tool: {other}")),
    }
}

// ── Paths (mirrors `tado-mcp/src/paths.ts`) ──────────────────────

fn app_support_root() -> PathBuf {
    tado_settings::SettingsPaths::macos_default()
        .map(|paths| paths.app_support)
        .unwrap_or_else(|| {
            PathBuf::from("/")
                .join("Library")
                .join("Application Support")
                .join("Tado")
        })
}

fn events_current_path() -> PathBuf {
    app_support_root().join("events").join("current.ndjson")
}

// ── tado_list ────────────────────────────────────────────────────

fn tado_list(args: Value) -> Result<String> {
    let project = args.get("project").and_then(Value::as_str).map(str::to_lowercase);
    let team = args.get("team").and_then(Value::as_str).map(str::to_lowercase);

    let paths = tado_ipc::IpcPaths::stable();
    let mut entries = tado_ipc::read_registry(&paths).map_err(|e| anyhow!(e.to_string()))?;

    if let Some(p) = &project {
        entries.retain(|e| e.project_name.as_deref().map(|s| s.to_lowercase()) == Some(p.clone()));
    }
    if let Some(t) = &team {
        entries.retain(|e| e.team_name.as_deref().map(|s| s.to_lowercase()) == Some(t.clone()));
    }

    if entries.is_empty() {
        return Ok("No active Tado sessions found.".to_string());
    }

    // Table output matches the Node version: header + separator + rows.
    let header = ["Grid", "Engine", "Status", "Project", "Team", "Agent", "Name", "ID"];
    let rows: Vec<[String; 8]> = entries
        .iter()
        .map(|e| {
            let name = if e.name.len() > 50 {
                format!("{}...", &e.name[..47])
            } else {
                e.name.clone()
            };
            let sid_short = e.session_id.simple().to_string();
            let sid_short = sid_short[..8].to_string();
            [
                e.grid_label.clone(),
                e.engine.clone(),
                e.status.clone(),
                e.project_name.clone().unwrap_or_else(|| "-".into()),
                e.team_name.clone().unwrap_or_else(|| "-".into()),
                e.agent_name.clone().unwrap_or_else(|| "-".into()),
                name,
                sid_short,
            ]
        })
        .collect();

    let widths: [usize; 8] = {
        let mut w = [0usize; 8];
        for (i, h) in header.iter().enumerate() {
            w[i] = h.len();
        }
        for r in &rows {
            for (i, c) in r.iter().enumerate() {
                if c.len() > w[i] {
                    w[i] = c.len();
                }
            }
        }
        w
    };

    let fmt = |row: &[String]| {
        row.iter()
            .enumerate()
            .map(|(i, c)| format!("{:<width$}", c, width = widths[i]))
            .collect::<Vec<_>>()
            .join(" | ")
    };
    let header_vec: Vec<String> = header.iter().map(|s| (*s).to_string()).collect();
    let sep = widths.iter().map(|w| "-".repeat(*w)).collect::<Vec<_>>().join(" | ");

    let mut out = Vec::with_capacity(rows.len() + 2);
    out.push(fmt(&header_vec));
    out.push(sep);
    for r in &rows {
        out.push(fmt(r));
    }
    Ok(out.join("\n"))
}

// ── tado_send ────────────────────────────────────────────────────

fn tado_send(args: Value) -> Result<String> {
    let target = args
        .get("target")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_send: missing `target`"))?;
    let message = args
        .get("message")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_send: missing `message`"))?;
    let project = args.get("project").and_then(Value::as_str).map(str::to_lowercase);

    let paths = tado_ipc::IpcPaths::stable();
    let entries = tado_ipc::read_registry(&paths).map_err(|e| anyhow!(e.to_string()))?;

    let mut pool: Vec<&tado_ipc::IpcSessionEntry> = entries.iter().collect();
    if let Some(p) = &project {
        pool.retain(|e| e.project_name.as_deref().map(|s| s.to_lowercase()) == Some(p.clone()));
    }

    let Some(entry) = resolve_target(&pool, target) else {
        let available = entries
            .iter()
            .map(|e| {
                let n = if e.name.len() > 40 { &e.name[..40] } else { &e.name[..] };
                format!("  {} {n}", e.grid_label)
            })
            .collect::<Vec<_>>()
            .join("\n");
        let available = if available.is_empty() { "  (none)".to_string() } else { available };
        return Ok(format!(
            "Could not resolve target \"{target}\". Available sessions:\n{available}"
        ));
    };

    let msg = tado_ipc::IpcMessage::new(
        tado_ipc::IpcMessage::external_origin_uuid(),
        "tado-mcp".to_string(),
        entry.session_id,
        message.to_string(),
    );
    tado_ipc::write_external_message(&paths, &msg).map_err(|e| anyhow!(e.to_string()))?;

    let name_short = if entry.name.len() > 40 { &entry.name[..40] } else { &entry.name[..] };
    let msg_short = msg.id.simple().to_string();
    let msg_short = &msg_short[..8];
    Ok(format!(
        "Message sent to {} \"{name_short}\" (msg: {msg_short})",
        entry.grid_label
    ))
}

/// Target resolution mirrors the `resolveTarget` helper in
/// `tado-mcp/src/ipc/registry.ts` *and* the bash/python heredocs
/// generated by `IPCBroker.writeHelperScripts`:
///
/// 1. Exact UUID (36 chars with hyphens)
/// 2. Grid coordinates — `1,1`, `1:1`, `[1,1]`, `[1, 1]`
/// 3. Name substring (case-insensitive)
fn resolve_target<'a>(
    pool: &'a [&'a tado_ipc::IpcSessionEntry],
    target: &str,
) -> Option<&'a tado_ipc::IpcSessionEntry> {
    let t = target.trim().to_lowercase();

    // Exact UUID
    if t.len() == 36 {
        if let Ok(id) = Uuid::parse_str(&t) {
            if let Some(e) = pool.iter().find(|e| e.session_id == id) {
                return Some(e);
            }
        }
    }

    // Grid coordinates: strip brackets + spaces, split on `,` or `:`.
    let cleaned = t
        .replace(['[', ']'], "")
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>();
    for sep in [',', ':'] {
        if let Some((a, b)) = cleaned.split_once(sep) {
            if a.chars().all(|c| c.is_ascii_digit())
                && b.chars().all(|c| c.is_ascii_digit())
                && !a.is_empty()
                && !b.is_empty()
            {
                let label = format!("[{a}, {b}]");
                if let Some(e) = pool.iter().find(|e| e.grid_label == label) {
                    return Some(e);
                }
            }
        }
    }

    // Substring on name
    let matches: Vec<&&tado_ipc::IpcSessionEntry> =
        pool.iter().filter(|e| e.name.to_lowercase().contains(&t)).collect();
    if matches.len() == 1 {
        return Some(matches[0]);
    }
    None
}

// ── tado_notify ──────────────────────────────────────────────────

fn tado_notify(args: Value) -> Result<String> {
    let title = args
        .get("title")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_notify: missing `title`"))?;
    let body = args.get("body").and_then(Value::as_str).unwrap_or("");
    let severity = args
        .get("severity")
        .and_then(Value::as_str)
        .filter(|s| ["info", "success", "warning", "error"].contains(s))
        .unwrap_or("info");

    let id = Uuid::new_v4();
    let event = json!({
        "id": id,
        "ts": Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "type": "user.broadcast",
        "severity": severity,
        "source": { "kind": "user" },
        "title": title,
        "body": body,
        "actions": [],
        "read": false,
    });

    let path = events_current_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let line = event.to_string() + "\n";
    // Plain append — the OS serializes single append writes; we
    // accept a rare interleave risk (same trade-off the Node server
    // and CLI `tado-notify` make).
    let mut f = fs::OpenOptions::new().append(true).create(true).open(&path)?;
    f.write_all(line.as_bytes())?;
    Ok(format!("published: {}", id))
}

// ── tado_events_query ────────────────────────────────────────────

fn tado_events_query(args: Value) -> Result<String> {
    let path = events_current_path();
    if !path.exists() {
        return Ok("(no events yet — tado has not published anything to this log)".to_string());
    }

    let since_ms = args
        .get("since")
        .and_then(Value::as_str)
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.timestamp_millis());
    let type_filter = args.get("type").and_then(Value::as_str).map(str::to_string);
    let severity_filter = args.get("severity").and_then(Value::as_str).map(str::to_string);
    let limit = args
        .get("limit")
        .and_then(Value::as_i64)
        .map(|n| n.clamp(1, 500) as usize)
        .unwrap_or(100);

    let contents = fs::read_to_string(&path)?;
    let lines: Vec<&str> = contents.split('\n').collect();
    let mut matched: Vec<Value> = Vec::with_capacity(limit);

    // Newest-first by walking the file in reverse.
    for raw in lines.iter().rev() {
        if raw.trim().is_empty() {
            continue;
        }
        let event: Value = match serde_json::from_str(raw) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if let Some(t) = &type_filter {
            if event.get("type").and_then(Value::as_str) != Some(t.as_str()) {
                continue;
            }
        }
        if let Some(s) = &severity_filter {
            if event.get("severity").and_then(Value::as_str) != Some(s.as_str()) {
                continue;
            }
        }
        if let Some(min_ms) = since_ms {
            let ts = event
                .get("ts")
                .and_then(Value::as_str)
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .map(|d| d.timestamp_millis())
                .unwrap_or(i64::MAX);
            if ts < min_ms {
                continue;
            }
        }
        matched.push(event);
        if matched.len() >= limit {
            break;
        }
    }

    if matched.is_empty() {
        return Ok("(no matching events)".to_string());
    }

    let rendered: Vec<String> = matched
        .iter()
        .map(|e| {
            let ts = e.get("ts").and_then(Value::as_str).unwrap_or("-");
            let sev = e.get("severity").and_then(Value::as_str).unwrap_or("info");
            let kind = e.get("type").and_then(Value::as_str).unwrap_or("-");
            let title = e.get("title").and_then(Value::as_str).unwrap_or("");
            format!("{ts}  [{:<7}] {:<28} {title}", sev, kind)
        })
        .collect();
    Ok(rendered.join("\n"))
}

// ── tado_read ────────────────────────────────────────────────────

fn tado_read(args: Value) -> Result<String> {
    let target = args
        .get("target")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_read: missing `target`"))?;
    let tail = args.get("tail").and_then(Value::as_u64).map(|n| n as usize);
    let project = args.get("project").and_then(Value::as_str).map(str::to_lowercase);

    let paths = tado_ipc::IpcPaths::stable();
    let entries = tado_ipc::read_registry(&paths).map_err(|e| anyhow!(e.to_string()))?;
    let mut pool: Vec<&tado_ipc::IpcSessionEntry> = entries.iter().collect();
    if let Some(p) = &project {
        pool.retain(|e| e.project_name.as_deref().map(|s| s.to_lowercase()) == Some(p.clone()));
    }

    let Some(entry) = resolve_target(&pool, target) else {
        return Ok(format!("Could not resolve target \"{target}\"."));
    };

    let sid_lower = entry.session_id.as_hyphenated().to_string().to_lowercase();
    let log_path = paths.session_log(&sid_lower);
    if !log_path.exists() {
        return Ok(format!("No log file found for session {}", entry.session_id));
    }

    let raw = fs::read_to_string(&log_path)?;
    let stripped = strip_ansi(&raw);
    if let Some(n) = tail {
        let lines: Vec<&str> = stripped.split('\n').collect();
        let start = lines.len().saturating_sub(n);
        return Ok(lines[start..].join("\n"));
    }
    Ok(stripped)
}

/// Match + drop ANSI CSI, OSC, and SS2/SS3/charset escapes. Mirrors
/// the regex in `tado-mcp/src/ipc/logs.ts`. Intentionally a subset
/// of the VT500 grammar — agents generally only care about the text
/// content, not the formatting.
fn strip_ansi(s: &str) -> String {
    use regex::Regex;
    use std::sync::OnceLock;
    static ANSI_RE: OnceLock<Regex> = OnceLock::new();
    let re = ANSI_RE.get_or_init(|| {
        // Split the alternatives across multiple concat!() pieces
        // so it's legible. The `x1b` literal is the ESC byte.
        Regex::new(concat!(
            r"(\x1b\[[0-9;]*[A-Za-z]",              // CSI sequences
            r"|\x1b\].*?(?:\x07|\x1b\\)",           // OSC, ST-terminated
            r"|\x1b[()][AB012]",                     // charset select
            r"|\x1b[>=<]",                           // keypad / app modes
            r"|\x1b\[\??[0-9;]*[hlm])"               // SGR + mode toggles
        ))
        .expect("strip_ansi regex compiles")
    });
    re.replace_all(s, "").into_owned()
}

// ── tado_broadcast ──────────────────────────────────────────────

fn tado_broadcast(args: Value) -> Result<String> {
    let message = args
        .get("message")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_broadcast: missing `message`"))?;
    let project = args.get("project").and_then(Value::as_str).map(str::to_lowercase);
    let team = args.get("team").and_then(Value::as_str).map(str::to_lowercase);

    let paths = tado_ipc::IpcPaths::stable();
    let entries = tado_ipc::read_registry(&paths).map_err(|e| anyhow!(e.to_string()))?;
    let mut targets: Vec<&tado_ipc::IpcSessionEntry> = entries.iter().collect();
    if let Some(p) = &project {
        targets.retain(|e| e.project_name.as_deref().map(|s| s.to_lowercase()) == Some(p.clone()));
    }
    if let Some(t) = &team {
        targets.retain(|e| e.team_name.as_deref().map(|s| s.to_lowercase()) == Some(t.clone()));
    }
    if targets.is_empty() {
        return Ok("No matching sessions to broadcast to.".to_string());
    }

    for entry in &targets {
        let msg = tado_ipc::IpcMessage::new(
            tado_ipc::IpcMessage::external_origin_uuid(),
            "tado-mcp".to_string(),
            entry.session_id,
            message.to_string(),
        );
        tado_ipc::write_external_message(&paths, &msg).map_err(|e| anyhow!(e.to_string()))?;
    }
    let grids: Vec<&str> = targets.iter().map(|e| e.grid_label.as_str()).collect();
    Ok(format!(
        "Broadcast sent to {} session(s): {}",
        targets.len(),
        grids.join(", ")
    ))
}

// ── tado_config_{get,set,list} ──────────────────────────────────

fn resolve_config_path(scope: &str) -> Result<PathBuf> {
    match scope {
        "global" => Ok(app_support_root().join("settings").join("global.json")),
        "project" | "project-shared" => project_config_path()
            .ok_or_else(|| anyhow!("No .tado/ directory found above the current working directory")),
        "project-local" | "local" => project_local_path()
            .ok_or_else(|| anyhow!("No .tado/ directory found above the current working directory")),
        _ => Err(anyhow!(
            "unknown scope: {scope} (expected: global | project | project-local)"
        )),
    }
}

fn find_project_root(cwd: &Path) -> Option<PathBuf> {
    let mut dir = cwd.to_path_buf();
    loop {
        if dir.join(".tado").is_dir() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

fn project_config_path() -> Option<PathBuf> {
    let cwd = std::env::current_dir().ok()?;
    find_project_root(&cwd).map(|r| r.join(".tado").join("config.json"))
}

fn project_local_path() -> Option<PathBuf> {
    let cwd = std::env::current_dir().ok()?;
    find_project_root(&cwd).map(|r| r.join(".tado").join("local.json"))
}

fn project_memory_path() -> Option<PathBuf> {
    let cwd = std::env::current_dir().ok()?;
    find_project_root(&cwd).map(|r| r.join(".tado").join("memory").join("project.md"))
}

fn project_notes_dir() -> Option<PathBuf> {
    let cwd = std::env::current_dir().ok()?;
    find_project_root(&cwd).map(|r| r.join(".tado").join("memory").join("notes"))
}

fn user_memory_path() -> PathBuf {
    app_support_root().join("memory").join("user.md")
}

fn tado_config_get(args: Value) -> Result<String> {
    let scope = args
        .get("scope")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_config_get: missing `scope`"))?;
    let key = args
        .get("key")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_config_get: missing `key`"))?;
    let path = resolve_config_path(scope)?;
    let data: Value = tado_settings::read_json(&path)
        .map_err(|e| anyhow!(e.to_string()))?
        .unwrap_or_else(|| json!({}));
    let value = navigate(&data, key);
    match value {
        None => Ok("(unset)".to_string()),
        Some(v) => match v {
            Value::String(s) => Ok(s.clone()),
            _ => Ok(serde_json::to_string_pretty(v).unwrap_or_else(|_| "null".to_string())),
        },
    }
}

fn tado_config_set(args: Value) -> Result<String> {
    let scope = args
        .get("scope")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_config_set: missing `scope`"))?;
    let key = args
        .get("key")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_config_set: missing `key`"))?;
    let raw = args
        .get("value")
        .cloned()
        .ok_or_else(|| anyhow!("tado_config_set: missing `value`"))?;

    // Best-effort coercion: if the caller passed a JSON string that
    // itself parses as JSON, unwrap it ("42" → 42, "true" → true,
    // "[1,2]" → array). Raw non-string values are passed through.
    let coerced = match &raw {
        Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(raw.clone()),
        _ => raw,
    };

    let path = resolve_config_path(scope)?;
    let mut data: Value = tado_settings::read_json(&path)
        .map_err(|e| anyhow!(e.to_string()))?
        .unwrap_or_else(|| json!({}));
    set_path(&mut data, key, coerced);
    // Writer-trace metadata — mirrors the Node server so a round-
    // trip through Rust preserves the audit convention.
    if let Some(obj) = data.as_object_mut() {
        obj.insert("writer".to_string(), Value::String("tado-mcp".to_string()));
        obj.insert(
            "updatedAt".to_string(),
            Value::String(Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
        );
    }
    tado_settings::write_json(&path, &data).map_err(|e| anyhow!(e.to_string()))?;
    Ok(format!("set {scope}.{key}"))
}

fn tado_config_list(args: Value) -> Result<String> {
    let scope = args.get("scope").and_then(Value::as_str).unwrap_or("global");
    let path = resolve_config_path(scope)?;
    let data: Value = tado_settings::read_json(&path)
        .map_err(|e| anyhow!(e.to_string()))?
        .unwrap_or_else(|| json!({}));
    Ok(serde_json::to_string_pretty(&data).unwrap_or_else(|_| "{}".to_string()))
}

fn navigate<'a>(obj: &'a Value, key: &str) -> Option<&'a Value> {
    let mut cursor = obj;
    for part in key.split('.') {
        cursor = cursor.as_object()?.get(part)?;
    }
    Some(cursor)
}

fn set_path(obj: &mut Value, key: &str, value: Value) {
    let parts: Vec<&str> = key.split('.').collect();
    if parts.is_empty() {
        return;
    }
    let mut cursor = obj;
    for part in &parts[..parts.len() - 1] {
        if !cursor.is_object() {
            *cursor = json!({});
        }
        let map = cursor.as_object_mut().unwrap();
        if !map.get(*part).map(Value::is_object).unwrap_or(false) {
            map.insert((*part).to_string(), json!({}));
        }
        cursor = map.get_mut(*part).unwrap();
    }
    if !cursor.is_object() {
        *cursor = json!({});
    }
    cursor
        .as_object_mut()
        .unwrap()
        .insert(parts[parts.len() - 1].to_string(), value);
}

// ── tado_memory_{read,append,search} ────────────────────────────

fn resolve_memory_path(scope: &str) -> Result<PathBuf> {
    match scope {
        "user" => Ok(user_memory_path()),
        "project" => project_memory_path()
            .ok_or_else(|| anyhow!("No .tado/ directory found above the current working directory")),
        _ => Err(anyhow!("unknown scope: {scope} (expected: user | project)")),
    }
}

fn tado_memory_read(args: Value) -> Result<String> {
    let scope = args.get("scope").and_then(Value::as_str).unwrap_or("project");
    let path = resolve_memory_path(scope)?;
    if !path.exists() {
        return Ok(format!(
            "(empty — no {scope} memory file yet at {})",
            path.display()
        ));
    }
    Ok(fs::read_to_string(&path)?)
}

fn tado_memory_append(args: Value) -> Result<String> {
    let text = args
        .get("text")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_memory_append: missing `text`"))?;
    if text.trim().is_empty() {
        return Ok("refusing to append empty note".to_string());
    }
    let scope = args.get("scope").and_then(Value::as_str).unwrap_or("project");
    let tags: Vec<String> = args
        .get("tags")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();

    let path = resolve_memory_path(scope)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    if !path.exists() {
        fs::write(&path, "")?;
    }

    let iso = Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let tag_line = if tags.is_empty() {
        String::new()
    } else {
        format!("\n_tags: {}_", tags.join(", "))
    };
    let entry = format!("\n\n## {iso}{tag_line}\n\n{}\n", text.trim());
    let mut f = fs::OpenOptions::new().append(true).open(&path)?;
    f.write_all(entry.as_bytes())?;
    Ok(format!("appended {} chars to {}", text.len(), path.display()))
}

fn tado_memory_search(args: Value) -> Result<String> {
    let query = args
        .get("query")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("tado_memory_search: missing `query`"))?;
    let q_lower = query.to_lowercase();
    let scope = args.get("scope").and_then(Value::as_str).unwrap_or("all");

    let mut files: Vec<PathBuf> = Vec::new();
    if scope == "user" || scope == "all" {
        files.push(user_memory_path());
    }
    if scope == "project" || scope == "all" {
        if let Some(p) = project_memory_path() {
            files.push(p);
        }
        if let Some(dir) = project_notes_dir() {
            if let Ok(rd) = fs::read_dir(&dir) {
                for entry in rd.flatten() {
                    let p = entry.path();
                    if p.extension().and_then(|e| e.to_str()) == Some("md") {
                        files.push(p);
                    }
                }
            }
        }
    }

    let mut hits: Vec<String> = Vec::new();
    for file in files {
        if !file.exists() {
            continue;
        }
        let Ok(contents) = fs::read_to_string(&file) else {
            continue;
        };
        for (idx, line) in contents.split('\n').enumerate() {
            if line.to_lowercase().contains(&q_lower) {
                hits.push(format!(
                    "{}:{}: {}",
                    file.display(),
                    idx + 1,
                    line.trim()
                ));
            }
        }
    }
    if hits.is_empty() {
        return Ok(format!("no matches for \"{query}\""));
    }
    let take = hits.iter().take(100).cloned().collect::<Vec<_>>();
    Ok(take.join("\n"))
}

// Required `use` for above helpers.
use std::path::Path;

#[cfg(test)]
mod tests {
    use super::*;

    fn entry_with(grid: &str, name: &str, project: Option<&str>) -> tado_ipc::IpcSessionEntry {
        tado_ipc::IpcSessionEntry {
            session_id: Uuid::new_v4(),
            name: name.to_string(),
            engine: "claude".to_string(),
            grid_label: grid.to_string(),
            status: "running".to_string(),
            project_name: project.map(str::to_string),
            agent_name: None,
            team_name: None,
            team_id: None,
        }
    }

    #[test]
    fn resolve_by_grid_coordinates() {
        let e1 = entry_with("[1, 1]", "alpha", None);
        let e2 = entry_with("[2, 1]", "beta", None);
        let pool: Vec<&tado_ipc::IpcSessionEntry> = vec![&e1, &e2];
        assert_eq!(resolve_target(&pool, "1,1").map(|e| &e.name), Some(&e1.name));
        assert_eq!(resolve_target(&pool, "2:1").map(|e| &e.name), Some(&e2.name));
        assert_eq!(resolve_target(&pool, "[1, 1]").map(|e| &e.name), Some(&e1.name));
    }

    #[test]
    fn resolve_by_uuid_exact() {
        let e1 = entry_with("[1, 1]", "alpha", None);
        let pool: Vec<&tado_ipc::IpcSessionEntry> = vec![&e1];
        let id = e1.session_id.as_hyphenated().to_string();
        assert_eq!(resolve_target(&pool, &id).map(|e| e.session_id), Some(e1.session_id));
    }

    #[test]
    fn resolve_by_name_substring_single_match() {
        let e1 = entry_with("[1, 1]", "auth-service", None);
        let e2 = entry_with("[1, 2]", "cache-warmer", None);
        let pool: Vec<&tado_ipc::IpcSessionEntry> = vec![&e1, &e2];
        assert_eq!(resolve_target(&pool, "auth").map(|e| &e.name), Some(&e1.name));
    }

    #[test]
    fn resolve_fails_when_multiple_name_matches() {
        let e1 = entry_with("[1, 1]", "auth-service-a", None);
        let e2 = entry_with("[1, 2]", "auth-service-b", None);
        let pool: Vec<&tado_ipc::IpcSessionEntry> = vec![&e1, &e2];
        assert!(resolve_target(&pool, "auth").is_none());
    }
}
