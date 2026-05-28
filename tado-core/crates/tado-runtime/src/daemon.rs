use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;

use anyhow::{anyhow, Context, Result};
use chrono::Utc;
use serde::Deserialize;
use serde_json::{json, Value};
use tado_core::Session;
use tokio::io::AsyncWriteExt;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::watch;
use tokio::time::{sleep, Duration};
use tracing::{error, info};
use uuid::Uuid;

use crate::db::{RuntimeDb, SessionRecord, WorkflowRecord};
use crate::profile::{remove_stale_socket, ProfilePaths};
use crate::protocol::{
    read_json_frame_async, write_json_frame_async, RuntimeRequest, RuntimeResponse,
    PROTOCOL_VERSION,
};
use crate::spawn::{plan_spawn, Engine, SpawnRequest};

#[derive(Debug, Clone)]
pub struct DaemonOptions {
    pub profile: String,
}

pub async fn run_daemon(options: DaemonOptions) -> Result<()> {
    let paths = ProfilePaths::resolve(&options.profile)?;
    paths.create_dirs()?;
    remove_stale_socket(&paths.socket_path)?;
    let state = Arc::new(RuntimeState::open(paths.clone())?);
    let listener = UnixListener::bind(&paths.socket_path)
        .with_context(|| format!("bind runtime socket {}", paths.socket_path.display()))?;
    info!(
        profile = %paths.profile,
        socket = %paths.socket_path.display(),
        db = %paths.db_path.display(),
        "tadod listening"
    );

    let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
    let _ = *shutdown_rx.borrow_and_update();

    loop {
        tokio::select! {
            biased;
            _ = shutdown_rx.changed() => {
                break;
            }
            signal = tokio::signal::ctrl_c() => {
                if let Err(err) = signal {
                    error!(?err, "ctrl-c signal listener failed");
                }
                break;
            }
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                let state = state.clone();
                let shutdown = shutdown_tx.clone();
                tokio::spawn(async move {
                    if let Err(err) = handle_client(stream, state, shutdown).await {
                        error!(?err, "runtime client failed");
                    }
                });
            }
        }
    }

    state.shutdown_live_sessions();
    state.append_event("daemon.shutdown", None, "runtime daemon stopped", None);
    let _ = std::fs::remove_file(&paths.socket_path);
    Ok(())
}

async fn handle_client(
    mut stream: UnixStream,
    state: Arc<RuntimeState>,
    shutdown: watch::Sender<bool>,
) -> Result<()> {
    let request: RuntimeRequest = read_json_frame_async(&mut stream).await?;
    if request.kind == "events.stream" {
        state.stream_events(stream, request).await?;
        return Ok(());
    }
    let response = state.handle_request(request, shutdown);
    write_json_frame_async(&mut stream, &response).await?;
    Ok(())
}

struct RuntimeState {
    paths: ProfilePaths,
    runtime_id: String,
    db: Mutex<RuntimeDb>,
    sessions: Arc<Mutex<HashMap<String, LiveSession>>>,
    advisor_links: Arc<Mutex<HashMap<String, AdvisorLink>>>,
}

#[derive(Clone)]
struct LiveSession {
    session: Arc<Session>,
}

#[derive(Debug, Clone)]
struct AdvisorLink {
    advisor_id: String,
    last_message: String,
}

