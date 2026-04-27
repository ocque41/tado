use anyhow::{anyhow, Result};
use bt_core::{rpc::RpcClient, Actor};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;

#[tokio::main]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("tado-dome: {err}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let mut args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.is_empty() || matches!(args[0].as_str(), "-h" | "--help" | "help") {
        print_help();
        return Ok(());
    }

    let cmd = args.remove(0);
    let client = RpcClient::new(socket_path()?);
    match cmd.as_str() {
        "register" => print_json(register(&client, parse_flags(args)?).await?),
        "search" => print_json(search(&client, args).await?),
        "graph" => print_json(graph(&client, parse_flags(args)?).await?),
        "code-register" => print_json(code_register(&client, parse_flags(args)?).await?),
        "code-unregister" => print_json(code_unregister(&client, parse_flags(args)?).await?),
        "code-list" => {
            let flags = parse_flags(args)?;
            let value = client
                .call("code.list_projects", json!({}))
                .await
                .map_err(|e| anyhow!(e.to_string()))?;
            if flags.contains_key("toon") {
                print_code_list_toon(&value);
                Ok(())
            } else {
                print_json(value)
            }
        }
        "index" => print_json(code_index(&client, parse_flags(args)?).await?),
        "index-status" => print_json(code_index_status(&client, parse_flags(args)?).await?),
        "code-search" => code_search_dispatch(&client, args).await,
        "watch" => print_json(code_watch_start(&client, parse_flags(args)?).await?),
        "unwatch" => print_json(code_watch_stop(&client, parse_flags(args)?).await?),
        "watch-list" => watch_list_dispatch(&client, parse_flags(args)?).await,
        "wait-for-index" => wait_for_index(&client, parse_flags(args)?).await,
        other => Err(anyhow!("unknown command `{other}`; run `tado-dome help`")),
    }
}

