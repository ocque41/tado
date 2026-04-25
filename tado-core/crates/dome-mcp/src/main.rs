//! bt-mcp — stdio MCP server for Dome.
//!
//! Exposes high-level tools to AI agents:
//!
//! - `dome_search(query, limit?, topic?, scope?)` — hybrid search
//!   across user + agent notes. Wraps `search.query` on bt-core.
//! - `dome_read(note_id)` — return a note's body + metadata. Wraps
//!   `doc.get`.
//! - `dome_note(text, topic?, title?, tags?, scope?)` — append-style
//!   agent-note write. Creates a new doc if no `doc_id` is given,
//!   otherwise appends to the existing one. Scope defaults to
//!   `"agent"`; bt-core's write barrier rejects `scope: "user"`
//!   regardless of what MCP lets through.
//! - `dome_schedule(name, schedule_kind, spec, prompt, context_key?)`
//!   — create a calendar automation. Wraps `automation.create`.
//! - `dome_graph_query(...)`, `dome_context_resolve(...)`,
//!   `dome_context_compact(...)`, `dome_agent_status(...)` — expose
//!   the graph/context/status contract Claude agents must use before
//!   making stale architecture or completion claims.
//!
//! The underlying rich RPC surface is still available to the desktop
//! shell, CLI, and future tooling; it's just deliberately _not_
//! exposed here. This keeps the agent tool surface small, legible,
//! and hard to misuse.

use anyhow::{anyhow, Result};
use bt_core::{rpc::RpcClient, Actor};
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};

const PROTOCOL_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "dome";
const SERVER_VERSION: &str = "0.2.0";

#[tokio::main]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("bt-mcp error: {}", err);
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let (vault_path, raw_token) = parse_args()?;
    let socket = socket_for(&vault_path)?;
    let client = RpcClient::new(socket);

    let auth = client
        .call("auth.agent_validate", json!({ "token": raw_token }))
        .await
        .map_err(|e| anyhow!(e.to_string()))?;
    let token_id = auth
        .get("token_id")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("token validation missing token_id"))?
        .to_string();

    let actor = Actor::Agent { token_id };

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
                let resp =
                    json_rpc_error(Value::Null, "ERR_PARSE", &format!("invalid json: {}", err));
                stdout
                    .write_all((resp.to_string() + "\n").as_bytes())
                    .await?;
                stdout.flush().await?;
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
                        "version": SERVER_VERSION
                    }
                }
            }),
            "tools/list" => json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "tools": tool_definitions()
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
                match call_tool(&client, &actor, tool_name, args).await {
                    Ok(result) => json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": {
                            "content": [{
                                "type": "text",
                                "text": serde_json::to_string(&result).unwrap_or_else(|_| "{}".to_string())
                            }],
                            "isError": false
                        }
                    }),
                    Err(err) => json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": {
                            "content": [{
                                "type": "text",
                                "text": err.to_string()
                            }],
                            "isError": true
                        }
                    }),
                }
            }
            "notifications/initialized" => continue,
            _ => json_rpc_error(
                id,
                "ERR_METHOD_NOT_FOUND",
                &format!("unknown method: {}", method),
            ),
        };

        stdout
            .write_all((response.to_string() + "\n").as_bytes())
            .await?;
        stdout.flush().await?;
    }

    Ok(())
}

// ── Tool dispatch ────────────────────────────────────────────────

async fn call_tool(client: &RpcClient, actor: &Actor, name: &str, args: Value) -> Result<Value> {
    match name {
        "dome_search" => dome_search(client, actor, args).await,
        "dome_read" => dome_read(client, args).await,
        "dome_note" => dome_note(client, actor, args).await,
        "dome_schedule" => dome_schedule(client, actor, args).await,
        "dome_graph_query" => dome_graph_query(client, actor, args).await,
        "dome_context_resolve" => dome_context_resolve(client, actor, args).await,
        "dome_context_compact" => dome_context_compact(client, actor, args).await,
        "dome_agent_status" => dome_agent_status(client, args).await,
        other => Err(anyhow!("unknown tool: {}", other)),
    }
}

// ── dome_search ──────────────────────────────────────────────────