impl RuntimeState {
    fn open(paths: ProfilePaths) -> Result<Self> {
        let db = RuntimeDb::open(&paths.db_path)?;
        let runtime_id = db.runtime_id()?;
        Ok(Self {
            paths,
            runtime_id,
            db: Mutex::new(db),
            sessions: Arc::new(Mutex::new(HashMap::new())),
            advisor_links: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    fn handle_request(
        &self,
        request: RuntimeRequest,
        shutdown: watch::Sender<bool>,
    ) -> RuntimeResponse {
        if request.version != PROTOCOL_VERSION {
            return RuntimeResponse::err(
                request.request_id,
                "bad_version",
                format!(
                    "protocol version {} is not supported by tadod {}",
                    request.version, PROTOCOL_VERSION
                ),
            );
        }
        let request_id = request.request_id.clone();
        match self.dispatch(&request.kind, request.payload, shutdown) {
            Ok(data) => RuntimeResponse::ok(request_id, data),
            Err(err) => RuntimeResponse::err(request_id, "runtime_error", err.to_string()),
        }
    }

    fn dispatch(&self, kind: &str, payload: Value, shutdown: watch::Sender<bool>) -> Result<Value> {
        self.reconcile_live_statuses();
        match kind {
            "runtime.status" => self.status(),
            "daemon.shutdown" => {
                self.append_event(
                    "daemon.shutdown_requested",
                    None,
                    "shutdown requested",
                    Some(&payload),
                );
                self.shutdown_live_sessions();
                let _ = shutdown.send(true);
                Ok(json!({ "ok": true }))
            }
            "session.spawn" => self.spawn(payload),
            "session.list" => self.list_sessions(),
            "session.read" => self.read_session(payload),
            "session.send" => self.send_session(payload),
            "session.broadcast" => self.broadcast_session(payload),
            "session.kill" => self.kill_session(payload),
            "session.delete" => self.delete_session(payload),
            "advisor.link" => self.advisor_link(payload),
            "transcript.tail" => self.tail_transcript(payload),
            "transcript.read" => self.read_transcript(payload),
            "transcript.search" => self.search_transcripts(payload),
            "events.list" => self.list_events(payload),
            "events.notify" => self.notify_event(payload),
            "settings.get" => self.settings_get(),
            "settings.set" => self.settings_set(payload),
            "project.status" => self.project_status(),
            "project.list" => self.project_list(),
            "project.add" => self.project_add(payload),
            "project.use" => self.project_use(payload),
            "kanban.snapshot" => self.kanban_snapshot(),
            "kanban.move" => self.kanban_move(payload),
            "kanban.add_column" => self.kanban_add_column(payload),
            "bootstrap.request" => self.bootstrap_request(payload),
            "workflow.propose" => self.workflow_propose(payload),
            "workflow.status" => self.workflow_status(payload),
            "workflow.list" => self.workflow_list(payload),
            "workflow.crafted" => self.workflow_crafted(payload),
            "workflow.accept" => self.workflow_accept(payload),
            "workflow.reject" => self.workflow_reject(payload),
            "workflow.stop" => self.workflow_stop(payload),
            other => Err(anyhow!("unknown runtime request kind: {other}")),
        }
    }

    fn status(&self) -> Result<Value> {
        let live_count = self.sessions.lock().unwrap().len();
        let db = self.db.lock().unwrap();
        Ok(json!({
            "runtime_id": self.runtime_id,
            "profile": self.paths.profile,
            "socket": self.paths.socket_path,
            "db": self.paths.db_path,
            "schema_version": db.schema_version()?,
            "live_sessions": live_count,
            "active_project": db.active_project()?,
        }))
    }

    fn spawn(&self, payload: Value) -> Result<Value> {
        let mut request: SpawnRequest = serde_json::from_value(payload)?;
        if request.project_root.is_none() {
            if let Some(project) = self.db.lock().unwrap().active_project()? {
                request.project_id = request.project_id.or(Some(project.id));
                request.project_root = Some(project.root.clone());
                request.cwd = request.cwd.or(Some(project.root));
            }
        }
        let plan = plan_spawn(request)?;
        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        let mut env = self.base_env(&id, &plan);
        env.extend(plan.env.clone());

        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let output_tap: tado_core::session::OutputTap = Arc::new(move |bytes: &[u8]| {
            let _ = tx.send(bytes.to_vec());
        });
        let session = Session::spawn_with_output_tap(
            &plan.executable,
            &plan.args,
            plan.cwd.as_deref(),
            &env,
            plan.cols,
            plan.rows,
            Some(output_tap),
        )
        .with_context(|| format!("spawn {}", plan.executable))?;

        let pid = session.process_id();
        let status = if matches!(plan.engine, Engine::Cowork) {
            "waiting"
        } else {
            "running"
        };
        let (grid_row, grid_col) = self.db.lock().unwrap().next_grid_position()?;
        let record = SessionRecord {
            id: id.clone(),
            title: plan.title.clone(),
            kind: if matches!(plan.engine, Engine::Cowork) {
                "cowork".into()
            } else {
                "pty".into()
            },
            status: status.into(),
            engine: Some(format!("{:?}", plan.engine).to_ascii_lowercase()),
            command: plan.executable.clone(),
            args: plan.args.clone(),
            cwd: plan.cwd.clone(),
            project_id: plan.project_id.clone(),
            project_root: plan.project_root.clone(),
            agent_name: plan.agent_name.clone(),
            team_name: plan.team_name.clone(),
            grid_row: Some(grid_row),
            grid_col: Some(grid_col),
            pid,
            created_at: now.clone(),
            updated_at: now,
            exit_code: None,
            cowork_result_path: plan.cowork_result_path.clone(),
        };

        {
            let db = self.db.lock().unwrap();
            db.insert_session(&record)?;
            db.append_transcript(&id, "system", &format!("spawned {}", record.title))?;
            db.append_event(
                "session.spawned",
                Some(&id),
                &format!("spawned {}", record.title),
                Some(&serde_json::to_value(&record)?),
            )?;
        }
        start_transcript_writer(
            self.paths.db_path.clone(),
            id.clone(),
            rx,
            self.sessions.clone(),
            self.advisor_links.clone(),
        );
        self.sessions
            .lock()
            .unwrap()
            .insert(id.clone(), LiveSession { session });

        Ok(json!({ "session": record }))
    }

    fn list_sessions(&self) -> Result<Value> {
        let sessions = self.db.lock().unwrap().list_sessions()?;
        Ok(json!({ "sessions": sessions }))
    }

    fn read_session(&self, payload: Value) -> Result<Value> {
        let target = required_str(&payload, "target")?;
        let limit = payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(20)
            .min(200) as usize;
        let id = self.resolve_session_id(target)?;
        let mut text = String::new();
        let mut source = "transcript";

        if let Some(live) = self.sessions.lock().unwrap().get(&id) {
            live.session.capture_viewport_frame();
            text = snapshot_text(&live.session);
            source = "pty";
            if !text.trim().is_empty() {
                let _ = self
                    .db
                    .lock()
                    .unwrap()
                    .append_transcript(&id, "screen", &text);
            }
        }

        if text.trim().is_empty() {
            if let Some(record) = self.db.lock().unwrap().get_session(&id)? {
                if record.kind == "cowork" {
                    if let Some(path) = record.cowork_result_path.as_deref() {
                        if let Ok(result) = std::fs::read_to_string(path) {
                            text = result;
                            source = "cowork-result";
                        } else {
                            text = format!("Cowork result is not ready yet.\nExpected: {path}");
                            source = "cowork-status";
                        }
                    }
                }
            }
        }

        if text.trim().is_empty() {
            let chunks = self.db.lock().unwrap().transcript_tail(&id, limit)?;
            text = chunks
                .into_iter()
                .map(|(_, stream, chunk, _)| format!("[{stream}] {chunk}"))
                .collect::<Vec<_>>()
                .join("\n");
        }
        Ok(json!({ "session_id": id, "source": source, "text": text }))
    }

    fn send_session(&self, payload: Value) -> Result<Value> {
        let target = required_str(&payload, "target")?;
        let message = required_str(&payload, "message")?;
        let id = self.resolve_session_id(target)?;
        let live = {
            let sessions = self.sessions.lock().unwrap();
            sessions
                .get(&id)
                .map(|s| s.session.clone())
                .ok_or_else(|| anyhow!("session {id} is not live"))?
        };
        let mut bytes = message.as_bytes().to_vec();
        if payload
            .get("enter")
            .and_then(Value::as_bool)
            .unwrap_or(true)
        {
            bytes.push(b'\n');
        }
        let written = live.write(&bytes)?;
        {
            let db = self.db.lock().unwrap();
            db.append_transcript(&id, "stdin", message)?;
            db.append_event(
                "session.sent",
                Some(&id),
                "message sent to session",
                Some(&json!({ "bytes": written })),
            )?;
        }
        Ok(json!({ "session_id": id, "bytes": written }))
    }

    fn broadcast_session(&self, payload: Value) -> Result<Value> {
        let message = required_str(&payload, "message")?;
        let project_root = payload.get("project_root").and_then(Value::as_str);
        let team = payload.get("team").and_then(Value::as_str);
        let sessions = self.db.lock().unwrap().list_sessions()?;
        let mut sent = Vec::new();
        for session in sessions {
            if !matches!(session.status.as_str(), "running" | "waiting") {
                continue;
            }
            if let Some(root) = project_root {
                if session.project_root.as_deref() != Some(root) {
                    continue;
                }
            }
            if let Some(team) = team {
                if session.team_name.as_deref() != Some(team) {
                    continue;
                }
            }
            if self
                .send_session(json!({
                    "target": session.id,
                    "message": message,
                    "enter": payload.get("enter").and_then(Value::as_bool).unwrap_or(true),
                }))
                .is_ok()
            {
                sent.push(session.id);
            }
        }
        Ok(json!({ "sent": sent }))
    }

    fn advisor_link(&self, payload: Value) -> Result<Value> {
        let executioner = required_str(&payload, "executioner_id")?;
        let advisor = required_str(&payload, "advisor_id")?;
        let executioner_id = self.resolve_session_id(executioner)?;
        let advisor_id = self.resolve_session_id(advisor)?;
        if executioner_id == advisor_id {
            return Err(anyhow!("advisor.link requires two different sessions"));
        }
        {
            let sessions = self.sessions.lock().unwrap();
            if !sessions.contains_key(&executioner_id) {
                return Err(anyhow!("executioner session {executioner_id} is not live"));
            }
            if !sessions.contains_key(&advisor_id) {
                return Err(anyhow!("advisor session {advisor_id} is not live"));
            }
        }
        self.advisor_links.lock().unwrap().insert(
            executioner_id.clone(),
            AdvisorLink {
                advisor_id: advisor_id.clone(),
                last_message: String::new(),
            },
        );
        self.append_event(
            "advisor.linked",
            Some(&executioner_id),
            "advisor linked to executioner",
            Some(&json!({ "advisor_id": advisor_id })),
        );
        Ok(json!({
            "executioner_id": executioner_id,
            "advisor_id": advisor_id,
        }))
    }

    fn kill_session(&self, payload: Value) -> Result<Value> {
        let target = required_str(&payload, "target")?;
        let hard = payload
            .get("hard")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let id = self.resolve_session_id(target)?;
        let signal = if hard { libc::SIGKILL } else { libc::SIGTERM };
        if let Some(live) = self.sessions.lock().unwrap().remove(&id) {
            live.session.kill(signal);
        }
        self.remove_advisor_link(&id);
        let status = if hard { "killed" } else { "stopped" };
        {
            let db = self.db.lock().unwrap();
            db.update_session_status(&id, status, None)?;
            db.append_event(
                if hard {
                    "session.killed"
                } else {
                    "session.stopped"
                },
                Some(&id),
                status,
                Some(&json!({ "signal": signal })),
            )?;
        }
        Ok(json!({ "session_id": id, "status": status }))
    }

    fn delete_session(&self, payload: Value) -> Result<Value> {
        let target = required_str(&payload, "target")?;
        let hard = payload.get("hard").and_then(Value::as_bool).unwrap_or(true);
        let id = self.resolve_session_id(target)?;
        let signal = if hard { libc::SIGKILL } else { libc::SIGTERM };
        if let Some(live) = self.sessions.lock().unwrap().remove(&id) {
            live.session.kill(signal);
        }
        self.remove_advisor_link(&id);
        let deleted = {
            let db = self.db.lock().unwrap();
            let deleted = db.delete_session(&id)?;
            db.append_event(
                "session.deleted",
                Some(&id),
                "session deleted",
                Some(&json!({ "signal": signal, "hard": hard })),
            )?;
            deleted
        };
        Ok(json!({ "session_id": id, "deleted": deleted }))
    }

    fn search_transcripts(&self, payload: Value) -> Result<Value> {
        let query = required_str(&payload, "query")?;
        let limit = payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(20)
            .min(200) as usize;
        let matches = self.db.lock().unwrap().search_transcripts(query, limit)?;
        Ok(json!({ "matches": matches }))
    }

    fn read_transcript(&self, payload: Value) -> Result<Value> {
        let target = required_str(&payload, "target")?;
        let after_cursor = payload
            .get("after_cursor")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let limit = payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(100)
            .min(500) as usize;
        let id = self.resolve_session_id(target)?;
        let chunks = self
            .db
            .lock()
            .unwrap()
            .transcript_after(&id, after_cursor, limit)?;
        let cursor = chunks
            .iter()
            .map(|(cursor, _, _, _)| *cursor)
            .max()
            .unwrap_or(after_cursor);
        let chunks = chunks
            .into_iter()
            .map(|(cursor, stream, chunk, created_at)| {
                json!({
                    "cursor": cursor,
                    "stream": stream,
                    "chunk": chunk,
                    "created_at": created_at,
                })
            })
            .collect::<Vec<_>>();
        Ok(json!({ "session_id": id, "cursor": cursor, "chunks": chunks }))
    }

    fn tail_transcript(&self, payload: Value) -> Result<Value> {
        let target = required_str(&payload, "target")?;
        let limit = payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(80)
            .min(500) as usize;
        let id = self.resolve_session_id(target)?;
        let chunks = self.db.lock().unwrap().transcript_tail(&id, limit)?;
        let cursor = chunks
            .iter()
            .map(|(cursor, _, _, _)| *cursor)
            .max()
            .unwrap_or(0);
        let chunks = chunks
            .into_iter()
            .map(|(cursor, stream, chunk, created_at)| {
                json!({
                    "cursor": cursor,
                    "stream": stream,
                    "chunk": chunk,
                    "created_at": created_at,
                })
            })
            .collect::<Vec<_>>();
        Ok(json!({ "session_id": id, "cursor": cursor, "chunks": chunks }))
    }

    fn list_events(&self, payload: Value) -> Result<Value> {
        let limit = payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(80)
            .min(500) as usize;
        let events = self.db.lock().unwrap().list_events(limit)?;
        Ok(json!({ "events": events }))
    }

    fn notify_event(&self, payload: Value) -> Result<Value> {
        let title = required_str(&payload, "title")?;
        let body = payload.get("body").and_then(Value::as_str).unwrap_or("");
        let severity = payload
            .get("severity")
            .and_then(Value::as_str)
            .unwrap_or("info");
        let event_id = self.db.lock().unwrap().append_event(
            "user.broadcast",
            None,
            title,
            Some(&json!({
                "title": title,
                "body": body,
                "severity": severity,
                "source": "runtime",
            })),
        )?;
        Ok(json!({ "id": event_id, "kind": "user.broadcast" }))
    }

    fn settings_get(&self) -> Result<Value> {
        let raw = self.db.lock().unwrap().meta("tui_settings")?;
        let settings = raw
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
            .unwrap_or(Value::Null);
        Ok(json!({ "settings": settings }))
    }

    fn settings_set(&self, payload: Value) -> Result<Value> {
        let settings = payload.get("settings").cloned().unwrap_or(Value::Null);
        self.db
            .lock()
            .unwrap()
            .set_meta("tui_settings", &settings.to_string())?;
        self.append_event(
            "settings.updated",
            None,
            "TUI settings updated",
            Some(&json!({ "source": "tui" })),
        );
        Ok(json!({ "settings": settings }))
    }

    fn project_status(&self) -> Result<Value> {
        let db = self.db.lock().unwrap();
        Ok(json!({
            "active": db.active_project()?,
            "projects": db.list_projects()?,
            "profile": self.paths.profile,
            "profile_root": self.paths.profile_root,
            "db": self.paths.db_path,
        }))
    }

    fn project_list(&self) -> Result<Value> {
        let db = self.db.lock().unwrap();
        Ok(json!({
            "active": db.active_project()?,
            "projects": db.list_projects()?,
        }))
    }

    fn project_add(&self, payload: Value) -> Result<Value> {
        let root = required_str(&payload, "root")?;
        let create = payload
            .get("create")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let root_path = expand_path(root)?;
        if root_path.exists() && !root_path.is_dir() {
            return Err(anyhow!(
                "project root exists but is not a directory: {}",
                root_path.display()
            ));
        }
        if !root_path.exists() {
            if create {
                std::fs::create_dir_all(&root_path)
                    .with_context(|| format!("create project root {}", root_path.display()))?;
            } else {
                return Err(anyhow!(
                    "project root does not exist: {}. Use /project create <path> or tado project add --create <path>.",
                    root_path.display()
                ));
            }
        }
        let canonical = root_path
            .canonicalize()
            .with_context(|| format!("canonicalize project root {}", root_path.display()))?;
        let name = payload
            .get("name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .or_else(|| {
                canonical
                    .file_name()
                    .and_then(|name| name.to_str())
                    .map(str::to_string)
            })
            .unwrap_or_else(|| canonical.display().to_string());
        let project = {
            let db = self.db.lock().unwrap();
            let project = db.upsert_project(&name, &canonical.display().to_string())?;
            if payload
                .get("activate")
                .and_then(Value::as_bool)
                .unwrap_or(true)
            {
                db.set_active_project(&project.id)?;
            }
            project
        };
        self.append_event(
            "project.added",
            Some(&project.id),
            &format!("project added {}", project.name),
            Some(&json!({ "project": project })),
        );
        Ok(json!({ "project": project, "active": self.db.lock().unwrap().active_project()? }))
    }

    fn project_use(&self, payload: Value) -> Result<Value> {
        let target = required_str(&payload, "target")?;
        let project = {
            let db = self.db.lock().unwrap();
            let project = db.resolve_project(target)?.ok_or_else(|| {
                anyhow!("no project matches {target:?}; add it first with /project add <path>")
            })?;
            db.set_active_project(&project.id)?;
            project
        };
        self.append_event(
            "project.selected",
            Some(&project.id),
            &format!("active project {}", project.name),
            Some(&json!({ "project": project })),
        );
        Ok(json!({ "active": project }))
    }

    fn kanban_snapshot(&self) -> Result<Value> {
        let db = self.db.lock().unwrap();
        let columns = db.kanban_columns()?;
        let overrides = db.kanban_card_lanes()?;
        let sessions = db.list_sessions()?;
        drop(db);
        let cards = sessions
            .into_iter()
            .map(|s| {
                let lane = overrides
                    .get(&s.id)
                    .cloned()
                    .unwrap_or_else(|| lane_for_status(&s.status).to_string());
                json!({
                    "id": s.id,
                    "title": s.title,
                    "lane": lane,
                    "status": s.status,
                    "engine": s.engine,
                    "agent": s.agent_name,
                    "team": s.team_name,
                    "grid": grid_label(s.grid_row, s.grid_col),
                    "project_root": s.project_root,
                    "session_id": s.id,
                })
            })
            .collect::<Vec<_>>();
        Ok(json!({ "columns": columns, "cards": cards }))
    }

    fn kanban_move(&self, payload: Value) -> Result<Value> {
        let target = required_str(&payload, "target")?;
        let lane = required_str(&payload, "lane")?;
        let id = self.resolve_session_id(target)?;
        let session = self
            .db
            .lock()
            .unwrap()
            .get_session(&id)?
            .ok_or_else(|| anyhow!("no session matches {id:?}"))?;
        {
            let db = self.db.lock().unwrap();
            db.move_kanban_card(&session, lane)?;
            db.append_event(
                "kanban.moved",
                Some(&id),
                "card moved",
                Some(&json!({ "lane": lane })),
            )?;
        }
        Ok(json!({ "session_id": id, "lane": lane }))
    }

    fn kanban_add_column(&self, payload: Value) -> Result<Value> {
        let key = required_str(&payload, "key")?;
        let title = required_str(&payload, "title")?;
        let lane_kind = payload
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("custom");
        {
            let db = self.db.lock().unwrap();
            db.add_kanban_column(key, title, lane_kind)?;
            db.append_event(
                "kanban.column_added",
                None,
                "column added",
                Some(&json!({ "key": key, "title": title, "kind": lane_kind })),
            )?;
        }
        Ok(json!({ "key": key, "title": title, "kind": lane_kind }))
    }

    fn bootstrap_request(&self, payload: Value) -> Result<Value> {
        let action = required_str(&payload, "action")?;
        let engine = payload
            .get("engine")
            .and_then(Value::as_str)
            .unwrap_or("claude");
        let project_root = payload
            .get("project_root")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| {
                std::env::current_dir()
                    .ok()
                    .map(|p| p.display().to_string())
            });
        let prompt = bootstrap_prompt(action, project_root.as_deref());
        let spawn_payload = if engine == "shell" {
            json!({
                "engine": "shell",
                "command": format!("printf '%s\\n' {}", crate::spawn::shell_escape(&format!("bootstrap requested: {action}"))),
                "title": format!("bootstrap {action}"),
                "cwd": project_root.as_deref(),
                "project_root": project_root.as_deref(),
                "agent_name": "bootstrap",
            })
        } else {
            json!({
                "engine": engine,
                "prompt": prompt,
                "title": format!("bootstrap {action}"),
                "cwd": project_root.as_deref(),
                "project_root": project_root.as_deref(),
                "agent_name": "bootstrap",
            })
        };
        let session = self.spawn(spawn_payload)?;
        self.append_event(
            "bootstrap.requested",
            session
                .get("session")
                .and_then(|s| s.get("id"))
                .and_then(Value::as_str),
            "bootstrap requested",
            Some(&payload),
        );
        Ok(json!({ "action": action, "spawn": session }))
    }

    fn workflow_propose(&self, payload: Value) -> Result<Value> {
        let kind = required_str(&payload, "kind")?;
        let feature = required_str(&payload, "feature")?;
        let task = required_str(&payload, "task")?;
        let engine = payload
            .get("engine")
            .and_then(Value::as_str)
            .unwrap_or("claude");
        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        let project = payload
            .get("project")
            .and_then(Value::as_str)
            .map(str::to_string);
        let (project_id, project_root) = self.workflow_project_context(project.as_deref())?;
        let raw_mode = payload
            .get("mode")
            .and_then(Value::as_str)
            .map(str::to_string);
        let raw_layout = payload
            .get("layout")
            .and_then(Value::as_str)
            .map(str::to_string);
        let mode = if kind == "dispatch" {
            Some(normalized_dispatch_execution_type(raw_mode.as_deref()).to_string())
        } else {
            raw_mode
        };
        let layout = if kind == "dispatch" {
            Some(normalized_dispatch_layout(raw_layout.as_deref()).to_string())
        } else {
            raw_layout
        };
        if kind == "dispatch" {
            if let Some(project_root) = project_root.as_deref() {
                seed_runtime_dispatch_run(project_root, &id, task)?;
            }
        }
        let crafted =
            workflow_crafted_text(kind, feature, task, mode.as_deref(), layout.as_deref());
        let record = WorkflowRecord {
            id: id.clone(),
            kind: kind.to_string(),
            project: project.clone(),
            feature: feature.to_string(),
            task: task.to_string(),
            mode: mode.clone(),
            layout: layout.clone(),
            engine: Some(engine.to_string()),
            state: "drafting".into(),
            coordinator_todo_id: payload
                .get("coordinator_todo_id")
                .and_then(Value::as_str)
                .map(str::to_string),
            label: payload
                .get("label")
                .and_then(Value::as_str)
                .map(str::to_string),
            crafted: Some(crafted.clone()),
            note: None,
            reason: None,
            architect_session_id: None,
            worker_session_id: None,
            created_at: now.clone(),
            updated_at: now,
        };
        self.db.lock().unwrap().insert_workflow(&record)?;
        let prompt = workflow_architect_prompt(
            kind,
            &id,
            feature,
            task,
            mode.as_deref(),
            layout.as_deref(),
            project_root.as_deref(),
        );
        let spawn = self.spawn(workflow_spawn_payload(
            engine,
            &prompt,
            &format!("{kind} architect {feature}"),
            project_id.as_deref(),
            project_root.as_deref(),
            &format!("{kind}-architect"),
        ))?;
        let architect_session_id = spawn
            .get("session")
            .and_then(|s| s.get("id"))
            .and_then(Value::as_str)
            .map(str::to_string);
        if let Some(session_id) = architect_session_id.as_deref() {
            self.db.lock().unwrap().update_workflow(
                &id,
                "drafting",
                Some(&crafted),
                None,
                None,
                Some(session_id),
                None,
            )?;
        }
        self.append_event(
            "workflow.proposed",
            Some(&id),
            "workflow proposed",
            Some(&json!({
                "kind": kind,
                "feature": feature,
                "mode": record.mode,
                "layout": record.layout,
            })),
        );
        self.workflow_status(json!({ "run_id": id }))
    }

    fn workflow_status(&self, payload: Value) -> Result<Value> {
        let run_id = required_str(&payload, "run_id")?;
        let record = self
            .db
            .lock()
            .unwrap()
            .get_workflow(run_id)?
            .ok_or_else(|| anyhow!("no workflow run matches {run_id:?}"))?;
        Ok(json!({ "run": record }))
    }

    fn workflow_list(&self, payload: Value) -> Result<Value> {
        let kind = required_str(&payload, "kind")?;
        let project = payload.get("project").and_then(Value::as_str);
        let state = payload.get("state").and_then(Value::as_str);
        let runs = self
            .db
            .lock()
            .unwrap()
            .list_workflows(kind, project, state)?;
        Ok(json!({ "runs": runs }))
    }

    fn workflow_crafted(&self, payload: Value) -> Result<Value> {
        let run_id = required_str(&payload, "run_id")?;
        let record = self
            .db
            .lock()
            .unwrap()
            .get_workflow(run_id)?
            .ok_or_else(|| anyhow!("no workflow run matches {run_id:?}"))?;
        Ok(json!({
            "run_id": run_id,
            "crafted": record.crafted.unwrap_or_else(|| {
                workflow_crafted_text(
                    &record.kind,
                    &record.feature,
                    &record.task,
                    record.mode.as_deref(),
                    record.layout.as_deref(),
                )
            }),
        }))
    }

    fn workflow_accept(&self, payload: Value) -> Result<Value> {
        let run_id = required_str(&payload, "run_id")?;
        let note = payload.get("note").and_then(Value::as_str);
        let record = self
            .db
            .lock()
            .unwrap()
            .get_workflow(run_id)?
            .ok_or_else(|| anyhow!("no workflow run matches {run_id:?}"))?;
        if record.kind == "dispatch" {
            if let Some(value) = self.workflow_accept_dispatch(&record, note)? {
                return Ok(value);
            }
        }
        let engine = record.engine.as_deref().unwrap_or("claude");
        let (project_id, project_root) =
            self.workflow_project_context(record.project.as_deref())?;
        let prompt = format!(
            "You are the Tado {} worker for run {}.\n\nFeature: {}\nTask: {}\n\nAcceptance note: {}\n\nExecute the task, report progress visibly, and stop when done.",
            record.kind,
            record.id,
            record.feature,
            record.task,
            note.unwrap_or("(none)")
        );
        let spawn = self.spawn(workflow_spawn_payload(
            engine,
            &prompt,
            &format!("{} worker {}", record.kind, record.feature),
            project_id.as_deref(),
            project_root.as_deref(),
            &format!("{}-worker", record.kind),
        ))?;
        let worker_session_id = spawn
            .get("session")
            .and_then(|s| s.get("id"))
            .and_then(Value::as_str)
            .map(str::to_string);
        self.db.lock().unwrap().update_workflow(
            run_id,
            "running",
            None,
            note,
            None,
            None,
            worker_session_id.as_deref(),
        )?;
        self.append_event(
            "workflow.accepted",
            Some(run_id),
            "workflow accepted",
            Some(&json!({ "worker_session_id": worker_session_id })),
        );
        self.workflow_status(json!({ "run_id": run_id }))
    }

    fn workflow_accept_dispatch(
        &self,
        record: &WorkflowRecord,
        note: Option<&str>,
    ) -> Result<Option<Value>> {
        let execution_type = normalized_dispatch_execution_type(record.mode.as_deref());
        let (project_id, project_root) =
            self.workflow_project_context(record.project.as_deref())?;
        let Some(project_root) = project_root else {
            return Ok(None);
        };
        let run_dir = PathBuf::from(&project_root)
            .join(".tado")
            .join("dispatch")
            .join("runs")
            .join(&record.id);
        let phases = read_dispatch_phases(&run_dir)?;
        if phases.is_empty() {
            return Ok(None);
        }
        let selected_phases: Vec<_> = if execution_type == "wave" {
            phases
        } else {
            phases.into_iter().take(1).collect()
        };
        let mut session_ids = Vec::new();
        let mut phase_ids = Vec::new();
        for phase in selected_phases {
            let engine = normalized_dispatch_engine(
                phase
                    .engine
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .or(record.engine.as_deref())
                    .unwrap_or("claude"),
            );
            let phase_id = if phase.id.trim().is_empty() {
                format!("phase-{}", phase.order.max(1))
            } else {
                phase.id.clone()
            };
            let title = if phase.title.trim().is_empty() {
                format!("dispatch {execution_type} {phase_id}")
            } else {
                format!("dispatch {} {}", record.feature, phase.title)
            };
            let agent_name = phase
                .agent
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .unwrap_or("dispatch-phase");
            let flags = dispatch_agent_flags(&project_root, agent_name, &engine)?;
            let env = vec![
                ("TADO_DISPATCH_RUN_ID".to_string(), record.id.clone()),
                ("TADO_DISPATCH_PHASE_ID".to_string(), phase_id.clone()),
                (
                    "TADO_DISPATCH_EXECUTION_TYPE".to_string(),
                    execution_type.to_string(),
                ),
                (
                    "TADO_DISPATCH_PHASE_ORDER".to_string(),
                    phase.order.to_string(),
                ),
            ];
            let spawn = self.spawn(workflow_spawn_payload_with_env(
                &engine,
                &phase.prompt,
                &title,
                project_id.as_deref(),
                Some(&project_root),
                agent_name,
                env,
                flags,
            ))?;
            if let Some(session_id) = spawn
                .get("session")
                .and_then(|s| s.get("id"))
                .and_then(Value::as_str)
            {
                session_ids.push(session_id.to_string());
            }
            phase_ids.push(phase_id);
        }

        let joined_sessions = session_ids.join(",");
        let state = if execution_type == "wave" {
            "dispatching"
        } else {
            "running"
        };
        self.db.lock().unwrap().update_workflow(
            &record.id,
            state,
            None,
            note,
            None,
            None,
            if joined_sessions.is_empty() {
                None
            } else {
                Some(joined_sessions.as_str())
            },
        )?;
        self.append_event(
            "workflow.accepted",
            Some(&record.id),
            "dispatch workflow accepted",
            Some(&json!({
                "execution_type": execution_type,
                "layout": normalized_dispatch_layout(record.layout.as_deref()),
                "phase_ids": phase_ids,
                "session_ids": session_ids,
            })),
        );
        Ok(Some(self.workflow_status(json!({ "run_id": record.id }))?))
    }

    fn workflow_project_context(
        &self,
        target: Option<&str>,
    ) -> Result<(Option<String>, Option<String>)> {
        {
            let db = self.db.lock().unwrap();
            if let Some(target) = target {
                if let Some(project) = db.resolve_project(target)? {
                    return Ok((Some(project.id), Some(project.root)));
                }
            }
            if let Some(project) = db.active_project()? {
                return Ok((Some(project.id), Some(project.root)));
            }
        }
        if let Some(target) = target {
            let expanded = expand_path(target)?;
            return Ok((None, Some(expanded.display().to_string())));
        }
        Ok((None, None))
    }

    fn workflow_reject(&self, payload: Value) -> Result<Value> {
        let run_id = required_str(&payload, "run_id")?;
        let reason = required_str(&payload, "reason")?;
        self.db.lock().unwrap().update_workflow(
            run_id,
            "rejected",
            payload.get("rebrief").and_then(Value::as_str),
            None,
            Some(reason),
            None,
            None,
        )?;
        self.append_event(
            "workflow.rejected",
            Some(run_id),
            "workflow rejected",
            Some(&json!({ "reason": reason })),
        );
        self.workflow_status(json!({ "run_id": run_id }))
    }

    fn workflow_stop(&self, payload: Value) -> Result<Value> {
        let run_id = required_str(&payload, "run_id")?;
        let record = self
            .db
            .lock()
            .unwrap()
            .get_workflow(run_id)?
            .ok_or_else(|| anyhow!("no workflow run matches {run_id:?}"))?;
        if let Some(session_id) = record.worker_session_id.as_deref() {
            let _ = self.kill_session(json!({ "target": session_id, "hard": false }));
        }
        self.db
            .lock()
            .unwrap()
            .update_workflow(run_id, "stopped", None, None, None, None, None)?;
        self.append_event("workflow.stopped", Some(run_id), "workflow stopped", None);
        self.workflow_status(json!({ "run_id": run_id }))
    }

    fn resolve_session_id(&self, target: &str) -> Result<String> {
        let sessions = self.db.lock().unwrap().list_sessions()?;
        if sessions.iter().any(|s| s.id == target) {
            return Ok(target.to_string());
        }
        if let Some(session) = sessions
            .iter()
            .find(|s| target_matches_grid(target, s.grid_row, s.grid_col))
        {
            return Ok(session.id.clone());
        }
        let matches = sessions
            .iter()
            .filter(|s| {
                s.id.starts_with(target) || s.title.to_lowercase().contains(&target.to_lowercase())
            })
            .collect::<Vec<_>>();
        match matches.len() {
            1 => Ok(matches[0].id.clone()),
            0 => Err(anyhow!("no session matches {target:?}")),
            _ => Err(anyhow!(
                "multiple sessions match {target:?}; use a longer id"
            )),
        }
    }

    fn base_env(&self, id: &str, plan: &crate::spawn::SpawnPlan) -> Vec<(String, String)> {
        let mut env = std::env::vars().collect::<Vec<_>>();
        env.push(("TADO_PROFILE".into(), self.paths.profile.clone()));
        env.push(("TADO_RUNTIME_ID".into(), self.runtime_id.clone()));
        env.push((
            "TADO_RUNTIME_SOCKET".into(),
            self.paths.socket_path.display().to_string(),
        ));
        env.push(("TADO_SESSION_ID".into(), id.to_string()));
        env.push((
            "TADO_ENGINE".into(),
            format!("{:?}", plan.engine).to_ascii_lowercase(),
        ));
        if let Some(project_id) = &plan.project_id {
            env.push(("TADO_PROJECT_ID".into(), project_id.clone()));
        }
        if let Some(project_root) = &plan.project_root {
            env.push(("TADO_PROJECT_ROOT".into(), project_root.clone()));
        }
        if let Some(agent) = &plan.agent_name {
            env.push(("TADO_AGENT".into(), agent.clone()));
            env.push(("TADO_AGENT_NAME".into(), agent.clone()));
        }
        if let Some(team) = &plan.team_name {
            env.push(("TADO_TEAM_NAME".into(), team.clone()));
        }
        env
    }

    fn remove_advisor_link(&self, id: &str) {
        let mut links = self.advisor_links.lock().unwrap();
        links.remove(id);
        let advisor_owned = id.to_string();
        links.retain(|_, link| link.advisor_id != advisor_owned);
    }

    fn reconcile_live_statuses(&self) {
        let ids = self
            .sessions
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(id, live)| {
                if live.session.running.load(Ordering::Acquire) {
                    None
                } else {
                    Some((id.clone(), live.session.exit_code.load(Ordering::Acquire)))
                }
            })
            .collect::<Vec<_>>();
        if ids.is_empty() {
            return;
        }
        for (id, code) in ids {
            self.sessions.lock().unwrap().remove(&id);
            self.remove_advisor_link(&id);
            let exit_code = if code == i32::MIN { None } else { Some(code) };
            let status = if exit_code == Some(0) {
                "done"
            } else {
                "exited"
            };
            let db = self.db.lock().unwrap();
            let _ = db.update_session_status(&id, status, exit_code);
            let _ = db.append_event(
                "session.exited",
                Some(&id),
                status,
                Some(&json!({ "exit_code": exit_code })),
            );
        }
    }

