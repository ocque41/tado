use anyhow::{anyhow, Result};

pub fn normalize_session_engine(engine: Option<String>) -> Result<String> {
    let value = engine.unwrap_or_else(|| "codex".to_string());
    match value.trim().to_ascii_lowercase().as_str() {
        "codex" => Ok("codex".to_string()),
        "shell" => Ok("shell".to_string()),
        "raw" => Ok("raw".to_string()),
        "claude" | "cowork" => Err(anyhow!(
            "unsupported AI provider {value:?}; terminal Agent OS supports codex"
        )),
        other => Err(anyhow!(
            "unknown session kind {other:?}; expected codex, shell, or raw"
        )),
    }
}

pub fn normalize_workflow_engine(engine: &str) -> Result<&'static str> {
    match engine.trim().to_ascii_lowercase().as_str() {
        "" | "codex" => Ok("codex"),
        "claude" | "cowork" => Err(anyhow!(
            "unsupported AI provider {engine:?}; terminal Agent OS supports codex"
        )),
        "shell" | "raw" => Err(anyhow!(
            "{engine:?} is a terminal utility session kind, not a workflow AI provider"
        )),
        other => Err(anyhow!(
            "unknown workflow engine {other:?}; terminal Agent OS supports codex"
        )),
    }
}