async fn dome_search(client: &RpcClient, actor: &Actor, args: Value) -> Result<Value> {
    let query = args
        .get("query")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("dome_search: missing required `query` (string)"))?;
    let limit = args
        .get("limit")
        .and_then(Value::as_i64)
        .unwrap_or(25)
        .clamp(1, 200);
    let scope = args
        .get("scope")
        .and_then(Value::as_str)
        .unwrap_or("all")
        .to_string();
    let topic = args.get("topic").cloned();
    let (knowledge_scope, project_id, _project_root, include_global) = scoped_defaults(&args);

    let mut body = json!({
        "q": query,
        "scope": scope.clone(),
        "limit": limit,
        "knowledge_scope": knowledge_scope,
        "include_global": include_global,
    });
    if let Some(project_id) = project_id {
        body["project_id"] = json!(project_id);
    }
    if let Some(topic) = topic {
        if !topic.is_null() {
            body["topic"] = topic;
        }
    }
    let event_knowledge_scope = body.get("knowledge_scope").cloned();
    let event_project_id = body.get("project_id").cloned();

    let result = client
        .call("search.query", body)
        .await
        .map_err(|e| anyhow!(e.to_string()))?;
    record_context_event(
        client,
        actor,
        "agent_used_context",
        "dome_search",
        json!({
            "query": query,
            "scope": scope,
            "topic": args.get("topic"),
            "knowledge_scope": event_knowledge_scope,
            "project_id": event_project_id,
        }),
    )
    .await;
    Ok(result)
}

// ── dome_read ────────────────────────────────────────────────────

async fn dome_read(client: &RpcClient, args: Value) -> Result<Value> {
    let id = args
        .get("note_id")
        .or_else(|| args.get("id"))
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("dome_read: missing required `note_id`"))?;

    client
        .call(
            "doc.get",
            json!({
                "id": id,
                "includeUser": true,
                "includeAgent": true,
                "includeMeta": true,
            }),
        )
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

// ── dome_note ────────────────────────────────────────────────────

async fn dome_note(client: &RpcClient, actor: &Actor, args: Value) -> Result<Value> {
    let text = args
        .get("text")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("dome_note: missing required `text`"))?
        .to_string();
    let scope = args
        .get("scope")
        .and_then(Value::as_str)
        .unwrap_or("agent")
        .to_string();

    // bt-core enforces the write barrier regardless; we still reject
    // scope=user early so the error is crisp.
    if scope == "user" {
        return Err(anyhow!(
            "dome_note: scope=\"user\" is not allowed for agents; use suggestion.create to propose a change to user.md"
        ));
    }
    if scope != "agent" {
        return Err(anyhow!(
            "dome_note: unknown scope `{}`; only `agent` is accepted",
            scope
        ));
    }

    // Resolve the target doc.
    //  - If caller passed `note_id` / `id`, use it.
    //  - Otherwise create a new inbox note with the given title (or
    //    auto-generated from the first line of `text`).
    let existing = args
        .get("note_id")
        .or_else(|| args.get("id"))
        .and_then(Value::as_str)
        .map(str::to_string);

    let doc_id = if let Some(id) = existing {
        id
    } else {
        let topic = args
            .get("topic")
            .and_then(Value::as_str)
            .unwrap_or("inbox")
            .to_string();
        let title = args
            .get("title")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| default_title_from(&text));

        let (knowledge_scope, project_id, project_root, _include_global) = scoped_defaults(&args);
        let owner_scope = if knowledge_scope == "global" || project_id.is_none() {
            "global"
        } else {
            "project"
        };
        let mut create_body = json!({
            "actor": actor,
            "topic": topic,
            "title": title,
            "owner_scope": owner_scope,
            "knowledge_kind": args
                .get("knowledge_kind")
                .or_else(|| args.get("knowledgeKind"))
                .or_else(|| args.get("kind"))
                .and_then(Value::as_str)
                .unwrap_or("knowledge"),
        });
        if let Some(project_id) = project_id {
            create_body["project_id"] = json!(project_id);
        }
        if let Some(project_root) = project_root {
            create_body["project_root"] = json!(project_root);
        }

        let created = client
            .call(
                "doc.create_scoped",
                create_body,
            )
            .await
            .map_err(|e| anyhow!(e.to_string()))?;
        created
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("doc.create returned no id"))?
            .to_string()
    };

    let mode = args
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("append")
        .to_string();
    let body_with_tags = match args.get("tags") {
        Some(Value::Array(tags)) if !tags.is_empty() => {
            let joined = tags
                .iter()
                .filter_map(|t| t.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            format!("{text}\n\n_tags: {joined}_\n")
        }
        _ => text,
    };

    let updated = client
        .call(
            "doc.update_agent",
            json!({
                "actor": actor,
                "id": doc_id,
                "content": body_with_tags,
                "mode": mode,
            }),
        )
        .await
        .map_err(|e| anyhow!(e.to_string()))?;

    Ok(json!({
        "note_id": doc_id,
        "updated": updated,
    }))
}