    fn shutdown_live_sessions(&self) {
        let drained = self
            .sessions
            .lock()
            .unwrap()
            .drain()
            .collect::<Vec<(String, LiveSession)>>();
        if drained.is_empty() {
            return;
        }
        self.advisor_links.lock().unwrap().clear();
        for (_, live) in &drained {
            live.session.kill(libc::SIGTERM);
        }
        thread::sleep(std::time::Duration::from_millis(250));
        for (_, live) in &drained {
            live.session.kill(libc::SIGKILL);
        }
        let db = self.db.lock().unwrap();
        for (id, live) in drained {
            drop(live);
            let _ = db.update_session_status(&id, "stopped", None);
            let _ = db.append_event(
                "session.stopped",
                Some(&id),
                "session stopped during daemon shutdown",
                Some(&json!({ "signal": libc::SIGTERM })),
            );
        }
    }

    fn append_event(
        &self,
        kind: &str,
        subject_id: Option<&str>,
        message: &str,
        payload: Option<&Value>,
    ) {
        if let Ok(db) = self.db.lock() {
            let _ = db.append_event(kind, subject_id, message, payload);
        }
    }

    async fn stream_events(&self, mut stream: UnixStream, request: RuntimeRequest) -> Result<()> {
        if request.version != PROTOCOL_VERSION {
            let response = RuntimeResponse::err(
                request.request_id,
                "bad_version",
                format!(
                    "protocol version {} is not supported by tadod {}",
                    request.version, PROTOCOL_VERSION
                ),
            );
            write_json_frame_async(&mut stream, &response).await?;
            return Ok(());
        }

        let limit = request
            .payload
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(100)
            .min(500) as usize;
        let poll_ms = request
            .payload
            .get("poll_ms")
            .and_then(Value::as_u64)
            .unwrap_or(250)
            .clamp(100, 5_000);
        let mut cursor = request
            .payload
            .get("after_id")
            .and_then(Value::as_i64)
            .unwrap_or(0);

        loop {
            self.reconcile_live_statuses();
            let events = self.db.lock().unwrap().list_events_after(cursor, limit)?;
            if !events.is_empty() {
                if let Some(max_id) = events.iter().filter_map(|e| e.get("id")?.as_i64()).max() {
                    cursor = max_id;
                }
                let response = RuntimeResponse::ok(
                    request.request_id.clone(),
                    json!({ "cursor": cursor, "events": events }),
                );
                if write_json_frame_async(&mut stream, &response)
                    .await
                    .is_err()
                {
                    break;
                }
            } else if stream.flush().await.is_err() {
                break;
            }
            sleep(Duration::from_millis(poll_ms)).await;
        }
        Ok(())
    }
}