async fn code_register(client: &RpcClient, flags: HashMap<String, String>) -> Result<Value> {
    let project_id = required(&flags, "project")?;
    let name = flags
        .get("name")
        .cloned()
        .unwrap_or_else(|| project_id.clone());
    let root_path = flags
        .get("root")
        .cloned()
        .or_else(|| std::env::var("TADO_PROJECT_ROOT").ok())
        .ok_or_else(|| anyhow!("--root <path> is required (or set TADO_PROJECT_ROOT)"))?;
    let enabled = flags
        .get("disabled")
        .map(|_| false)
        .unwrap_or(true);
    client
        .call(
            "code.project.register",
            json!({
                "project_id": project_id,
                "name": name,
                "root_path": root_path,
                "enabled": enabled,
            }),
        )
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

async fn code_unregister(client: &RpcClient, flags: HashMap<String, String>) -> Result<Value> {
    let project_id = required(&flags, "project")?;
    let purge = !flags.contains_key("keep");
    client
        .call(
            "code.project.unregister",
            json!({ "project_id": project_id, "purge": purge }),
        )
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

async fn code_index(client: &RpcClient, flags: HashMap<String, String>) -> Result<Value> {
    let project_id = required(&flags, "project")?;
    let full_rebuild = flags.contains_key("full");

    // Auto-register if `--root` is supplied and the project isn't
    // registered yet — saves the user the two-step.
    if let Some(root) = flags.get("root").cloned() {
        let _ = client
            .call(
                "code.project.register",
                json!({
                    "project_id": project_id,
                    "name": flags
                        .get("name")
                        .cloned()
                        .unwrap_or_else(|| project_id.clone()),
                    "root_path": root,
                    "enabled": true,
                }),
            )
            .await;
    }

    client
        .call(
            "code.index_project",
            json!({ "project_id": project_id, "full_rebuild": full_rebuild }),
        )
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

async fn code_index_status(client: &RpcClient, flags: HashMap<String, String>) -> Result<Value> {
    let project_id = required(&flags, "project")?;
    client
        .call("code.index_status", json!({ "project_id": project_id }))
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

async fn code_watch_start(client: &RpcClient, flags: HashMap<String, String>) -> Result<Value> {
    let project_id = required(&flags, "project")?;
    client
        .call("code.watch.start", json!({ "project_id": project_id }))
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

async fn code_watch_stop(client: &RpcClient, flags: HashMap<String, String>) -> Result<Value> {
    let project_id = required(&flags, "project")?;
    client
        .call("code.watch.stop", json!({ "project_id": project_id }))
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

/// `tado-dome wait-for-index --project <id> [--timeout 600]`.
/// Polls `code.index_status` every 1 s until `running == false` or
/// the timeout fires. Useful for shell scripting: kick off an index
/// from one terminal, wait for it from CI / another agent, then
/// query.
///
/// Exit codes:
///   0 — index completed successfully (running=false, no error)
///   1 — timed out
///   2 — index reported an error
async fn wait_for_index(client: &RpcClient, flags: HashMap<String, String>) -> Result<()> {
    let project_id = required(&flags, "project")?;
    let timeout = flags
        .get("timeout")
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(900); // 15 min default — covers a full Tado-size rebuild
    let toon = flags.contains_key("toon");
    let started = std::time::Instant::now();
    loop {
        let status = client
            .call("code.index_status", json!({ "project_id": project_id }))
            .await
            .map_err(|e| anyhow!(e.to_string()))?;
        let running = status.get("running").and_then(Value::as_bool).unwrap_or(false);
        let err: Option<String> = status
            .get("error")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let files_done = status.get("files_done").and_then(Value::as_i64).unwrap_or(0);
        let files_total = status.get("files_total").and_then(Value::as_i64).unwrap_or(0);
        let chunks_done = status.get("chunks_done").and_then(Value::as_i64).unwrap_or(0);

        if !running {
            if toon {
                let final_state = if err.is_some() { "error" } else { "ok" };
                let err_str = err.as_deref().unwrap_or("-").replace(' ', "_");
                println!("{project_id} {final_state} {files_done} {chunks_done} {err_str}");
            } else {
                print_json(status)?;
            }
            if err.is_some() {
                std::process::exit(2);
            }
            return Ok(());
        }
        if started.elapsed().as_secs() > timeout {
            if toon {
                println!("{project_id} timeout {files_done} {chunks_done} -");
            } else {
                eprintln!(
                    "tado-dome wait-for-index: timed out after {timeout}s ({files_done}/{files_total} files, {chunks_done} chunks)"
                );
            }
            std::process::exit(1);
        }
        if !toon {
            eprint!(
                "\rwaiting: {files_done}/{files_total} files · {chunks_done} chunks"
            );
            use std::io::Write as _;
            std::io::stderr().flush().ok();
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
}

/// `tado-dome watch-list [--toon]`. AXI mode prints one project_id
/// per line — the simplest possible record. Silent on empty.
async fn watch_list_dispatch(client: &RpcClient, flags: HashMap<String, String>) -> Result<()> {
    let toon = flags.contains_key("toon");
    let value = client
        .call("code.watch.list", json!({}))
        .await
        .map_err(|e| anyhow!(e.to_string()))?;
    if toon {
        if let Some(arr) = value.get("watching").and_then(Value::as_array) {
            for v in arr {
                if let Some(s) = v.as_str() {
                    println!("{s}");
                }
            }
        }
        Ok(())
    } else {
        print_json(value)
    }
}

/// `tado-dome code-search "query" [--project <id>]... [--language rust]...
///                                 [--limit N] [--alpha 0.6] [--toon]`
///
/// Honors the AXI `--toon` convention used elsewhere in the Tado
/// CLI surface (`tado-list --toon`): one record per line, space-
/// separated, `-` for nulls, spaces in fields → `_`, variable-length
/// excerpt last. Silent on empty results so agents can detect zero
/// hits via stdout / exit.
async fn code_search_dispatch(client: &RpcClient, args: Vec<String>) -> Result<()> {
    let (query, flags) = split_query_and_flags(args)?;
    let toon = flags.contains_key("toon");
    let limit = flags
        .get("limit")
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(25)
        .clamp(1, 200);
    let alpha = flags.get("alpha").and_then(|v| v.parse::<f64>().ok());
    let project_ids: Vec<String> = flags
        .get("project")
        .map(|v| v.split(',').map(|s| s.trim().to_string()).collect())
        .unwrap_or_default();
    let languages: Vec<String> = flags
        .get("language")
        .map(|v| v.split(',').map(|s| s.trim().to_string()).collect())
        .unwrap_or_default();

    let mut body = json!({ "query": query, "limit": limit });
    if !project_ids.is_empty() {
        body["project_ids"] = json!(project_ids);
    }
    if !languages.is_empty() {
        body["languages"] = json!(languages);
    }
    if let Some(a) = alpha {
        body["alpha"] = json!(a);
    }

    let result = client
        .call("code.search", body)
        .await
        .map_err(|e| anyhow!(e.to_string()))?;

    if toon {
        print_code_search_toon(&result);
    } else {
        print_json(result)?;
    }
    Ok(())
}

/// AXI compact form. Order: project repo_path lang start_line end_line
/// vector lexical combined node_kind qualified_name excerpt.
/// Excerpt goes last because it's the most variable-length field;
/// trailing space is fine for `awk` / `cut -d ' '` consumers.
fn print_code_search_toon(result: &Value) {
    let Some(arr) = result.get("results").and_then(Value::as_array) else {
        return;
    };
    if arr.is_empty() {
        return;
    }
    for hit in arr {
        let project = toon_field(hit.get("project_id"));
        let repo = toon_field(hit.get("repo_path"));
        let lang = toon_field(hit.get("language"));
        let start = toon_int(hit.get("start_line"));
        let end = toon_int(hit.get("end_line"));
        let v = toon_score(hit.get("vector_score"));
        let l = toon_score(hit.get("lexical_score"));
        let combined = toon_score(hit.get("combined_score"));
        let node_kind = toon_field(hit.get("node_kind"));
        let qualified = toon_field(hit.get("qualified_name"));
        let excerpt = toon_excerpt(hit.get("excerpt"));
        println!(
            "{project} {repo} {lang} {start} {end} {v} {l} {combined} {node_kind} {qualified} {excerpt}"
        );
    }
}

/// AXI compact form for `code-list --toon`. Order: project enabled
/// files chunks model root.
fn print_code_list_toon(result: &Value) {
    let Some(arr) = result.get("projects").and_then(Value::as_array) else {
        return;
    };
    if arr.is_empty() {
        return;
    }
    for proj in arr {
        let project = toon_field(proj.get("project_id"));
        let enabled = match proj.get("enabled").and_then(Value::as_bool) {
            Some(true) => "1",
            Some(false) => "0",
            None => "-",
        };
        let files = toon_int(proj.get("file_count"));
        let chunks = toon_int(proj.get("chunk_count"));
        let model = toon_field(proj.get("embedding_model_version"));
        let root = toon_field(proj.get("root_path"));
        println!("{project} {enabled} {files} {chunks} {model} {root}");
    }
}

fn toon_field(v: Option<&Value>) -> String {
    match v.and_then(Value::as_str) {
        Some(s) if !s.is_empty() => s.replace(' ', "_"),
        _ => "-".to_string(),
    }
}

fn toon_int(v: Option<&Value>) -> String {
    match v.and_then(Value::as_i64) {
        Some(n) => n.to_string(),
        None => "-".to_string(),
    }
}

fn toon_score(v: Option<&Value>) -> String {
    match v.and_then(Value::as_f64) {
        Some(f) => format!("{f:.4}"),
        None => "-".to_string(),
    }
}

/// Excerpt is the variable-length tail. Replace internal whitespace
/// runs with single spaces, then drop spaces (so `cut -d ' '` keeps
/// the rest of the line as one field).
fn toon_excerpt(v: Option<&Value>) -> String {
    let raw = v.and_then(Value::as_str).unwrap_or("");
    if raw.is_empty() {
        return "-".to_string();
    }
    let collapsed: String = raw.split_whitespace().collect::<Vec<_>>().join("_");
    if collapsed.is_empty() {
        "-".to_string()
    } else {
        collapsed
    }
}

async fn register(client: &RpcClient, flags: HashMap<String, String>) -> Result<Value> {
    let title = required(&flags, "title")?;
    let body = required(&flags, "body")?;
    let scope = flags.get("scope").map(String::as_str).unwrap_or("global");
    let kind = flags.get("kind").map(String::as_str).unwrap_or("knowledge");
    let project_id = project_id_for(scope, &flags)?;
    let project_root = flags
        .get("project-root")
        .cloned()
        .or_else(|| std::env::var("TADO_PROJECT_ROOT").ok());
    let topic = flags
        .get("topic")
        .cloned()
        .unwrap_or_else(|| default_topic(scope, project_id.as_deref()));

    let mut body_json = json!({
        "actor": Actor::CliUser,
        "title": title,
        "body": body,
        "scope": scope,
        "topic": topic,
        "kind": kind,
        "note_scope": "user",
    });
    if let Some(project_id) = project_id {
        body_json["project_id"] = json!(project_id);
    }
    if let Some(project_root) = project_root {
        body_json["project_root"] = json!(project_root);
    }

    client
        .call("knowledge.register", body_json)
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

async fn search(client: &RpcClient, args: Vec<String>) -> Result<Value> {
    let (query, flags) = split_query_and_flags(args)?;
    let scope = flags.get("scope").map(String::as_str).unwrap_or("merged");
    let limit = flags
        .get("limit")
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(25)
        .clamp(1, 200);
    let project_id = project_id_for(scope, &flags)?;
    let mut body = json!({
        "q": query,
        "scope": "all",
        "limit": limit,
        "knowledge_scope": scope,
        "include_global": scope == "merged",
    });
    if let Some(project_id) = project_id {
        body["project_id"] = json!(project_id);
    }
    client
        .call("search.query", body)
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

async fn graph(client: &RpcClient, flags: HashMap<String, String>) -> Result<Value> {
    let scope = flags.get("scope").map(String::as_str).unwrap_or("merged");
    let project_id = project_id_for(scope, &flags)?;
    let mut body = json!({
        "knowledge_scope": scope,
        "include_global": scope == "merged",
        "maxNodes": flags
            .get("max-nodes")
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(400),
    });
    if let Some(search) = flags.get("search") {
        body["search"] = json!(search);
    }
    if let Some(project_id) = project_id {
        body["project_id"] = json!(project_id);
    }
    client
        .call("graph.snapshot", body)
        .await
        .map_err(|e| anyhow!(e.to_string()))
}

fn socket_path() -> Result<PathBuf> {
    let vault = if let Ok(path) = std::env::var("TADO_DOME_VAULT") {
        PathBuf::from(path)
    } else {
        tado_settings::SettingsPaths::macos_default()
            .ok_or_else(|| anyhow!("could not resolve Dome vault path"))?
            .app_support
            .join("dome")
    };
    Ok(vault.join(".bt").join("bt-core.sock"))
}

fn parse_flags(args: Vec<String>) -> Result<HashMap<String, String>> {
    let mut out = HashMap::new();
    let mut i = 0;
    while i < args.len() {
        let key = args[i].strip_prefix("--").ok_or_else(|| {
            anyhow!("expected flag like --title, got `{}`", args[i])
        })?;
        let value = args
            .get(i + 1)
            .ok_or_else(|| anyhow!("missing value for --{key}"))?;
        out.insert(key.to_string(), value.clone());
        i += 2;
    }
    Ok(out)
}

fn split_query_and_flags(args: Vec<String>) -> Result<(String, HashMap<String, String>)> {
    let query = args
        .first()
        .filter(|value| !value.starts_with("--"))
        .cloned()
        .ok_or_else(|| anyhow!("search requires a query string"))?;
    let flags = parse_flags(args.into_iter().skip(1).collect())?;
    Ok((query, flags))
}

fn required(flags: &HashMap<String, String>, key: &str) -> Result<String> {
    flags
        .get(key)
        .cloned()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("register requires --{key}"))
}

fn project_id_for(scope: &str, flags: &HashMap<String, String>) -> Result<Option<String>> {
    if scope == "global" {
        return Ok(None);
    }
    let project_id = flags
        .get("project-id")
        .cloned()
        .or_else(|| flags.get("project_id").cloned())
        .or_else(|| std::env::var("TADO_PROJECT_ID").ok())
        .filter(|value| !value.trim().is_empty());
    if matches!(scope, "project" | "merged") && project_id.is_none() {
        return Err(anyhow!(
            "--project-id or TADO_PROJECT_ID is required for `{scope}` scope"
        ));
    }
    Ok(project_id)
}

fn default_topic(scope: &str, project_id: Option<&str>) -> String {
    match (scope, project_id) {
        ("project", Some(id)) | ("merged", Some(id)) => {
            format!("project-{}", id.chars().take(8).collect::<String>().to_lowercase())
        }
        _ => "global".to_string(),
    }
}

fn print_json(value: Value) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

fn print_help() {
    println!(
        r#"tado-dome — scoped Dome knowledge CLI

Notes:
  tado-dome register --scope global|project --kind knowledge|workflow|decision --title "..." --body "..."
  tado-dome search "query" --scope global|project|merged
  tado-dome graph --scope global|project|merged [--search "query"]

Code indexing:
  tado-dome code-register --project <id> --root <path> [--name <name>]
  tado-dome code-unregister --project <id> [--keep]
  tado-dome code-list                      [--toon]
  tado-dome index --project <id> [--root <path>] [--full]
  tado-dome index-status --project <id>

Code search (Phase 3 — hybrid vec + lexical over indexed chunks):
  tado-dome code-search "query" [--project <id>] [--language rust,swift]
                                [--limit N] [--alpha 0.6] [--toon]

File-watch incremental (Phase 4):
  tado-dome watch --project <id>
  tado-dome unwatch --project <id>
  tado-dome watch-list [--toon]
  tado-dome wait-for-index --project <id> [--timeout 900] [--toon]
                              # exit 0 on completion, 1 on timeout, 2 on error

`tado-dome index --root <path>` auto-registers if the project doesn't exist yet.
Project scope defaults from TADO_PROJECT_ID and TADO_PROJECT_ROOT when present.

`--toon` (AXI mode): one record per line, space-separated, `-` for null,
spaces replaced with `_`. Silent on empty so agents detect zero hits via
stdout/exit. Column order documented in source comments.
"#
    );
}
