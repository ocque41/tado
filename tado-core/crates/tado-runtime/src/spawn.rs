use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Engine {
    Raw,
    Shell,
    Codex,
}

impl Default for Engine {
    fn default() -> Self {
        Self::Shell
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpawnRequest {
    #[serde(default)]
    pub engine: Engine,
    pub prompt: Option<String>,
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    pub title: Option<String>,
    pub cwd: Option<String>,
    pub project_id: Option<String>,
    pub project_root: Option<String>,
    #[serde(default)]
    pub env: Vec<(String, String)>,
    #[serde(default)]
    pub flags: Vec<String>,
    pub agent_name: Option<String>,
    pub team_name: Option<String>,
    #[serde(default = "default_cols")]
    pub cols: u16,
    #[serde(default = "default_rows")]
    pub rows: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SpawnPlan {
    pub engine: Engine,
    pub title: String,
    pub executable: String,
    pub args: Vec<String>,
    pub cwd: Option<String>,
    pub project_id: Option<String>,
    pub project_root: Option<String>,
    pub agent_name: Option<String>,
    pub team_name: Option<String>,
    pub env: Vec<(String, String)>,
    pub cols: u16,
    pub rows: u16,
}

pub fn plan_spawn(request: SpawnRequest) -> Result<SpawnPlan> {
    let cols = request.cols.clamp(20, 400);
    let rows = request.rows.clamp(5, 120);
    let cwd = request.cwd.or_else(|| request.project_root.clone());
    let prompt = request.prompt.unwrap_or_default();
    let title = request
        .title
        .clone()
        .or_else(|| title_from_prompt(&prompt))
        .or_else(|| request.command.clone())
        .unwrap_or_else(|| "Tado session".to_string());

    let (executable, args) = match request.engine {
        Engine::Raw => {
            let cmd = request
                .command
                .clone()
                .ok_or_else(|| anyhow!("raw spawn requires command"))?;
            (cmd, request.args.clone())
        }
        Engine::Shell => {
            let command = request.command.clone().unwrap_or_else(|| prompt.clone());
            if command.trim().is_empty() {
                return Err(anyhow!("shell spawn requires command or prompt"));
            }
            (
                "/bin/zsh".to_string(),
                vec!["-l".into(), "-c".into(), command],
            )
        }
        Engine::Codex => {
            if prompt.trim().is_empty() {
                return Err(anyhow!("codex spawn requires prompt"));
            }
            let mut parts = vec!["codex".to_string()];
            parts.extend(
                sanitize_flags(request.flags)
                    .into_iter()
                    .map(|f| shell_escape(&f)),
            );
            parts.push(shell_escape(&prompt));
            (
                "/bin/zsh".to_string(),
                vec!["-l".into(), "-c".into(), parts.join(" ")],
            )
        }
    };

    Ok(SpawnPlan {
        engine: request.engine,
        title,
        executable,
        args,
        cwd,
        project_id: request.project_id,
        project_root: request.project_root,
        agent_name: request.agent_name,
        team_name: request.team_name,
        env: request.env,
        cols,
        rows,
    })
}

pub fn shell_escape(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

pub fn sanitize_flags(flags: Vec<String>) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < flags.len() {
        let token = &flags[i];
        if token.starts_with("--") && i + 1 < flags.len() && flags[i + 1] == "auto" {
            i += 2;
            continue;
        }
        if token == "-c" && i + 1 < flags.len() {
            let payload = &flags[i + 1];
            if payload.ends_with("=\"auto\"") || payload.ends_with("=auto") {
                i += 2;
                continue;
            }
        }
        out.push(token.clone());
        i += 1;
    }
    out
}

fn title_from_prompt(prompt: &str) -> Option<String> {
    let trimmed = prompt.trim();
    if trimmed.is_empty() {
        return None;
    }
    let mut title = trimmed.lines().next().unwrap_or(trimmed).trim().to_string();
    if title.len() > 80 {
        title.truncate(77);
        title.push_str("...");
    }
    Some(title)
}

fn default_cols() -> u16 {
    120
}

fn default_rows() -> u16 {
    36
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_escape_handles_single_quotes() {
        assert_eq!(shell_escape("it's ok"), "'it'\\''s ok'");
    }

    #[test]
    fn sanitize_flags_drops_auto_sentinel_pairs() {
        assert_eq!(
            sanitize_flags(vec![
                "--model".into(),
                "auto".into(),
                "--effort".into(),
                "high".into(),
                "-c".into(),
                "model_reasoning_effort=\"auto\"".into(),
            ]),
            vec!["--effort".to_string(), "high".to_string()]
        );
    }

    #[test]
    fn codex_plan_shell_escapes_flags_and_prompt() {
        let plan = plan_spawn(SpawnRequest {
            engine: Engine::Codex,
            prompt: Some("hello 'world'".into()),
            command: None,
            args: Vec::new(),
            title: None,
            cwd: None,
            project_id: None,
            project_root: None,
            env: Vec::new(),
            flags: vec!["--model".into(), "opus[1m]".into()],
            agent_name: Some("reviewer".into()),
            team_name: None,
            cols: 120,
            rows: 36,
        })
        .unwrap();
        assert_eq!(plan.executable, "/bin/zsh");
        assert!(plan.args[2].contains("'opus[1m]'"));
        assert!(plan.args[2].contains("'hello '\\''world'\\'''"));
    }
}