fn required_str<'a>(payload: &'a Value, key: &str) -> Result<&'a str> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("missing required string field {key:?}"))
}

fn expand_path(input: &str) -> Result<PathBuf> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(anyhow!("empty path"));
    }
    if trimmed == "~" {
        if let Some(home) = std::env::var_os("HOME") {
            return Ok(PathBuf::from(home));
        }
    }
    if let Some(rest) = trimmed.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return Ok(PathBuf::from(home).join(rest));
        }
    }
    let path = PathBuf::from(trimmed);
    if path.is_absolute() {
        Ok(path)
    } else if trimmed == "." {
        Ok(std::env::current_dir()?)
    } else if let Some(rest) = trimmed.strip_prefix("./") {
        Ok(std::env::current_dir()?.join(rest))
    } else if trimmed == ".." || trimmed.starts_with("../") {
        Ok(std::env::current_dir()?.join(path))
    } else if let Some(home_path) = home_relative_path(trimmed) {
        Ok(home_path)
    } else {
        Ok(home_dir()?.join(path))
    }
}

fn home_dir() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("HOME is not set"))
}

fn home_relative_path(trimmed: &str) -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let path = Path::new(trimmed);
    let mut components = path.components();
    let first = components.next()?.as_os_str().to_string_lossy();
    let canonical = match first.to_ascii_lowercase().as_str() {
        "desktop" => "Desktop",
        "documents" => "Documents",
        "downloads" => "Downloads",
        "applications" => "Applications",
        "pictures" => "Pictures",
        "movies" => "Movies",
        "music" => "Music",
        "library" => "Library",
        _ => return None,
    };
    let mut out = home.join(canonical);
    for component in components {
        out.push(component.as_os_str());
    }
    Some(out)
}