fn default_title_from(text: &str) -> String {
    let first_line = text
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("agent note")
        .trim();
    // Strip leading markdown heading markers so "# Onboarding" becomes
    // "Onboarding" as the doc title.
    let cleaned = first_line.trim_start_matches('#').trim();
    let mut chars: Vec<char> = cleaned.chars().collect();
    if chars.len() > 80 {
        chars.truncate(80);
    }
    chars.iter().collect()
}

// ── dome_schedule ────────────────────────────────────────────────

async fn dome_schedule(client: &RpcClient, actor: &Actor, args: Value) -> Result<Value> {
    let name = args
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("dome_schedule: missing required `name`"))?
        .to_string();
    let schedule_kind = args
        .get("schedule_kind")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            anyhow!("dome_schedule: missing required `schedule_kind` (one of once/cron/interval)")
        })?
        .to_string();
    let spec = args.get("spec").cloned().ok_or_else(|| {
        anyhow!("dome_schedule: missing required `spec` (object matching the chosen schedule_kind)")
    })?;
    let prompt = args
        .get("prompt")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("dome_schedule: missing required `prompt`"))?
        .to_string();
    let context_key = args
        .get("context_key")
        .and_then(Value::as_str)
        .map(str::to_string);
    let executor_kind = args
        .get("executor_kind")
        .and_then(Value::as_str)
        .unwrap_or("agent")
        .to_string();

    let schedule_json = serde_json::to_string(&spec)?;
    let mut body = json!({
        "actor": actor,
        "title": name,
        "executor_kind": executor_kind,
        "prompt_template": prompt,
        "schedule_kind": schedule_kind,
        "schedule_json": schedule_json,
        "enabled": true,
    });
    if let Some(ctx) = context_key {
        body["shared_context_key"] = json!(ctx);
    }

    client
        .call("automation.create", body)
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

// ── dome_graph_query ─────────────────────────────────────────────

async fn dome_graph_query(client: &RpcClient, actor: &Actor, args: Value) -> Result<Value> {
    let mut body = json!({});
    let (knowledge_scope, project_id, _project_root, include_global) = scoped_defaults(&args);
    body["knowledge_scope"] = json!(knowledge_scope);
    body["include_global"] = json!(include_global);
    if let Some(project_id) = project_id {
        body["project_id"] = json!(project_id);
    }
    for (from, to) in [
        ("focus_node_id", "focusNodeId"),
        ("focusNodeId", "focusNodeId"),
        ("search", "search"),
        ("from", "from"),
        ("to", "to"),
        ("max_nodes", "maxNodes"),
        ("maxNodes", "maxNodes"),
        ("include_types", "includeTypes"),
        ("includeTypes", "includeTypes"),
    ] {
        if let Some(value) = args.get(from) {
            body[to] = value.clone();
        }
    }
    let result = client
        .call("graph.snapshot", body)
        .await
        .map_err(|e| anyhow!(e.to_string()))?;
    let node_id = result
        .get("focus_node_id")
        .and_then(Value::as_str)
        .or_else(|| args.get("focus_node_id").and_then(Value::as_str))
        .or_else(|| args.get("focusNodeId").and_then(Value::as_str))
        .map(str::to_string);
    record_context_event_with_refs(
        client,
        actor,
        "agent_used_context",
        "dome_graph_query",
        None,
        node_id.as_deref(),
        json!({ "args": args, "visible_nodes": result.get("stats").and_then(|s| s.get("visible_nodes")) }),
    )
    .await;
    Ok(result)
}

// ── dome_context_resolve ─────────────────────────────────────────

async fn dome_context_resolve(client: &RpcClient, actor: &Actor, args: Value) -> Result<Value> {
    let brand = args
        .get("brand")
        .and_then(Value::as_str)
        .unwrap_or("claude_code");
    let mut body = json!({ "brand": brand });
    for key in ["session_id", "sessionId", "doc_id", "docId", "mode"] {
        if let Some(value) = args.get(key) {
            body[key] = value.clone();
        }
    }
    let result = client
        .call("context.resolve", body)
        .await
        .map_err(|e| anyhow!(e.to_string()))?;
    let context_id = result
        .get("context_pack")
        .and_then(|pack| pack.get("context_id"))
        .and_then(Value::as_str)
        .map(str::to_string);
    if result
        .get("resolved")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        record_context_event_with_refs(
            client,
            actor,
            "agent_used_context",
            "dome_context_resolve",
            context_id.as_deref(),
            None,
            json!({ "args": args }),
        )
        .await;
    }
    Ok(result)
}

