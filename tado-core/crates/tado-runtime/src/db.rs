use std::path::Path;

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

pub const LATEST_SCHEMA_VERSION: i64 = 5;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionRecord {
    pub id: String,
    pub title: String,
    pub kind: String,
    pub status: String,
    pub engine: Option<String>,
    pub command: String,
    pub args: Vec<String>,
    pub cwd: Option<String>,
    pub project_id: Option<String>,
    pub project_root: Option<String>,
    pub agent_name: Option<String>,
    pub team_name: Option<String>,
    pub grid_row: Option<i64>,
    pub grid_col: Option<i64>,
    pub pid: Option<u32>,
    pub created_at: String,
    pub updated_at: String,
    pub exit_code: Option<i32>,
    pub cowork_result_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowRecord {
    pub id: String,
    pub kind: String,
    pub project: Option<String>,
    pub feature: String,
    pub task: String,
    pub mode: Option<String>,
    pub layout: Option<String>,
    pub engine: Option<String>,
    pub state: String,
    pub coordinator_todo_id: Option<String>,
    pub label: Option<String>,
    pub crafted: Option<String>,
    pub note: Option<String>,
    pub reason: Option<String>,
    pub architect_session_id: Option<String>,
    pub worker_session_id: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectRecord {
    pub id: String,
    pub name: String,
    pub root: String,
    pub created_at: String,
    pub updated_at: String,
}

pub struct RuntimeDb {
    conn: Connection,
}

impl RuntimeDb {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create runtime db dir {}", parent.display()))?;
        }
        let conn = Connection::open(path)
            .with_context(|| format!("open runtime sqlite {}", path.display()))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        let db = Self { conn };
        db.migrate()?;
        Ok(db)
    }

    pub fn runtime_id(&self) -> Result<String> {
        if let Some(existing) = self.meta("runtime_id")? {
            return Ok(existing);
        }
        let id = Uuid::new_v4().to_string();
        self.set_meta("runtime_id", &id)?;
        Ok(id)
    }

    pub fn schema_version(&self) -> Result<i64> {
        Ok(self
            .meta("schema_version")?
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0))
    }

    pub fn migrate(&self) -> Result<()> {
        self.conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'pty',
                status TEXT NOT NULL,
                engine TEXT,
                command TEXT NOT NULL,
                args_json TEXT NOT NULL DEFAULT '[]',
                cwd TEXT,
                project_id TEXT,
                project_root TEXT,
                agent_name TEXT,
                team_name TEXT,
                grid_row INTEGER,
                grid_col INTEGER,
                pid INTEGER,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                exit_code INTEGER,
                cowork_result_path TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
            CREATE INDEX IF NOT EXISTS idx_sessions_project_root ON sessions(project_root);

            CREATE TABLE IF NOT EXISTS transcript_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                stream TEXT NOT NULL,
                chunk TEXT NOT NULL,
                created_at TEXT NOT NULL,
                cursor INTEGER NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_transcript_session_cursor
                ON transcript_chunks(session_id, cursor);
            CREATE INDEX IF NOT EXISTS idx_transcript_chunk
                ON transcript_chunks(chunk);

            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                subject_id TEXT,
                message TEXT NOT NULL,
                payload_json TEXT,
                created_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at);

            CREATE TABLE IF NOT EXISTS kanban_columns (
                column_key TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                lane_kind TEXT NOT NULL,
                order_index INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS kanban_cards (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                lane_key TEXT NOT NULL,
                session_id TEXT,
                agent TEXT,
                team TEXT,
                order_index INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS workflows (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                project TEXT,
                feature TEXT NOT NULL,
                task TEXT NOT NULL,
                mode TEXT,
                layout TEXT,
                engine TEXT,
                state TEXT NOT NULL,
                coordinator_todo_id TEXT,
                label TEXT,
                crafted TEXT,
                note TEXT,
                reason TEXT,
                architect_session_id TEXT,
                worker_session_id TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_workflows_kind_state ON workflows(kind, state);
            CREATE INDEX IF NOT EXISTS idx_workflows_project ON workflows(project);

            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                root TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_projects_name ON projects(name);
            ",
        )?;
        self.ensure_column("sessions", "agent_name", "TEXT")?;
        self.ensure_column("sessions", "team_name", "TEXT")?;
        self.ensure_column("sessions", "grid_row", "INTEGER")?;
        self.ensure_column("sessions", "grid_col", "INTEGER")?;
        self.ensure_column("workflows", "layout", "TEXT")?;
        self.seed_lanes()?;
        self.set_meta("schema_version", &LATEST_SCHEMA_VERSION.to_string())?;
        Ok(())
    }

    pub fn insert_session(&self, record: &SessionRecord) -> Result<()> {
        self.conn.execute(
            "
            INSERT INTO sessions
                (id, title, kind, status, engine, command, args_json, cwd,
                 project_id, project_root, agent_name, team_name, grid_row,
                 grid_col, pid, created_at, updated_at, exit_code,
                 cowork_result_path)
            VALUES
                (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                kind = excluded.kind,
                status = excluded.status,
                engine = excluded.engine,
                command = excluded.command,
                args_json = excluded.args_json,
                cwd = excluded.cwd,
                project_id = excluded.project_id,
                project_root = excluded.project_root,
                agent_name = excluded.agent_name,
                team_name = excluded.team_name,
                grid_row = excluded.grid_row,
                grid_col = excluded.grid_col,
                pid = excluded.pid,
                updated_at = excluded.updated_at,
                exit_code = excluded.exit_code,
                cowork_result_path = excluded.cowork_result_path
            ",
            params![
                record.id,
                record.title,
                record.kind,
                record.status,
                record.engine,
                record.command,
                serde_json::to_string(&record.args)?,
                record.cwd,
                record.project_id,
                record.project_root,
                record.agent_name,
                record.team_name,
                record.grid_row,
                record.grid_col,
                record.pid.map(|v| v as i64),
                record.created_at,
                record.updated_at,
                record.exit_code,
                record.cowork_result_path,
            ],
        )?;
        Ok(())
    }

    pub fn update_session_status(
        &self,
        id: &str,
        status: &str,
        exit_code: Option<i32>,
    ) -> Result<()> {
        self.conn.execute(
            "UPDATE sessions SET status = ?2, exit_code = ?3, updated_at = ?4 WHERE id = ?1",
            params![id, status, exit_code, Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub fn list_sessions(&self) -> Result<Vec<SessionRecord>> {
        let mut stmt = self.conn.prepare(
            "
            SELECT id, title, kind, status, engine, command, args_json, cwd,
                   project_id, project_root, agent_name, team_name, grid_row,
                   grid_col, pid, created_at, updated_at, exit_code,
                   cowork_result_path
            FROM sessions
            ORDER BY datetime(created_at) DESC
            ",
        )?;
        let rows = stmt.query_map([], row_to_session)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn get_session(&self, id: &str) -> Result<Option<SessionRecord>> {
        self.conn
            .query_row(
                "
                SELECT id, title, kind, status, engine, command, args_json, cwd,
                       project_id, project_root, agent_name, team_name, grid_row,
                       grid_col, pid, created_at, updated_at, exit_code,
                       cowork_result_path
                FROM sessions
                WHERE id = ?1
                ",
                params![id],
                row_to_session,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn delete_session(&self, id: &str) -> Result<bool> {
        self.conn.execute(
            "DELETE FROM transcript_chunks WHERE session_id = ?1",
            params![id],
        )?;
        self.conn.execute(
            "DELETE FROM kanban_cards WHERE session_id = ?1 OR id = ?1",
            params![id],
        )?;
        let deleted = self
            .conn
            .execute("DELETE FROM sessions WHERE id = ?1", params![id])?;
        Ok(deleted > 0)
    }

    pub fn append_transcript(&self, session_id: &str, stream: &str, chunk: &str) -> Result<i64> {
        let cursor: i64 = self.conn.query_row(
            "SELECT COALESCE(MAX(cursor), 0) + 1 FROM transcript_chunks WHERE session_id = ?1",
            params![session_id],
            |row| row.get(0),
        )?;
        self.conn.execute(
            "
            INSERT INTO transcript_chunks(session_id, stream, chunk, created_at, cursor)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ",
            params![session_id, stream, chunk, Utc::now().to_rfc3339(), cursor],
        )?;
        Ok(cursor)
    }

    pub fn transcript_tail(
        &self,
        session_id: &str,
        limit: usize,
    ) -> Result<Vec<(i64, String, String, String)>> {
        let mut stmt = self.conn.prepare(
            "
            SELECT cursor, stream, chunk, created_at
            FROM transcript_chunks
            WHERE session_id = ?1
            ORDER BY cursor DESC
            LIMIT ?2
            ",
        )?;
        let rows = stmt.query_map(params![session_id, limit as i64], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        out.reverse();
        Ok(out)
    }

    pub fn transcript_after(
        &self,
        session_id: &str,
        after_cursor: i64,
        limit: usize,
    ) -> Result<Vec<(i64, String, String, String)>> {
        let mut stmt = self.conn.prepare(
            "
            SELECT cursor, stream, chunk, created_at
            FROM transcript_chunks
            WHERE session_id = ?1 AND cursor > ?2
            ORDER BY cursor ASC
            LIMIT ?3
            ",
        )?;
        let rows = stmt.query_map(params![session_id, after_cursor, limit as i64], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn search_transcripts(&self, query: &str, limit: usize) -> Result<Vec<Value>> {
        let like = format!("%{}%", query.replace('%', "\\%").replace('_', "\\_"));
        let mut stmt = self.conn.prepare(
            "
            SELECT t.session_id, s.title, t.cursor, t.stream, t.chunk, t.created_at
            FROM transcript_chunks t
            LEFT JOIN sessions s ON s.id = t.session_id
            WHERE t.chunk LIKE ?1 ESCAPE '\\'
            ORDER BY t.id DESC
            LIMIT ?2
            ",
        )?;
        let rows = stmt.query_map(params![like, limit as i64], |row| {
            Ok(serde_json::json!({
                "session_id": row.get::<_, String>(0)?,
                "title": row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                "cursor": row.get::<_, i64>(2)?,
                "stream": row.get::<_, String>(3)?,
                "chunk": row.get::<_, String>(4)?,
                "created_at": row.get::<_, String>(5)?,
            }))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn append_event(
        &self,
        kind: &str,
        subject_id: Option<&str>,
        message: &str,
        payload: Option<&Value>,
    ) -> Result<i64> {
        self.conn.execute(
            "
            INSERT INTO events(kind, subject_id, message, payload_json, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ",
            params![
                kind,
                subject_id,
                message,
                payload.map(|v| v.to_string()),
                Utc::now().to_rfc3339()
            ],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn list_events(&self, limit: usize) -> Result<Vec<Value>> {
        let mut stmt = self.conn.prepare(
            "
            SELECT id, kind, subject_id, message, payload_json, created_at
            FROM events
            ORDER BY id DESC
            LIMIT ?1
            ",
        )?;
        let rows = stmt.query_map(params![limit as i64], |row| {
            let payload_raw: Option<String> = row.get(4)?;
            Ok(serde_json::json!({
                "id": row.get::<_, i64>(0)?,
                "kind": row.get::<_, String>(1)?,
                "subject_id": row.get::<_, Option<String>>(2)?,
                "message": row.get::<_, String>(3)?,
                "payload": payload_raw
                    .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
                    .unwrap_or(Value::Null),
                "created_at": row.get::<_, String>(5)?,
            }))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        out.reverse();
        Ok(out)
    }

    pub fn list_events_after(&self, after_id: i64, limit: usize) -> Result<Vec<Value>> {
        let mut stmt = self.conn.prepare(
            "
            SELECT id, kind, subject_id, message, payload_json, created_at
            FROM events
            WHERE id > ?1
            ORDER BY id ASC
            LIMIT ?2
            ",
        )?;
        let rows = stmt.query_map(params![after_id, limit as i64], |row| {
            let payload_raw: Option<String> = row.get(4)?;
            Ok(serde_json::json!({
                "id": row.get::<_, i64>(0)?,
                "kind": row.get::<_, String>(1)?,
                "subject_id": row.get::<_, Option<String>>(2)?,
                "message": row.get::<_, String>(3)?,
                "payload": payload_raw
                    .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
                    .unwrap_or(Value::Null),
                "created_at": row.get::<_, String>(5)?,
            }))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn kanban_columns(&self) -> Result<Vec<Value>> {
        let mut stmt = self.conn.prepare(
            "
            SELECT column_key, title, lane_kind, order_index
            FROM kanban_columns
            ORDER BY order_index ASC
            ",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(serde_json::json!({
                "key": row.get::<_, String>(0)?,
                "title": row.get::<_, String>(1)?,
                "kind": row.get::<_, String>(2)?,
                "order": row.get::<_, i64>(3)?,
            }))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn add_kanban_column(&self, key: &str, title: &str, lane_kind: &str) -> Result<()> {
        let order: i64 = self.conn.query_row(
            "SELECT COALESCE(MAX(order_index), -1) + 1 FROM kanban_columns",
            [],
            |row| row.get(0),
        )?;
        self.conn.execute(
            "
            INSERT INTO kanban_columns(column_key, title, lane_kind, order_index)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(column_key) DO UPDATE SET
                title = excluded.title,
                lane_kind = excluded.lane_kind
            ",
            params![key, title, lane_kind, order],
        )?;
        Ok(())
    }

    pub fn move_kanban_card(&self, session: &SessionRecord, lane_key: &str) -> Result<()> {
        self.conn.execute(
            "
            INSERT INTO kanban_cards(id, title, lane_key, session_id, agent, team, order_index, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7, ?7)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                lane_key = excluded.lane_key,
                session_id = excluded.session_id,
                agent = excluded.agent,
                team = excluded.team,
                updated_at = excluded.updated_at
            ",
            params![
                &session.id,
                &session.title,
                lane_key,
                &session.id,
                &session.agent_name,
                &session.team_name,
                Utc::now().to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub fn kanban_card_lanes(&self) -> Result<std::collections::HashMap<String, String>> {
        let mut stmt = self.conn.prepare(
            "SELECT session_id, lane_key FROM kanban_cards WHERE session_id IS NOT NULL",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        let mut out = std::collections::HashMap::new();
        for row in rows {
            let (session_id, lane_key) = row?;
            out.insert(session_id, lane_key);
        }
        Ok(out)
    }

    pub fn next_grid_position(&self) -> Result<(i64, i64)> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM sessions", [], |row| row.get(0))?;
        Ok((count / 4 + 1, count % 4 + 1))
    }

    pub fn upsert_project(&self, name: &str, root: &str) -> Result<ProjectRecord> {
        let now = Utc::now().to_rfc3339();
        let existing: Option<(String, String)> = self
            .conn
            .query_row(
                "SELECT id, created_at FROM projects WHERE root = ?1",
                params![root],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let (id, created_at) =
            existing.unwrap_or_else(|| (Uuid::new_v4().to_string(), now.clone()));
        self.conn.execute(
            "
            INSERT INTO projects(id, name, root, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(root) DO UPDATE SET
                name = excluded.name,
                updated_at = excluded.updated_at
            ",
            params![id, name, root, created_at, now],
        )?;
        self.get_project(&id)?
            .ok_or_else(|| anyhow::anyhow!("project was not saved"))
    }

    pub fn list_projects(&self) -> Result<Vec<ProjectRecord>> {
        let mut stmt = self.conn.prepare(
            "
            SELECT id, name, root, created_at, updated_at
            FROM projects
            ORDER BY lower(name), root
            ",
        )?;
        let rows = stmt.query_map([], row_to_project)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn get_project(&self, id: &str) -> Result<Option<ProjectRecord>> {
        self.conn
            .query_row(
                "
                SELECT id, name, root, created_at, updated_at
                FROM projects
                WHERE id = ?1 OR name = ?1 OR root = ?1
                ",
                params![id],
                row_to_project,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn resolve_project(&self, target: &str) -> Result<Option<ProjectRecord>> {
        if let Some(project) = self.get_project(target)? {
            return Ok(Some(project));
        }
        let like = format!("%{}%", target.replace('%', "\\%").replace('_', "\\_"));
        self.conn
            .query_row(
                "
                SELECT id, name, root, created_at, updated_at
                FROM projects
                WHERE name LIKE ?1 ESCAPE '\\' OR root LIKE ?1 ESCAPE '\\'
                ORDER BY length(name), lower(name)
                LIMIT 1
                ",
                params![like],
                row_to_project,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn set_active_project(&self, id: &str) -> Result<()> {
        self.set_meta("active_project_id", id)
    }

    pub fn active_project(&self) -> Result<Option<ProjectRecord>> {
        let Some(id) = self.meta("active_project_id")? else {
            return Ok(None);
        };
        self.get_project(&id)
    }

    pub fn insert_workflow(&self, record: &WorkflowRecord) -> Result<()> {
        self.conn.execute(
            "
            INSERT INTO workflows
                (id, kind, project, feature, task, mode, layout, engine, state,
                 coordinator_todo_id, label, crafted, note, reason,
                 architect_session_id, worker_session_id, created_at, updated_at)
            VALUES
                (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
            ON CONFLICT(id) DO UPDATE SET
                project = excluded.project,
                feature = excluded.feature,
                task = excluded.task,
                mode = excluded.mode,
                layout = excluded.layout,
                engine = excluded.engine,
                state = excluded.state,
                coordinator_todo_id = excluded.coordinator_todo_id,
                label = excluded.label,
                crafted = excluded.crafted,
                note = excluded.note,
                reason = excluded.reason,
                architect_session_id = excluded.architect_session_id,
                worker_session_id = excluded.worker_session_id,
                updated_at = excluded.updated_at
            ",
            params![
                record.id,
                record.kind,
                record.project,
                record.feature,
                record.task,
                record.mode,
                record.layout,
                record.engine,
                record.state,
                record.coordinator_todo_id,
                record.label,
                record.crafted,
                record.note,
                record.reason,
                record.architect_session_id,
                record.worker_session_id,
                record.created_at,
                record.updated_at,
            ],
        )?;
        Ok(())
    }

    pub fn get_workflow(&self, id: &str) -> Result<Option<WorkflowRecord>> {
        self.conn
            .query_row(
                "
                SELECT id, kind, project, feature, task, mode, layout, engine, state,
                       coordinator_todo_id, label, crafted, note, reason,
                       architect_session_id, worker_session_id, created_at, updated_at
                FROM workflows
                WHERE id = ?1
                ",
                params![id],
                row_to_workflow,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn list_workflows(
        &self,
        kind: &str,
        project: Option<&str>,
        state: Option<&str>,
    ) -> Result<Vec<WorkflowRecord>> {
        let mut records = Vec::new();
        let mut stmt = self.conn.prepare(
            "
            SELECT id, kind, project, feature, task, mode, layout, engine, state,
                   coordinator_todo_id, label, crafted, note, reason,
                   architect_session_id, worker_session_id, created_at, updated_at
            FROM workflows
            WHERE kind = ?1
            ORDER BY datetime(created_at) DESC
            ",
        )?;
        let rows = stmt.query_map(params![kind], row_to_workflow)?;
        for row in rows {
            let record = row?;
            if let Some(project) = project {
                if record.project.as_deref() != Some(project) {
                    continue;
                }
            }
            if let Some(state) = state {
                if record.state != state {
                    continue;
                }
            }
            records.push(record);
        }
        Ok(records)
    }

    pub fn update_workflow(
        &self,
        id: &str,
        state: &str,
        crafted: Option<&str>,
        note: Option<&str>,
        reason: Option<&str>,
        architect_session_id: Option<&str>,
        worker_session_id: Option<&str>,
    ) -> Result<()> {
        self.conn.execute(
            "
            UPDATE workflows SET
                state = ?2,
                crafted = COALESCE(?3, crafted),
                note = COALESCE(?4, note),
                reason = COALESCE(?5, reason),
                architect_session_id = COALESCE(?6, architect_session_id),
                worker_session_id = COALESCE(?7, worker_session_id),
                updated_at = ?8
            WHERE id = ?1
            ",
            params![
                id,
                state,
                crafted,
                note,
                reason,
                architect_session_id,
                worker_session_id,
                Utc::now().to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub fn meta(&self, key: &str) -> Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT value FROM meta WHERE key = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn set_meta(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    fn ensure_column(&self, table: &str, column: &str, ddl: &str) -> Result<()> {
        let mut stmt = self.conn.prepare(&format!("PRAGMA table_info({table})"))?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
        for row in rows {
            if row? == column {
                return Ok(());
            }
        }
        self.conn.execute(
            &format!("ALTER TABLE {table} ADD COLUMN {column} {ddl}"),
            [],
        )?;
        Ok(())
    }

    fn seed_lanes(&self) -> Result<()> {
        let lanes = [
            ("needs-input", "Needs Input", "needs_input", 0),
            ("running", "Running", "running", 1),
            ("waiting", "Waiting", "waiting", 2),
            ("queued", "Queued", "queued", 3),
            ("done", "Done", "done", 4),
        ];
        for (key, title, kind, order) in lanes {
            self.conn.execute(
                "
                INSERT INTO kanban_columns(column_key, title, lane_kind, order_index)
                VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT(column_key) DO NOTHING
                ",
                params![key, title, kind, order],
            )?;
        }
        Ok(())
    }
}

fn row_to_session(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionRecord> {
    let args_json: String = row.get(6)?;
    let args = serde_json::from_str::<Vec<String>>(&args_json).unwrap_or_default();
    let pid_i64: Option<i64> = row.get(14)?;
    Ok(SessionRecord {
        id: row.get(0)?,
        title: row.get(1)?,
        kind: row.get(2)?,
        status: row.get(3)?,
        engine: row.get(4)?,
        command: row.get(5)?,
        args,
        cwd: row.get(7)?,
        project_id: row.get(8)?,
        project_root: row.get(9)?,
        agent_name: row.get(10)?,
        team_name: row.get(11)?,
        grid_row: row.get(12)?,
        grid_col: row.get(13)?,
        pid: pid_i64.map(|v| v as u32),
        created_at: row.get(15)?,
        updated_at: row.get(16)?,
        exit_code: row.get(17)?,
        cowork_result_path: row.get(18)?,
    })
}

fn row_to_workflow(row: &rusqlite::Row<'_>) -> rusqlite::Result<WorkflowRecord> {
    Ok(WorkflowRecord {
        id: row.get(0)?,
        kind: row.get(1)?,
        project: row.get(2)?,
        feature: row.get(3)?,
        task: row.get(4)?,
        mode: row.get(5)?,
        layout: row.get(6)?,
        engine: row.get(7)?,
        state: row.get(8)?,
        coordinator_todo_id: row.get(9)?,
        label: row.get(10)?,
        crafted: row.get(11)?,
        note: row.get(12)?,
        reason: row.get(13)?,
        architect_session_id: row.get(14)?,
        worker_session_id: row.get(15)?,
        created_at: row.get(16)?,
        updated_at: row.get(17)?,
    })
}

fn row_to_project(row: &rusqlite::Row<'_>) -> rusqlite::Result<ProjectRecord> {
    Ok(ProjectRecord {
        id: row.get(0)?,
        name: row.get(1)?,
        root: row.get(2)?,
        created_at: row.get(3)?,
        updated_at: row.get(4)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrations_are_idempotent_and_wal_enabled() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("runtime.sqlite");
        let db = RuntimeDb::open(&path).unwrap();
        db.migrate().unwrap();
        assert_eq!(db.schema_version().unwrap(), LATEST_SCHEMA_VERSION);
        let mode: String = db
            .conn
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .unwrap();
        assert_eq!(mode.to_ascii_lowercase(), "wal");
    }

    #[test]
    fn transcript_tail_is_cursor_ordered() {
        let dir = tempfile::tempdir().unwrap();
        let db = RuntimeDb::open(&dir.path().join("runtime.sqlite")).unwrap();
        let now = Utc::now().to_rfc3339();
        db.insert_session(&SessionRecord {
            id: "s1".into(),
            title: "test".into(),
            kind: "pty".into(),
            status: "running".into(),
            engine: Some("shell".into()),
            command: "/bin/zsh".into(),
            args: Vec::new(),
            cwd: None,
            project_id: None,
            project_root: None,
            agent_name: None,
            team_name: None,
            grid_row: None,
            grid_col: None,
            pid: None,
            created_at: now.clone(),
            updated_at: now,
            exit_code: None,
            cowork_result_path: None,
        })
        .unwrap();
        db.append_transcript("s1", "stdout", "one").unwrap();
        db.append_transcript("s1", "stdout", "two").unwrap();
        let tail = db.transcript_tail("s1", 2).unwrap();
        assert_eq!(tail[0].2, "one");
        assert_eq!(tail[1].2, "two");
        let after = db.transcript_after("s1", 1, 10).unwrap();
        assert_eq!(after.len(), 1);
        assert_eq!(after[0].2, "two");
    }

    #[test]
    fn events_can_be_read_after_cursor() {
        let dir = tempfile::tempdir().unwrap();
        let db = RuntimeDb::open(&dir.path().join("runtime.sqlite")).unwrap();
        let first = db
            .append_event("runtime.test", None, "first", None)
            .unwrap();
        db.append_event("runtime.test", None, "second", None)
            .unwrap();
        let events = db.list_events_after(first, 10).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["message"], "second");
    }

    #[test]
    fn workflow_layout_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let db = RuntimeDb::open(&dir.path().join("runtime.sqlite")).unwrap();
        let now = Utc::now().to_rfc3339();
        db.insert_workflow(&WorkflowRecord {
            id: "w1".into(),
            kind: "dispatch".into(),
            project: Some("/tmp/project".into()),
            feature: "Feature".into(),
            task: "Task".into(),
            mode: Some("wave".into()),
            layout: Some("kanban".into()),
            engine: Some("claude".into()),
            state: "drafting".into(),
            coordinator_todo_id: Some("todo".into()),
            label: Some("Label".into()),
            crafted: None,
            note: None,
            reason: None,
            architect_session_id: None,
            worker_session_id: None,
            created_at: now.clone(),
            updated_at: now,
        })
        .unwrap();

        let workflow = db.get_workflow("w1").unwrap().unwrap();
        assert_eq!(workflow.mode.as_deref(), Some("wave"));
        assert_eq!(workflow.layout.as_deref(), Some("kanban"));

        let workflows = db.list_workflows("dispatch", None, None).unwrap();
        assert_eq!(workflows[0].layout.as_deref(), Some("kanban"));
    }
}