fn grid_label(row: Option<i64>, col: Option<i64>) -> Option<String> {
    Some(format!("[{}, {}]", row?, col?))
}

fn target_matches_grid(target: &str, row: Option<i64>, col: Option<i64>) -> bool {
    let Some(row) = row else {
        return false;
    };
    let Some(col) = col else {
        return false;
    };
    let cleaned = target
        .trim()
        .replace(['[', ']'], "")
        .chars()
        .filter(|ch| !ch.is_whitespace())
        .collect::<String>();
    for sep in [',', ':'] {
        if let Some((left, right)) = cleaned.split_once(sep) {
            if left.parse::<i64>().ok() == Some(row) && right.parse::<i64>().ok() == Some(col) {
                return true;
            }
        }
    }
    false
}

fn bootstrap_prompt(action: &str, project_root: Option<&str>) -> String {
    let root = project_root.unwrap_or("(current project)");
    let directive = match action {
        "a2a" => "Add or refresh Tado A2A tool instructions in CLAUDE.md and AGENTS.md.",
        "team" => "Add or refresh team-awareness instructions for coordinated Tado agents.",
        "auto-mode" => "Add or refresh trusted auto-mode operating instructions.",
        "knowledge" => "Add or refresh Dome knowledge, memory, and retrieval instructions.",
        "cowork" => "Install or refresh the Tado Cowork plugin instructions and lifecycle notes.",
        "index" => "Index project code and Dome docs where available, then report what is searchable.",
        other => return format!("Run Tado bootstrap action `{other}` for project `{root}` and report the exact changes."),
    };
    format!(
        "You are a Tado bootstrap agent for project `{root}`.\n\n\
         Task: {directive}\n\n\
         Keep edits scoped to project instruction/config files. Preserve existing project guidance. \
         When done, print a concise summary of changed files and any follow-up needed."
    )
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct RuntimeDispatchPhase {
    id: String,
    order: i64,
    title: String,
    skill: Option<String>,
    agent: Option<String>,
    engine: Option<String>,
    prompt: String,
    status: Option<String>,
}

impl Default for RuntimeDispatchPhase {
    fn default() -> Self {
        Self {
            id: String::new(),
            order: 0,
            title: String::new(),
            skill: None,
            agent: None,
            engine: None,
            prompt: String::new(),
            status: None,
        }
    }
}

fn normalized_dispatch_execution_type(value: Option<&str>) -> &'static str {
    if value
        .map(|value| value.eq_ignore_ascii_case("wave"))
        .unwrap_or(false)
    {
        "wave"
    } else {
        "sequential"
    }
}