// ── dome_context_compact ─────────────────────────────────────────

async fn dome_context_compact(client: &RpcClient, actor: &Actor, args: Value) -> Result<Value> {
    let brand = args
        .get("brand")
        .and_then(Value::as_str)
        .unwrap_or("claude_code");
    let mut body = json!({
        "actor": actor,
        "brand": brand,
        "force": args.get("force").and_then(Value::as_bool).unwrap_or(false),
    });
    for key in ["session_id", "sessionId", "doc_id", "docId"] {
        if let Some(value) = args.get(key) {
            body[key] = value.clone();
        }
    }
    let result = client
        .call("context.compact", body)
        .await
        .map_err(|e| anyhow!(e.to_string()))?;
    let context_id = result
        .get("context_pack")
        .and_then(|pack| pack.get("context_id"))
        .and_then(Value::as_str)
        .map(str::to_string);
    record_context_event_with_refs(
        client,
        actor,
        "agent_used_context",
        "dome_context_compact",
        context_id.as_deref(),
        None,
        json!({ "args": args }),
    )
    .await;
    Ok(result)
}

// ── dome_agent_status ────────────────────────────────────────────

async fn dome_agent_status(client: &RpcClient, args: Value) -> Result<Value> {
    let limit = args
        .get("limit")
        .and_then(Value::as_i64)
        .unwrap_or(50)
        .clamp(1, 200);
    let (knowledge_scope, project_id, _project_root, include_global) = scoped_defaults(&args);
    let mut body = json!({
        "limit": limit,
        "knowledge_scope": knowledge_scope,
        "include_global": include_global,
    });
    if let Some(project_id) = project_id {
        body["project_id"] = json!(project_id);
    }
    client
        .call("agent.status", body)
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

fn scoped_defaults(args: &Value) -> (String, Option<String>, Option<String>, bool) {
    let mut knowledge_scope = args
        .get("knowledge_scope")
        .or_else(|| args.get("knowledgeScope"))
        .and_then(Value::as_str)
        .unwrap_or("auto")
        .to_string();
    let project_id = args
        .get("project_id")
        .or_else(|| args.get("projectId"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| std::env::var("TADO_PROJECT_ID").ok())
        .filter(|value| !value.trim().is_empty());
    let project_root = args
        .get("project_root")
        .or_else(|| args.get("projectRoot"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| std::env::var("TADO_PROJECT_ROOT").ok())
        .filter(|value| !value.trim().is_empty());
    if knowledge_scope == "auto" {
        knowledge_scope = if project_id.is_some() {
            "merged".to_string()
        } else {
            "global".to_string()
        };
    }
    let include_global = args
        .get("include_global")
        .or_else(|| args.get("includeGlobal"))
        .and_then(Value::as_bool)
        .unwrap_or(knowledge_scope == "merged");
    (knowledge_scope, project_id, project_root, include_global)
}

async fn record_context_event(
    client: &RpcClient,
    actor: &Actor,
    event_kind: &str,
    reason: &str,
    payload: Value,
) {
    record_context_event_with_refs(client, actor, event_kind, reason, None, None, payload).await;
}

async fn record_context_event_with_refs(
    client: &RpcClient,
    actor: &Actor,
    event_kind: &str,
    reason: &str,
    context_id: Option<&str>,
    node_id: Option<&str>,
    payload: Value,
) {
    let mut body = json!({
        "actor": actor,
        "event_kind": event_kind,
        "reason": reason,
        "payload": payload,
    });
    if let Some(context_id) = context_id {
        body["context_id"] = json!(context_id);
    }
    if let Some(node_id) = node_id {
        body["node_id"] = json!(node_id);
    }
    if let Ok(project_id) = std::env::var("TADO_PROJECT_ID") {
        if !project_id.trim().is_empty() {
            body["project_id"] = json!(project_id);
        }
    }
    let _ = client.call("agent.context_event.record", body).await;
}

// ── Tool schemas (advertised via tools/list) ─────────────────────

fn tool_definitions() -> Vec<Value> {
    vec![
        tool(
            "dome_search",
            "Search Dome notes and knowledge. Returns ranked hits with snippets.",
            json!({
                "type": "object",
                "properties": {
                    "query":  { "type": "string",  "description": "Search query — natural language or keywords." },
                    "limit":  { "type": "integer", "description": "Max hits to return (1-200, default 25).", "minimum": 1, "maximum": 200 },
                    "scope":  { "type": "string",  "enum": ["user", "agent", "all"], "description": "Which note scope to search (default: all)." },
                    "topic":  { "type": "string",  "description": "Restrict to one topic slug." },
                    "knowledge_scope": { "type": "string", "enum": ["auto", "global", "project", "merged"], "description": "Knowledge ownership scope. Auto uses TADO_PROJECT_ID when present." },
                    "project_id": { "type": "string", "description": "Tado project id for project/merged knowledge scope." },
                    "include_global": { "type": "boolean", "description": "Include inherited global knowledge in project views." }
                },
                "required": ["query"]
            }),
        ),
        tool(
            "dome_read",
            "Fetch the full body + metadata of a Dome note by id.",
            json!({
                "type": "object",
                "properties": {
                    "note_id": { "type": "string", "description": "Doc id returned by dome_search." }
                },
                "required": ["note_id"]
            }),
        ),
        tool(
            "dome_note",
            "Append an agent note. If note_id is provided, appends to that doc; otherwise creates a new note in the `inbox` topic. Scope is always `agent` — propose user-note changes via suggestion.create.",
            json!({
                "type": "object",
                "properties": {
                    "text":    { "type": "string", "description": "Note body (markdown)." },
                    "note_id": { "type": "string", "description": "Existing doc id to append to (optional)." },
                    "topic":   { "type": "string", "description": "Topic slug for a new doc (default: inbox)." },
                    "title":   { "type": "string", "description": "Title for a new doc (default: first non-blank line of text)." },
                    "tags":    { "type": "array",  "items": { "type": "string" }, "description": "Optional tag list appended as `_tags: a, b_` footer." },
                    "scope":   { "type": "string", "enum": ["agent"], "description": "Must be `agent`; present for symmetry with dome_search." },
                    "mode":    { "type": "string", "enum": ["append", "replace"], "description": "Write mode (default: append)." },
                    "knowledge_scope": { "type": "string", "enum": ["auto", "global", "project", "merged"], "description": "New notes default to project scope when TADO_PROJECT_ID is present." },
                    "project_id": { "type": "string", "description": "Tado project id for project notes." },
                    "project_root": { "type": "string", "description": "Project root path for provenance." },
                    "knowledge_kind": { "type": "string", "enum": ["knowledge", "workflow", "decision", "system"], "description": "Typed knowledge category." }
                },
                "required": ["text"]
            }),
        ),
        tool(
            "dome_schedule",
            "Create a calendar automation. Use when you need a follow-up or a recurring task.",
            json!({
                "type": "object",
                "properties": {
                    "name":          { "type": "string", "description": "Human-readable title shown in the calendar." },
                    "schedule_kind": { "type": "string", "enum": ["once", "cron", "interval", "manual", "heartbeat"] },
                    "spec":          { "type": "object", "description": "Schedule parameters. For `once`: `{ at: <iso8601> }`. For `cron`: `{ expression: <cron> }`. For `interval`: `{ seconds: <n> }`." },
                    "prompt":        { "type": "string", "description": "Prompt template passed to the executor when the automation fires." },
                    "context_key":   { "type": "string", "description": "Shared-context key so successive runs can hand off state." },
                    "executor_kind": { "type": "string", "enum": ["agent", "command_local"], "description": "Who runs the job (default: agent)." }
                },
                "required": ["name", "schedule_kind", "spec", "prompt"]
            }),
        ),
        tool(
            "dome_graph_query",
            "Query Dome's typed knowledge graph. Use before architecture decisions, unfamiliar edits, team joins, and completion claims.",
            json!({
                "type": "object",
                "properties": {
                    "search":        { "type": "string", "description": "Optional text search over graph labels and payloads." },
                    "focus_node_id": { "type": "string", "description": "Optional graph node id to inspect with its neighborhood." },
                    "include_types": { "type": "array", "items": { "type": "string" }, "description": "Node kinds to include, e.g. doc, task, run, context_pack, agent." },
                    "max_nodes":     { "type": "integer", "minimum": 50, "maximum": 1000, "description": "Maximum nodes returned." },
                    "knowledge_scope": { "type": "string", "enum": ["auto", "global", "project", "merged"], "description": "Knowledge ownership scope." },
                    "project_id": { "type": "string", "description": "Tado project id for project/merged graph views." },
                    "include_global": { "type": "boolean", "description": "Include inherited global graph nodes in project views." }
                }
            }),
        ),
        tool(
            "dome_context_resolve",
            "Resolve the current compact context pack and cited source list for a Claude/Codex session or doc.",
            json!({
                "type": "object",
                "properties": {
                    "brand":      { "type": "string", "description": "Runtime brand, default claude_code." },
                    "session_id": { "type": "string", "description": "Agent/session id to resolve." },
                    "doc_id":     { "type": "string", "description": "Dome doc id to resolve." },
                    "mode":       { "type": "string", "description": "Resolution mode label, default compact." }
                }
            }),
        ),
        tool(
            "dome_context_compact",
            "Create or refresh a compact cited context pack for a session or doc. Use when context is stale or before handing work to another agent.",
            json!({
                "type": "object",
                "properties": {
                    "brand":      { "type": "string", "description": "Runtime brand, default claude_code." },
                    "session_id": { "type": "string", "description": "Agent/session id to compact." },
                    "doc_id":     { "type": "string", "description": "Dome doc id to compact." },
                    "force":      { "type": "boolean", "description": "Force a new pack even if sources are unchanged." }
                }
            }),
        ),
        tool(
            "dome_agent_status",
            "Read Tado's Claude-agent operations feed: context-window status, recent context packs, retrieval events, and stale-context signals.",
            json!({
                "type": "object",
                "properties": {
                    "limit": { "type": "integer", "minimum": 1, "maximum": 200, "description": "Maximum status/context rows." },
                    "knowledge_scope": { "type": "string", "enum": ["auto", "global", "project", "merged"], "description": "Knowledge ownership scope." },
                    "project_id": { "type": "string", "description": "Tado project id for project status views." },
                    "include_global": { "type": "boolean", "description": "Include inherited global status/events in project views." }
                }
            }),
        ),
    ]
}

fn tool(name: &str, description: &str, input_schema: Value) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": input_schema
    })
}

