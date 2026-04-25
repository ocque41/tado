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
        other => Err(anyhow!("unknown command `{other}`; run `tado-dome help`")),
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

Usage:
  tado-dome register --scope global|project --kind knowledge|workflow|decision --title "..." --body "..."
  tado-dome search "query" --scope global|project|merged
  tado-dome graph --scope global|project|merged [--search "query"]

Project scope defaults from TADO_PROJECT_ID and TADO_PROJECT_ROOT when present.
"#
    );
}