fn normalized_dispatch_layout(value: Option<&str>) -> &'static str {
    if value
        .map(|value| value.eq_ignore_ascii_case("kanban"))
        .unwrap_or(false)
    {
        "kanban"
    } else {
        "grid"
    }
}

fn read_dispatch_phases(run_dir: &Path) -> Result<Vec<RuntimeDispatchPhase>> {
    let phase_dir = run_dir.join("phases");
    if !phase_dir.exists() {
        return Ok(Vec::new());
    }
    let mut phases = Vec::new();
    for entry in std::fs::read_dir(&phase_dir)
        .with_context(|| format!("read dispatch phase dir {}", phase_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
            continue;
        }
        let text = std::fs::read_to_string(&path)
            .with_context(|| format!("read dispatch phase {}", path.display()))?;
        let mut phase: RuntimeDispatchPhase = serde_json::from_str(&text)
            .with_context(|| format!("parse dispatch phase {}", path.display()))?;
        if phase.id.trim().is_empty() {
            phase.id = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or("phase")
                .to_string();
        }
        if phase.order <= 0 {
            phase.order = phases.len() as i64 + 1;
        }
        if phase.prompt.trim().is_empty() {
            return Err(anyhow!(
                "dispatch phase {} has an empty prompt",
                path.display()
            ));
        }
        phases.push(phase);
    }
    phases.sort_by(|a, b| a.order.cmp(&b.order).then_with(|| a.id.cmp(&b.id)));
    Ok(phases)
}

fn seed_runtime_dispatch_run(project_root: &str, run_id: &str, task: &str) -> Result<()> {
    let run_dir = PathBuf::from(project_root)
        .join(".tado")
        .join("dispatch")
        .join("runs")
        .join(run_id);
    std::fs::create_dir_all(run_dir.join("phases"))
        .with_context(|| format!("create dispatch phases dir {}", run_dir.display()))?;
    std::fs::create_dir_all(run_dir.join("retros"))
        .with_context(|| format!("create dispatch retros dir {}", run_dir.display()))?;
    std::fs::write(run_dir.join("dispatch.md"), task)
        .with_context(|| format!("write dispatch brief {}", run_dir.display()))?;
    Ok(())
}