// ── Helpers ──────────────────────────────────────────────────────

fn json_rpc_error(id: Value, code: &str, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message }
    })
}

fn parse_args() -> Result<(String, String)> {
    let mut vault = None;
    let mut token = None;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--vault" => {
                vault = args.next();
            }
            "--token" => {
                token = args.next();
            }
            _ => {}
        }
    }

    let vault = vault.ok_or_else(|| anyhow!("usage: bt-mcp --vault <path> --token <raw_token>"))?;
    let token = token
        .or_else(|| std::env::var("BT_AGENT_TOKEN").ok())
        .ok_or_else(|| anyhow!("missing --token and BT_AGENT_TOKEN"))?;

    Ok((vault, token))
}

fn socket_for(vault_path: &str) -> Result<PathBuf> {
    let canonical = std::fs::canonicalize(vault_path)?;
    Ok(canonical.join(".bt/bt-core.sock"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_title_strips_leading_hashes() {
        assert_eq!(default_title_from("# Onboarding\nbody"), "Onboarding");
        assert_eq!(default_title_from("## Deep\nbody"), "Deep");
    }

    #[test]
    fn default_title_skips_blank_lines() {
        assert_eq!(default_title_from("\n\nSomething\nrest"), "Something");
    }

    #[test]
    fn default_title_caps_at_80_chars() {
        let long = "x".repeat(200);
        let title = default_title_from(&long);
        assert_eq!(title.chars().count(), 80);
    }

    #[test]
    fn tool_definitions_expose_four_tools() {
        let tools = tool_definitions();
        assert_eq!(tools.len(), 8);
        let names: Vec<&str> = tools
            .iter()
            .map(|t| t.get("name").and_then(Value::as_str).unwrap())
            .collect();
        assert!(names.contains(&"dome_search"));
        assert!(names.contains(&"dome_read"));
        assert!(names.contains(&"dome_note"));
        assert!(names.contains(&"dome_schedule"));
        assert!(names.contains(&"dome_graph_query"));
        assert!(names.contains(&"dome_context_resolve"));
        assert!(names.contains(&"dome_context_compact"));
        assert!(names.contains(&"dome_agent_status"));
    }
}