fn workflow_architect_prompt(
    kind: &str,
    run_id: &str,
    feature: &str,
    task: &str,
    mode: Option<&str>,
    layout: Option<&str>,
    project_root: Option<&str>,
) -> String {
    if kind != "dispatch" {
        return format!(
            "You are the Tado {kind} architect for run {run_id}.\n\nFeature: {feature}\nTask: {task}\n\nProduce a concise plan and then wait for acceptance. Do not spawn follow-up agents unless instructed."
        );
    }
    let execution_type = normalized_dispatch_execution_type(mode);
    let layout = normalized_dispatch_layout(layout);
    let run_dir = project_root
        .map(|root| format!("{root}/.tado/dispatch/runs/{run_id}"))
        .unwrap_or_else(|| format!(".tado/dispatch/runs/{run_id}"));
    format!(
        "You are the Tado Dispatch architect for run {run_id}.\n\nFeature: {feature}\nExecution type: {execution_type}\nLayout: {layout}\nRun dir: {run_dir}\n\nTask:\n{task}\n\nCreate a Dispatch plan and then wait for acceptance. Write {run_dir}/plan.json and one phase JSON per phase under {run_dir}/phases/ with fields id, order, title, skill, agent, engine, prompt, nextPhaseFile, and status.\n\nIf execution type is sequential, phase 1 starts first and non-last phase prompts may hand off with tado-deploy. If execution type is wave, every phase must be independent, must declare owned scope and out-of-scope areas in its prompt, must set nextPhaseFile to null, and must end with the lock-based Wave completion protocol that wakes this architect for review only once. Do not spawn phase workers yourself."
    )
}

fn dispatch_agent_flags(project_root: &str, agent: &str, engine: &str) -> Result<Vec<String>> {
    let agent_root = match engine {
        "claude" => ".claude",
        "codex" => ".codex",
        _ => return Ok(Vec::new()),
    };
    let path = PathBuf::from(project_root)
        .join(agent_root)
        .join("agents")
        .join(format!("{agent}.md"));
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Ok(Vec::new());
    };
    let frontmatter = parse_frontmatter_fields(&text);
    match engine {
        "claude" => claude_agent_flags(&frontmatter),
        "codex" => codex_agent_flags(&frontmatter),
        _ => Ok(Vec::new()),
    }
}

fn claude_agent_flags(frontmatter: &HashMap<String, String>) -> Result<Vec<String>> {
    let mut flags = Vec::new();
    if let Some(model) = frontmatter
        .get("model")
        .and_then(|value| claude_model_id(value))
    {
        flags.extend(["--model".to_string(), model.to_string()]);
    }
    if let Some(effort) = frontmatter
        .get("effort")
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| matches!(value.as_str(), "low" | "medium" | "high" | "max"))
    {
        flags.extend(["--effort".to_string(), effort]);
    }
    Ok(flags)
}

fn codex_agent_flags(frontmatter: &HashMap<String, String>) -> Result<Vec<String>> {
    let mut flags = Vec::new();
    if let Some(model) = frontmatter
        .get("model")
        .and_then(|value| codex_model_id(value))
    {
        flags.extend(["-c".to_string(), format!("model=\"{model}\"")]);
    }
    if let Some(effort) = frontmatter
        .get("effort")
        .and_then(|value| codex_effort_id(value))
    {
        flags.extend([
            "-c".to_string(),
            format!("model_reasoning_effort=\"{effort}\""),
        ]);
    }
    Ok(flags)
}

fn parse_frontmatter_fields(text: &str) -> HashMap<String, String> {
    let mut fields = HashMap::new();
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some("---") {
        return fields;
    }
    for line in lines {
        let trimmed = line.trim();
        if trimmed == "---" {
            break;
        }
        if let Some((key, value)) = trimmed.split_once(':') {
            fields.insert(key.trim().to_string(), clean_frontmatter_value(value));
        }
    }
    fields
}

fn clean_frontmatter_value(value: &str) -> String {
    value
        .split_once(" #")
        .map(|(left, _)| left)
        .unwrap_or(value)
        .trim()
        .trim_matches('"')
        .to_string()
}

fn claude_model_id(short: &str) -> Option<&'static str> {
    match short.trim().to_ascii_lowercase().as_str() {
        "haiku" | "haiku45" | "haiku-4-5" | "haiku4.5" => Some("claude-haiku-4-5"),
        "sonnet" | "sonnet46" | "sonnet-4-6" | "sonnet4.6" => Some("claude-sonnet-4-6"),
        "opus" | "opus47" | "opus-4-7" | "opus4.7" => Some("claude-opus-4-7"),
        _ => None,
    }
}

fn codex_model_id(short: &str) -> Option<&'static str> {
    match short.trim().to_ascii_lowercase().as_str() {
        "gpt-5.5" | "5.5" => Some("gpt-5.5"),
        "gpt-5.4" | "5.4" => Some("gpt-5.4"),
        "gpt-5.4-mini" | "5.4-mini" | "mini" => Some("gpt-5.4-mini"),
        "gpt-5.3-codex" | "5.3-codex" | "codex" => Some("gpt-5.3-codex"),
        "gpt-5.2" | "5.2" => Some("gpt-5.2"),
        _ => None,
    }
}

fn codex_effort_id(value: &str) -> Option<&'static str> {
    match value.trim().to_ascii_lowercase().as_str() {
        "low" => Some("low"),
        "medium" => Some("medium"),
        "high" => Some("high"),
        "max" | "xhigh" => Some("xhigh"),
        _ => None,
    }
}

fn normalized_dispatch_engine(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "codex" => "codex".to_string(),
        "shell" => "shell".to_string(),
        "raw" => "raw".to_string(),
        _ => "claude".to_string(),
    }
}

fn workflow_crafted_text(
    kind: &str,
    feature: &str,
    task: &str,
    mode: Option<&str>,
    layout: Option<&str>,
) -> String {
    let execution_line = if kind == "dispatch" {
        format!(
            "Execution type: {}\nLayout: {}\n",
            normalized_dispatch_execution_type(mode),
            normalized_dispatch_layout(layout)
        )
    } else {
        format!("Mode: {}\n", mode.unwrap_or("default"))
    };
    format!(
        "# Tado {kind} Runtime Plan\n\nFeature: {feature}\n{execution_line}\nTask:\n{task}\n\nRuntime behavior:\n- This run is owned by `tadod` for the active CLI profile.\n- Dispatch Wave accepts spawn every phase JSON under `.tado/dispatch/runs/<run-id>/phases/` at once.\n- There are no watchdogs, hidden retries, or synthetic timeouts.\n"
    )
}

fn workflow_spawn_payload(
    engine: &str,
    prompt: &str,
    title: &str,
    project_id: Option<&str>,
    project_root: Option<&str>,
    agent_name: &str,
) -> Value {
    workflow_spawn_payload_with_env(
        engine,
        prompt,
        title,
        project_id,
        project_root,
        agent_name,
        Vec::new(),
        Vec::new(),
    )
}

fn workflow_spawn_payload_with_env(
    engine: &str,
    prompt: &str,
    title: &str,
    project_id: Option<&str>,
    project_root: Option<&str>,
    agent_name: &str,
    env: Vec<(String, String)>,
    flags: Vec<String>,
) -> Value {
    if engine == "shell" {
        json!({
            "engine": "shell",
            "command": format!("printf '%s\\n' {}", crate::spawn::shell_escape(prompt)),
            "title": title,
            "cwd": project_root,
            "project_id": project_id,
            "project_root": project_root,
            "agent_name": agent_name,
            "env": env,
            "flags": flags,
        })
    } else {
        json!({
            "engine": engine,
            "prompt": prompt,
            "command": prompt,
            "title": title,
            "cwd": project_root,
            "project_id": project_id,
            "project_root": project_root,
            "agent_name": agent_name,
            "env": env,
            "flags": flags,
        })
    }
}

fn snapshot_text(session: &Session) -> String {
    let scroll = session.scrollback_snapshot(0, 200);
    let mut lines = cells_to_lines(scroll.cols, &scroll.cells);
    let snapshot = session.snapshot_full();
    lines.extend(cells_to_lines(snapshot.cols, &snapshot.cells));
    trim_blank_edges(lines).join("\n")
}

fn start_transcript_writer(
    db_path: std::path::PathBuf,
    session_id: String,
    rx: mpsc::Receiver<Vec<u8>>,
    sessions: Arc<Mutex<HashMap<String, LiveSession>>>,
    advisor_links: Arc<Mutex<HashMap<String, AdvisorLink>>>,
) {
    thread::spawn(move || {
        let Ok(db) = RuntimeDb::open(&db_path) else {
            return;
        };
        let mut pending = String::new();
        loop {
            match rx.recv_timeout(std::time::Duration::from_millis(1_200)) {
                Ok(bytes) => {
                    if bytes.is_empty() {
                        continue;
                    }
                    let chunk = String::from_utf8_lossy(&bytes).to_string();
                    let _ = db.append_transcript(&session_id, "stdout", &chunk);
                    pending.push_str(&chunk);
                    if pending.len() >= 4_000 {
                        relay_advisor_output(
                            &db,
                            &session_id,
                            "idle",
                            &pending,
                            &sessions,
                            &advisor_links,
                        );
                        pending.clear();
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if !pending.is_empty() {
                        relay_advisor_output(
                            &db,
                            &session_id,
                            "idle",
                            &pending,
                            &sessions,
                            &advisor_links,
                        );
                        pending.clear();
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    relay_advisor_output(
                        &db,
                        &session_id,
                        "completed",
                        &pending,
                        &sessions,
                        &advisor_links,
                    );
                    break;
                }
            }
        }
    });
}

fn relay_advisor_output(
    db: &RuntimeDb,
    executioner_id: &str,
    status: &str,
    output: &str,
    sessions: &Arc<Mutex<HashMap<String, LiveSession>>>,
    advisor_links: &Arc<Mutex<HashMap<String, AdvisorLink>>>,
) {
    let compact = compact_advisor_tail(output, 2_800, 80);
    let body = if compact.trim().is_empty() {
        "(no visible output)".to_string()
    } else {
        compact
    };
    let message = format!(
        "[advisor-relay]\nexecutioner: {executioner_id}\nstatus: {status}\noutput:\n{body}"
    );
    let advisor_id = {
        let mut links = advisor_links.lock().unwrap();
        let Some(link) = links.get_mut(executioner_id) else {
            return;
        };
        if link.last_message == message {
            return;
        }
        link.last_message = message.clone();
        link.advisor_id.clone()
    };
    let Some(live) = sessions.lock().unwrap().get(&advisor_id).cloned() else {
        return;
    };
    let mut bytes = message.as_bytes().to_vec();
    bytes.push(b'\n');
    if live.session.write(&bytes).is_ok() {
        let _ = db.append_transcript(&advisor_id, "advisor-relay", &message);
        let _ = db.append_event(
            "advisor.relayed",
            Some(executioner_id),
            "executioner output relayed to advisor",
            Some(&json!({
                "advisor_id": advisor_id,
                "status": status,
                "chars": message.len(),
            })),
        );
    }
}

fn compact_advisor_tail(text: &str, max_chars: usize, max_lines: usize) -> String {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut lines = normalized
        .split('\n')
        .map(str::to_string)
        .collect::<Vec<_>>();
    while lines
        .first()
        .map(|line| line.trim().is_empty())
        .unwrap_or(false)
    {
        lines.remove(0);
    }
    while lines
        .last()
        .map(|line| line.trim().is_empty())
        .unwrap_or(false)
    {
        lines.pop();
    }
    if lines.len() > max_lines {
        lines = lines[lines.len() - max_lines..].to_vec();
        lines.insert(0, "[clipped earlier lines]".to_string());
    }
    let mut out = lines.join("\n");
    if out.chars().count() > max_chars {
        let suffix = out
            .chars()
            .rev()
            .take(max_chars)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect::<String>();
        out = format!("[clipped earlier output]\n{suffix}");
    }
    out
}

fn cells_to_lines(cols: u16, cells: &[tado_core::grid::Cell]) -> Vec<String> {
    if cols == 0 {
        return Vec::new();
    }
    cells
        .chunks(cols as usize)
        .map(|row| {
            row.iter()
                .filter_map(|cell| char::from_u32(cell.ch).or(Some(' ')))
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect()
}

fn trim_blank_edges(mut lines: Vec<String>) -> Vec<String> {
    while lines.first().map(|s| s.trim().is_empty()).unwrap_or(false) {
        lines.remove(0);
    }
    while lines.last().map(|s| s.trim().is_empty()).unwrap_or(false) {
        lines.pop();
    }
    lines
}

fn lane_for_status(status: &str) -> &'static str {
    match status.replace([' ', '_'], "").to_ascii_lowercase().as_str() {
        "needsinput" | "awaitingresponse" | "awaitingreview" => "needs-input",
        "running" | "dispatching" => "running",
        "waiting" => "waiting",
        "queued" | "pending" | "planning" | "drafted" | "ready" => "queued",
        "done" | "stopped" | "killed" | "exited" => "done",
        _ => "waiting",
    }
}

#[allow(dead_code)]
fn path_exists(path: &str) -> bool {
    Path::new(path).exists()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[test]
    fn expands_named_user_folders_from_home() {
        let _guard = env_lock().lock().unwrap_or_else(|err| err.into_inner());
        let home = tempfile::tempdir().unwrap();
        std::env::set_var("HOME", home.path());

        assert_eq!(
            expand_path("documents/gg").unwrap(),
            home.path().join("Documents").join("gg")
        );
        assert_eq!(
            expand_path("Downloads/demo").unwrap(),
            home.path().join("Downloads").join("demo")
        );
    }

    #[test]
    fn bare_relative_paths_are_home_relative() {
        let _guard = env_lock().lock().unwrap_or_else(|err| err.into_inner());
        let home = tempfile::tempdir().unwrap();
        std::env::set_var("HOME", home.path());

        assert_eq!(
            expand_path("my-project").unwrap(),
            home.path().join("my-project")
        );
    }

    #[test]
    fn dot_relative_paths_stay_cwd_relative() {
        let _guard = env_lock().lock().unwrap_or_else(|err| err.into_inner());
        let home = tempfile::tempdir().unwrap();
        let cwd = tempfile::tempdir().unwrap();
        std::env::set_var("HOME", home.path());
        let previous = std::env::current_dir().unwrap();
        std::env::set_current_dir(cwd.path()).unwrap();
        let resolved_cwd = std::env::current_dir().unwrap();

        assert_eq!(expand_path("./local").unwrap(), resolved_cwd.join("local"));

        std::env::set_current_dir(previous).unwrap();
    }

    #[test]
    fn dispatch_agent_flags_reads_claude_frontmatter() {
        let root = tempfile::tempdir().unwrap();
        let agents_dir = root.path().join(".claude").join("agents");
        std::fs::create_dir_all(&agents_dir).unwrap();
        std::fs::write(
            agents_dir.join("phase-one.md"),
            "---\nmodel: sonnet # route\n effort: max\n---\n",
        )
        .unwrap();

        assert_eq!(
            dispatch_agent_flags(root.path().to_str().unwrap(), "phase-one", "claude").unwrap(),
            vec![
                "--model".to_string(),
                "claude-sonnet-4-6".to_string(),
                "--effort".to_string(),
                "max".to_string(),
            ]
        );
    }

    #[test]
    fn dispatch_agent_flags_reads_codex_frontmatter() {
        let root = tempfile::tempdir().unwrap();
        let agents_dir = root.path().join(".codex").join("agents");
        std::fs::create_dir_all(&agents_dir).unwrap();
        std::fs::write(
            agents_dir.join("phase-two.md"),
            "---\nmodel: gpt-5.4-mini\neffort: max\n---\n",
        )
        .unwrap();

        assert_eq!(
            dispatch_agent_flags(root.path().to_str().unwrap(), "phase-two", "codex").unwrap(),
            vec![
                "-c".to_string(),
                "model=\"gpt-5.4-mini\"".to_string(),
                "-c".to_string(),
                "model_reasoning_effort=\"xhigh\"".to_string(),
            ]
        );
    }

    #[test]
    fn advisor_compact_tail_caps_lines_and_chars() {
        let text = (0..120)
            .map(|n| format!("line-{n:03}"))
            .collect::<Vec<_>>()
            .join("\n");
        let compact = compact_advisor_tail(&text, 80, 5);
        assert!(compact.contains("[clipped earlier lines]"));
        assert!(compact.contains("line-119"));
        assert!(!compact.contains("line-000"));

        let long = "x".repeat(120);
        let clipped = compact_advisor_tail(&long, 20, 80);
        assert!(clipped.starts_with("[clipped earlier output]\n"));
        assert!(clipped.len() <= "[clipped earlier output]\n".len() + 20);
    }
}
