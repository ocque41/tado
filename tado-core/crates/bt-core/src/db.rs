use crate::error::BtError;
use crate::migrations;
use crate::model::{
    AdapterRecord, AgentContextEventRecord, AgentRecord, AuditEntry, AutomationOccurrence,
    AutomationRecord, BrandRecord, BudgetOverrideRecord, BudgetUsageEntry, ChainOfKnowledgeConfig,
    ChainOfThoughtConfig, CompanyRecord, ConfigRevision, ContextPackRecord,
    ContextPackSourceRecord, CraftingFramework, Craftship, CraftshipNode, CraftshipSession,
    CraftshipSessionNode, CraftshipTeamInboxEntry, CraftshipTeamMessage,
    CraftshipTeamMessageReceipt, CraftshipTeamWorkItem, DocMetaRecord, DocPlanHandoff, DocRecord,
    EventRecord, GoalRecord, GovernanceApproval, GraphEdgeRecord, GraphNodeRecord, PlanRecord,
    PlanRevisionRecord, RunArtifact, RunEvaluation, RunRecord, SearchResult, SharedContextRecord,
    Suggestion, Task, TaskEditHandoff, TicketDecision, TicketRecord, TicketThreadMessage,
    TicketToolTrace, WorkerCursor,
};
use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use std::path::Path;

pub fn open_db(path: &Path) -> Result<Connection, BtError> {
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    // 30 s: the craftship launch hot path fires many concurrent write
    // RPCs (token.create, run.create, bind_node_runtime, session.launch)
    // that all serialize on the WAL write lock. 5 s was insufficient
    // under contention, producing "database is locked" errors.
    conn.busy_timeout(std::time::Duration::from_secs(30))?;
    let _ = conn.pragma_update(None, "wal_autocheckpoint", 1000);
    let _ = migrations::migrate(&conn)?;
    Ok(conn)
}

fn parse_dt(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or_else(|_| Utc::now())
}

fn parse_opt_dt(value: Option<String>) -> Option<DateTime<Utc>> {
    value
        .and_then(|d| DateTime::parse_from_rfc3339(&d).ok())
        .map(|d| d.with_timezone(&Utc))
}

fn parse_json_value(raw: &str) -> Value {
    serde_json::from_str::<Value>(raw).unwrap_or(Value::Null)
}

fn parse_opt_json_value(raw: Option<String>) -> Option<Value> {
    raw.and_then(|m| serde_json::from_str(&m).ok())
}

fn parse_string_list_json(raw: Option<String>) -> Vec<String> {
    raw.and_then(|value| serde_json::from_str::<Vec<String>>(&value).ok())
        .unwrap_or_default()
}

fn default_chain_of_thought_config() -> ChainOfThoughtConfig {
    ChainOfThoughtConfig {
        autonomy_level: "balanced".to_string(),
        workflow_order: "research_plan_implement".to_string(),
        priority_focus: "core_feature_first".to_string(),
        planning_depth: "standard".to_string(),
        research_preference: "balanced".to_string(),
        set_pillar: "knowledge_notes_calendar".to_string(),
    }
}

fn default_chain_of_knowledge_config() -> ChainOfKnowledgeConfig {
    ChainOfKnowledgeConfig {
        focus_mode: "unrestricted".to_string(),
        allowed_knowledge: Vec::new(),
        blocked_knowledge: Vec::new(),
    }
}

fn parse_chain_of_thought_config(raw: &str) -> ChainOfThoughtConfig {
    serde_json::from_str::<ChainOfThoughtConfig>(raw)
        .unwrap_or_else(|_| default_chain_of_thought_config())
}

fn parse_chain_of_knowledge_config(raw: &str) -> ChainOfKnowledgeConfig {
    let parsed = serde_json::from_str::<ChainOfKnowledgeConfig>(raw)
        .unwrap_or_else(|_| default_chain_of_knowledge_config());
    normalize_chain_of_knowledge_config(parsed)
}

fn normalize_chain_of_knowledge_config(
    mut value: ChainOfKnowledgeConfig,
) -> ChainOfKnowledgeConfig {
    match value.focus_mode.as_str() {
        "allowed_only" | "focused" | "strict" => {
            value.focus_mode = "allowed_only".to_string();
            value.blocked_knowledge.clear();
        }
        "blocked_only" | "exclude_list" | "avoid_blocked" => {
            value.focus_mode = "blocked_only".to_string();
            value.allowed_knowledge.clear();
        }
        _ => {
            value.focus_mode = "unrestricted".to_string();
            value.allowed_knowledge.clear();
            value.blocked_knowledge.clear();
        }
    }
    value
}

pub fn upsert_doc(
    conn: &Connection,
    doc: &DocRecord,
    user_hash: &str,
    agent_hash: &str,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO docs(
            id, topic, slug, title, user_path, agent_path, created_at, updated_at,
            user_hash, agent_hash, owner_scope, project_id, project_root, knowledge_kind
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
        ON CONFLICT(id) DO UPDATE SET
            topic=excluded.topic,
            slug=excluded.slug,
            title=excluded.title,
            user_path=excluded.user_path,
            agent_path=excluded.agent_path,
            updated_at=excluded.updated_at,
            user_hash=excluded.user_hash,
            agent_hash=excluded.agent_hash,
            owner_scope=excluded.owner_scope,
            project_id=excluded.project_id,
            project_root=excluded.project_root,
            knowledge_kind=excluded.knowledge_kind
        "#,
        params![
            doc.id,
            doc.topic,
            doc.slug,
            doc.title,
            doc.user_path,
            doc.agent_path,
            doc.created_at.to_rfc3339(),
            doc.updated_at.to_rfc3339(),
            user_hash,
            agent_hash,
            doc.owner_scope,
            doc.project_id,
            doc.project_root,
            doc.knowledge_kind
        ],
    )?;
    Ok(())
}

pub fn update_doc_scope(
    conn: &Connection,
    doc_id: &str,
    owner_scope: &str,
    project_id: Option<&str>,
    project_root: Option<&str>,
    knowledge_kind: &str,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        UPDATE docs
        SET owner_scope = ?2,
            project_id = ?3,
            project_root = ?4,
            knowledge_kind = ?5
        WHERE id = ?1
        "#,
        params![doc_id, owner_scope, project_id, project_root, knowledge_kind],
    )?;
    Ok(())
}

pub fn upsert_doc_meta(
    conn: &Connection,
    doc_id: &str,
    tags: &[String],
    links_out: &[String],
    status: Option<&str>,
    updated_at: DateTime<Utc>,
) -> Result<(), BtError> {
    let tags_json = serde_json::to_string(tags).map_err(|e| BtError::Validation(e.to_string()))?;
    let links_json =
        serde_json::to_string(links_out).map_err(|e| BtError::Validation(e.to_string()))?;
    conn.execute(
        r#"
        INSERT INTO doc_meta(doc_id, tags_json, links_out_json, status, updated_at)
        VALUES(?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(doc_id) DO UPDATE SET
            tags_json=excluded.tags_json,
            links_out_json=excluded.links_out_json,
            status=excluded.status,
            updated_at=excluded.updated_at
        "#,
        params![
            doc_id,
            tags_json,
            links_json,
            status,
            updated_at.to_rfc3339()
        ],
    )?;
    Ok(())
}

pub fn list_doc_meta(conn: &Connection) -> Result<Vec<DocMetaRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT doc_id, tags_json, links_out_json, status, updated_at
        FROM doc_meta
        ORDER BY updated_at DESC
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        let updated: String = row.get(4)?;
        let tags_raw: String = row.get(1)?;
        let links_raw: String = row.get(2)?;
        Ok(DocMetaRecord {
            doc_id: row.get(0)?,
            tags: serde_json::from_str(&tags_raw).unwrap_or_default(),
            links_out: serde_json::from_str(&links_raw).unwrap_or_default(),
            status: row.get(3)?,
            updated_at: parse_dt(&updated),
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Cheap existence check on the docs `(topic, slug)` unique index. Used by
/// `unique_slug` to make sure we never hand out a slug that the SQL UNIQUE
/// constraint will reject. Filesystem-only checks are not authoritative
/// because the docs row can outlive its directory (orphaned by cascade
/// failures, manual deletes, or craftship-session deletes that historically
/// did not clean up the linked session doc).
pub fn doc_exists_with_topic_slug(
    conn: &Connection,
    topic: &str,
    slug: &str,
) -> Result<bool, BtError> {
    let mut stmt = conn.prepare("SELECT 1 FROM docs WHERE topic = ?1 AND slug = ?2 LIMIT 1")?;
    let exists = stmt
        .query_row(params![topic, slug], |_| Ok(()))
        .optional()?;
    Ok(exists.is_some())
}

/// Hard-delete a doc and its associated metadata/FTS rows. Returns true if
/// a row was removed. The caller is responsible for cleaning up the
/// on-disk directory if it still exists.
pub fn delete_doc_row(conn: &Connection, doc_id: &str) -> Result<bool, BtError> {
    let _ = conn.execute("DELETE FROM doc_meta WHERE doc_id = ?1", params![doc_id])?;
    let _ = conn.execute("DELETE FROM fts_notes WHERE doc_id = ?1", params![doc_id]);
    let changed = conn.execute("DELETE FROM docs WHERE id = ?1", params![doc_id])?;
    Ok(changed > 0)
}

pub fn get_doc(conn: &Connection, doc_id: &str) -> Result<Option<DocRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT id, topic, slug, title, user_path, agent_path, created_at, updated_at,
               owner_scope, project_id, project_root, knowledge_kind
        FROM docs
        WHERE id = ?1
        "#,
    )?;

    let row = stmt
        .query_row(params![doc_id], |row| {
            let created: String = row.get(6)?;
            let updated: String = row.get(7)?;
            Ok(DocRecord {
                id: row.get(0)?,
                topic: row.get(1)?,
                slug: row.get(2)?,
                title: row.get(3)?,
                user_path: row.get(4)?,
                agent_path: row.get(5)?,
                created_at: DateTime::parse_from_rfc3339(&created)
                    .map(|d| d.with_timezone(&Utc))
                    .unwrap_or_else(|_| Utc::now()),
                updated_at: DateTime::parse_from_rfc3339(&updated)
                    .map(|d| d.with_timezone(&Utc))
                    .unwrap_or_else(|_| Utc::now()),
                owner_scope: row.get(8)?,
                project_id: row.get(9)?,
                project_root: row.get(10)?,
                knowledge_kind: row.get(11)?,
            })
        })
        .optional()?;

    Ok(row)
}

pub fn list_docs(conn: &Connection, topic: Option<&str>) -> Result<Vec<DocRecord>, BtError> {
    let sql = if topic.is_some() {
        r#"
        SELECT id, topic, slug, title, user_path, agent_path, created_at, updated_at,
               owner_scope, project_id, project_root, knowledge_kind
        FROM docs
        WHERE topic = ?1
        ORDER BY updated_at DESC
        "#
    } else {
        r#"
        SELECT id, topic, slug, title, user_path, agent_path, created_at, updated_at,
               owner_scope, project_id, project_root, knowledge_kind
        FROM docs
        ORDER BY updated_at DESC
        "#
    };

    let mut stmt = conn.prepare(sql)?;
    let mut out = Vec::new();
    if let Some(topic_value) = topic {
        let rows = stmt.query_map(params![topic_value], parse_doc_row)?;
        for row in rows {
            out.push(row?);
        }
    } else {
        let rows = stmt.query_map([], parse_doc_row)?;
        for row in rows {
            out.push(row?);
        }
    }

    Ok(out)
}

fn parse_doc_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DocRecord> {
    let created: String = row.get(6)?;
    let updated: String = row.get(7)?;
    Ok(DocRecord {
        id: row.get(0)?,
        topic: row.get(1)?,
        slug: row.get(2)?,
        title: row.get(3)?,
        user_path: row.get(4)?,
        agent_path: row.get(5)?,
        created_at: DateTime::parse_from_rfc3339(&created)
            .map(|d| d.with_timezone(&Utc))
            .unwrap_or_else(|_| Utc::now()),
        updated_at: DateTime::parse_from_rfc3339(&updated)
            .map(|d| d.with_timezone(&Utc))
            .unwrap_or_else(|_| Utc::now()),
        owner_scope: row.get(8)?,
        project_id: row.get(9)?,
        project_root: row.get(10)?,
        knowledge_kind: row.get(11)?,
    })
}

pub fn update_doc_identifiers(
    conn: &Connection,
    doc_id: &str,
    topic: &str,
    slug: &str,
    title: &str,
    user_path: &str,
    agent_path: &str,
    updated_at: DateTime<Utc>,
) -> Result<(), BtError> {
    conn.execute(
        "UPDATE docs SET topic=?2, slug=?3, title=?4, user_path=?5, agent_path=?6, updated_at=?7 WHERE id=?1",
        params![doc_id, topic, slug, title, user_path, agent_path, updated_at.to_rfc3339()],
    )?;
    Ok(())
}

pub fn update_doc_title(
    conn: &Connection,
    doc_id: &str,
    title: &str,
    updated_at: DateTime<Utc>,
) -> Result<(), BtError> {
    conn.execute(
        "UPDATE docs SET title=?2, updated_at=?3 WHERE id=?1",
        params![doc_id, title, updated_at.to_rfc3339()],
    )?;
    Ok(())
}

pub fn refresh_fts(
    conn: &Connection,
    doc_id: &str,
    user_content: &str,
    agent_content: &str,
) -> Result<(), BtError> {
    conn.execute("DELETE FROM fts_notes WHERE doc_id = ?1", params![doc_id])?;
    conn.execute(
        "INSERT INTO fts_notes(doc_id, scope, content) VALUES(?1, 'user', ?2)",
        params![doc_id, user_content],
    )?;
    conn.execute(
        "INSERT INTO fts_notes(doc_id, scope, content) VALUES(?1, 'agent', ?2)",
        params![doc_id, agent_content],
    )?;
    Ok(())
}

pub fn search(
    conn: &Connection,
    q: &str,
    scope: &str,
    topic: Option<&str>,
    limit: usize,
) -> Result<Vec<SearchResult>, BtError> {
    let effective_scope = match scope {
        "user" | "agent" | "all" => scope,
        _ => "all",
    };

    let sql = r#"
        SELECT f.doc_id, f.scope, d.topic, d.title,
               snippet(fts_notes, 2, '[', ']', '…', 20)
        FROM fts_notes f
        JOIN docs d ON d.id = f.doc_id
        WHERE fts_notes MATCH ?1
          AND (?2 = 'all' OR f.scope = ?2)
          AND (?3 IS NULL OR d.topic = ?3)
        LIMIT ?4
    "#;

    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(params![q, effective_scope, topic, limit as i64], |row| {
        Ok(SearchResult {
            doc_id: row.get(0)?,
            scope: row.get(1)?,
            topic: row.get(2)?,
            title: row.get(3)?,
            excerpt: row.get(4)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn upsert_links(conn: &Connection, doc_id: &str, links: &[String]) -> Result<(), BtError> {
    conn.execute("DELETE FROM links WHERE from_doc_id = ?1", params![doc_id])?;
    for link in links {
        conn.execute(
            "INSERT INTO links(from_doc_id, to_ref, kind) VALUES(?1, ?2, 'meta')",
            params![doc_id, link],
        )?;
    }
    Ok(())
}

pub fn graph_links(conn: &Connection, doc_id: &str) -> Result<Vec<Value>, BtError> {
    let mut stmt =
        conn.prepare("SELECT to_ref, kind FROM links WHERE from_doc_id=?1 ORDER BY to_ref")?;
    let rows = stmt.query_map(params![doc_id], |row| {
        Ok(serde_json::json!({
            "to": row.get::<_, String>(0)?,
            "kind": row.get::<_, String>(1)?,
        }))
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn insert_task(conn: &Connection, task: &Task) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO tasks(
            id, title, status, priority, due_at, topic, doc_id,
            created_at, updated_at, completed_at,
            earliest_start_at, snooze_until,
            lease_owner, lease_expires_at,
            queue_lane, queue_order, success_criteria_json,
            verification_hint, verification_summary, archived_at,
            merged_into_task_id, verified_by_run_id
        )
        VALUES(
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
            ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22
        )
        "#,
        params![
            task.id,
            task.title,
            task.status,
            task.priority,
            task.due_at.map(|d| d.to_rfc3339()),
            task.topic,
            task.doc_id,
            task.created_at.to_rfc3339(),
            task.updated_at.map(|d| d.to_rfc3339()),
            task.completed_at.map(|d| d.to_rfc3339()),
            task.earliest_start_at.map(|d| d.to_rfc3339()),
            task.snooze_until.map(|d| d.to_rfc3339()),
            task.lease_owner,
            task.lease_expires_at.map(|d| d.to_rfc3339()),
            task.queue_lane,
            task.queue_order,
            serde_json::to_string(&task.success_criteria).unwrap_or_else(|_| "[]".to_string()),
            task.verification_hint,
            task.verification_summary,
            task.archived_at.map(|d| d.to_rfc3339()),
            task.merged_into_task_id,
            task.verified_by_run_id,
        ],
    )?;
    Ok(())
}

fn task_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Task> {
    let due: Option<String> = row.get(4)?;
    let created: String = row.get(7)?;
    let updated: Option<String> = row.get(8)?;
    let completed: Option<String> = row.get(9)?;
    let earliest: Option<String> = row.get(10)?;
    let snooze: Option<String> = row.get(11)?;
    let lease_expires: Option<String> = row.get(13)?;
    let queue_lane: Option<String> = row.get(14)?;
    let success_criteria_json: Option<String> = row.get(16)?;
    let archived_at: Option<String> = row.get(19)?;

    Ok(Task {
        id: row.get(0)?,
        title: row.get(1)?,
        status: row.get(2)?,
        priority: row.get(3)?,
        due_at: parse_opt_dt(due),
        topic: row.get(5)?,
        doc_id: row.get(6)?,
        created_at: parse_dt(&created),
        updated_at: parse_opt_dt(updated),
        completed_at: parse_opt_dt(completed),
        earliest_start_at: parse_opt_dt(earliest),
        snooze_until: parse_opt_dt(snooze),
        lease_owner: row.get(12)?,
        lease_expires_at: parse_opt_dt(lease_expires),
        queue_lane: queue_lane.unwrap_or_else(|| "queued".to_string()),
        queue_order: row.get(15)?,
        success_criteria: parse_string_list_json(success_criteria_json),
        verification_hint: row.get(17)?,
        verification_summary: row.get(18)?,
        archived_at: parse_opt_dt(archived_at),
        merged_into_task_id: row.get(20)?,
        verified_by_run_id: row.get(21)?,
    })
}

pub fn get_task(conn: &Connection, task_id: &str) -> Result<Option<Task>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT id, title, status, priority, due_at, topic, doc_id,
               created_at, updated_at, completed_at,
               earliest_start_at, snooze_until,
               lease_owner, lease_expires_at,
               queue_lane, queue_order, success_criteria_json,
               verification_hint, verification_summary, archived_at,
               merged_into_task_id, verified_by_run_id
        FROM tasks
        WHERE id = ?1
        LIMIT 1
    "#,
    )?;

    stmt.query_row(params![task_id], task_from_row)
        .optional()
        .map_err(Into::into)
}

pub fn list_tasks(
    conn: &Connection,
    status: Option<&str>,
    topic: Option<&str>,
    doc_id: Option<&str>,
    lane: Option<&str>,
    include_archived: bool,
    limit: usize,
) -> Result<Vec<Task>, BtError> {
    let sql = r#"
        SELECT id, title, status, priority, due_at, topic, doc_id,
               created_at, updated_at, completed_at,
               earliest_start_at, snooze_until,
               lease_owner, lease_expires_at,
               queue_lane, queue_order, success_criteria_json,
               verification_hint, verification_summary, archived_at,
               merged_into_task_id, verified_by_run_id
        FROM tasks
        WHERE (:status IS NULL OR status = :status)
          AND (:topic IS NULL OR topic = :topic)
          AND (:doc_id IS NULL OR doc_id = :doc_id)
          AND (:lane IS NULL OR COALESCE(queue_lane, 'queued') = :lane)
          AND (:include_archived = 1 OR COALESCE(queue_lane, 'queued') <> 'archived')
        ORDER BY
            CASE COALESCE(queue_lane, 'queued')
                WHEN 'active' THEN 0
                WHEN 'queued' THEN 1
                WHEN 'merged' THEN 2
                WHEN 'archived' THEN 3
                ELSE 4
            END ASC,
            CASE WHEN COALESCE(queue_lane, 'queued') = 'queued' THEN COALESCE(queue_order, 9223372036854775807) END ASC,
            CASE WHEN COALESCE(queue_lane, 'queued') = 'archived' THEN archived_at END DESC,
            updated_at DESC,
            created_at DESC
        LIMIT :limit
    "#;

    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":status": status,
            ":topic": topic,
            ":doc_id": doc_id,
            ":lane": lane,
            ":include_archived": if include_archived { 1 } else { 0 },
            ":limit": limit as i64,
        },
        task_from_row,
    )?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_active_task_for_doc(
    conn: &Connection,
    doc_id: Option<&str>,
) -> Result<Option<Task>, BtError> {
    let sql = if doc_id.is_some() {
        r#"
        SELECT id, title, status, priority, due_at, topic, doc_id,
               created_at, updated_at, completed_at,
               earliest_start_at, snooze_until,
               lease_owner, lease_expires_at,
               queue_lane, queue_order, success_criteria_json,
               verification_hint, verification_summary, archived_at,
               merged_into_task_id, verified_by_run_id
        FROM tasks
        WHERE doc_id = ?1
          AND COALESCE(queue_lane, 'queued') = 'active'
        ORDER BY updated_at DESC, created_at DESC
        LIMIT 1
        "#
    } else {
        r#"
        SELECT id, title, status, priority, due_at, topic, doc_id,
               created_at, updated_at, completed_at,
               earliest_start_at, snooze_until,
               lease_owner, lease_expires_at,
               queue_lane, queue_order, success_criteria_json,
               verification_hint, verification_summary, archived_at,
               merged_into_task_id, verified_by_run_id
        FROM tasks
        WHERE doc_id IS NULL
          AND COALESCE(queue_lane, 'queued') = 'active'
        ORDER BY updated_at DESC, created_at DESC
        LIMIT 1
        "#
    };

    let mut stmt = conn.prepare(sql)?;
    let row = if let Some(doc_id) = doc_id {
        stmt.query_row(params![doc_id], task_from_row).optional()?
    } else {
        stmt.query_row([], task_from_row).optional()?
    };
    Ok(row)
}

pub fn list_queued_tasks_for_doc(
    conn: &Connection,
    doc_id: Option<&str>,
) -> Result<Vec<Task>, BtError> {
    let sql = if doc_id.is_some() {
        r#"
        SELECT id, title, status, priority, due_at, topic, doc_id,
               created_at, updated_at, completed_at,
               earliest_start_at, snooze_until,
               lease_owner, lease_expires_at,
               queue_lane, queue_order, success_criteria_json,
               verification_hint, verification_summary, archived_at,
               merged_into_task_id, verified_by_run_id
        FROM tasks
        WHERE doc_id = ?1
          AND COALESCE(queue_lane, 'queued') = 'queued'
        ORDER BY COALESCE(queue_order, 9223372036854775807) ASC, created_at ASC
        "#
    } else {
        r#"
        SELECT id, title, status, priority, due_at, topic, doc_id,
               created_at, updated_at, completed_at,
               earliest_start_at, snooze_until,
               lease_owner, lease_expires_at,
               queue_lane, queue_order, success_criteria_json,
               verification_hint, verification_summary, archived_at,
               merged_into_task_id, verified_by_run_id
        FROM tasks
        WHERE doc_id IS NULL
          AND COALESCE(queue_lane, 'queued') = 'queued'
        ORDER BY COALESCE(queue_order, 9223372036854775807) ASC, created_at ASC
        "#
    };

    let mut stmt = conn.prepare(sql)?;
    let rows = if let Some(doc_id) = doc_id {
        stmt.query_map(params![doc_id], task_from_row)?
    } else {
        stmt.query_map([], task_from_row)?
    };
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn next_queue_order_for_doc(conn: &Connection, doc_id: Option<&str>) -> Result<i64, BtError> {
    let sql = if doc_id.is_some() {
        r#"
        SELECT COALESCE(MAX(queue_order), 0)
        FROM tasks
        WHERE doc_id = ?1
          AND COALESCE(queue_lane, 'queued') IN ('active', 'queued')
        "#
    } else {
        r#"
        SELECT COALESCE(MAX(queue_order), 0)
        FROM tasks
        WHERE doc_id IS NULL
          AND COALESCE(queue_lane, 'queued') IN ('active', 'queued')
        "#
    };
    let value: i64 = if let Some(doc_id) = doc_id {
        conn.query_row(sql, params![doc_id], |row| row.get(0))?
    } else {
        conn.query_row(sql, [], |row| row.get(0))?
    };
    Ok(value + 1)
}

pub fn delete_queued_tasks_for_doc(
    conn: &Connection,
    doc_id: Option<&str>,
) -> Result<usize, BtError> {
    let changed = if let Some(doc_id) = doc_id {
        conn.execute(
            "DELETE FROM tasks WHERE doc_id = ?1 AND COALESCE(queue_lane, 'queued') = 'queued'",
            params![doc_id],
        )?
    } else {
        conn.execute(
            "DELETE FROM tasks WHERE doc_id IS NULL AND COALESCE(queue_lane, 'queued') = 'queued'",
            [],
        )?
    };
    Ok(changed)
}

pub fn delete_task(conn: &Connection, task_id: &str) -> Result<(), BtError> {
    let changed = conn.execute("DELETE FROM tasks WHERE id = ?1", params![task_id])?;
    if changed == 0 {
        return Err(BtError::NotFound(format!("task {} not found", task_id)));
    }
    Ok(())
}

pub fn update_task_merge(
    conn: &Connection,
    task_id: &str,
    merged_into_task_id: &str,
    updated_at: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE tasks
        SET status='merged',
            queue_lane='merged',
            updated_at=?2,
            merged_into_task_id=?3
        WHERE id=?1
        "#,
        params![task_id, updated_at.to_rfc3339(), merged_into_task_id],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!("task {} not found", task_id)));
    }
    Ok(())
}

pub fn archive_task(
    conn: &Connection,
    task_id: &str,
    verification_summary: &str,
    verified_by_run_id: Option<&str>,
    archived_at: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE tasks
        SET status='completed',
            queue_lane='archived',
            verification_summary=?2,
            completed_at=?3,
            archived_at=?3,
            verified_by_run_id=?4,
            updated_at=?3
        WHERE id=?1
        "#,
        params![
            task_id,
            verification_summary,
            archived_at.to_rfc3339(),
            verified_by_run_id
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!("task {} not found", task_id)));
    }
    Ok(())
}

pub fn activate_task(
    conn: &Connection,
    task_id: &str,
    updated_at: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        "UPDATE tasks SET queue_lane='active', status='open', updated_at=?2 WHERE id=?1",
        params![task_id, updated_at.to_rfc3339()],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!("task {} not found", task_id)));
    }
    Ok(())
}

pub fn list_task_edit_handoffs(
    conn: &Connection,
    status: Option<&str>,
    limit: usize,
) -> Result<Vec<TaskEditHandoff>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT handoff_id, task_id, doc_id, status, created_by, created_at, updated_at,
               claimed_at, claimed_by, completed_at, completed_by
        FROM task_edit_handoffs
        WHERE (:status IS NULL OR status = :status)
        ORDER BY created_at DESC
        LIMIT :limit
        "#,
    )?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":status": status,
            ":limit": limit as i64,
        },
        |row| {
            let created_at: String = row.get(5)?;
            let updated_at: String = row.get(6)?;
            let claimed_at: Option<String> = row.get(7)?;
            let completed_at: Option<String> = row.get(9)?;
            Ok(TaskEditHandoff {
                handoff_id: row.get(0)?,
                task_id: row.get(1)?,
                doc_id: row.get(2)?,
                status: row.get(3)?,
                created_by: row.get(4)?,
                created_at: parse_dt(&created_at),
                updated_at: parse_dt(&updated_at),
                claimed_at: parse_opt_dt(claimed_at),
                claimed_by: row.get(8)?,
                completed_at: parse_opt_dt(completed_at),
                completed_by: row.get(10)?,
            })
        },
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_task_edit_handoff(
    conn: &Connection,
    handoff_id: &str,
) -> Result<Option<TaskEditHandoff>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT handoff_id, task_id, doc_id, status, created_by, created_at, updated_at,
               claimed_at, claimed_by, completed_at, completed_by
        FROM task_edit_handoffs
        WHERE handoff_id = ?1
        LIMIT 1
        "#,
    )?;
    stmt.query_row(params![handoff_id], |row| {
        let created_at: String = row.get(5)?;
        let updated_at: String = row.get(6)?;
        let claimed_at: Option<String> = row.get(7)?;
        let completed_at: Option<String> = row.get(9)?;
        Ok(TaskEditHandoff {
            handoff_id: row.get(0)?,
            task_id: row.get(1)?,
            doc_id: row.get(2)?,
            status: row.get(3)?,
            created_by: row.get(4)?,
            created_at: parse_dt(&created_at),
            updated_at: parse_dt(&updated_at),
            claimed_at: parse_opt_dt(claimed_at),
            claimed_by: row.get(8)?,
            completed_at: parse_opt_dt(completed_at),
            completed_by: row.get(10)?,
        })
    })
    .optional()
    .map_err(Into::into)
}

pub fn get_pending_task_edit_handoff_for_task(
    conn: &Connection,
    task_id: &str,
) -> Result<Option<TaskEditHandoff>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT handoff_id, task_id, doc_id, status, created_by, created_at, updated_at,
               claimed_at, claimed_by, completed_at, completed_by
        FROM task_edit_handoffs
        WHERE task_id = ?1
          AND status = 'pending'
        ORDER BY created_at DESC
        LIMIT 1
        "#,
    )?;
    stmt.query_row(params![task_id], |row| {
        let created_at: String = row.get(5)?;
        let updated_at: String = row.get(6)?;
        let claimed_at: Option<String> = row.get(7)?;
        let completed_at: Option<String> = row.get(9)?;
        Ok(TaskEditHandoff {
            handoff_id: row.get(0)?,
            task_id: row.get(1)?,
            doc_id: row.get(2)?,
            status: row.get(3)?,
            created_by: row.get(4)?,
            created_at: parse_dt(&created_at),
            updated_at: parse_dt(&updated_at),
            claimed_at: parse_opt_dt(claimed_at),
            claimed_by: row.get(8)?,
            completed_at: parse_opt_dt(completed_at),
            completed_by: row.get(10)?,
        })
    })
    .optional()
    .map_err(Into::into)
}

pub fn insert_task_edit_handoff(
    conn: &Connection,
    handoff: &TaskEditHandoff,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO task_edit_handoffs(
            handoff_id, task_id, doc_id, status, created_by, created_at, updated_at,
            claimed_at, claimed_by, completed_at, completed_by
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        "#,
        params![
            handoff.handoff_id,
            handoff.task_id,
            handoff.doc_id,
            handoff.status,
            handoff.created_by,
            handoff.created_at.to_rfc3339(),
            handoff.updated_at.to_rfc3339(),
            handoff.claimed_at.map(|d| d.to_rfc3339()),
            handoff.claimed_by,
            handoff.completed_at.map(|d| d.to_rfc3339()),
            handoff.completed_by,
        ],
    )?;
    Ok(())
}

pub fn claim_task_edit_handoff(
    conn: &Connection,
    handoff_id: &str,
    claimed_by: &str,
    claimed_at: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE task_edit_handoffs
        SET claimed_at = ?2,
            claimed_by = ?3,
            updated_at = ?2
        WHERE handoff_id = ?1
          AND status = 'pending'
        "#,
        params![handoff_id, claimed_at.to_rfc3339(), claimed_by],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "pending task edit handoff {} not found",
            handoff_id
        )));
    }
    Ok(())
}

pub fn complete_task_edit_handoff(
    conn: &Connection,
    handoff_id: &str,
    completed_by: &str,
    completed_at: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE task_edit_handoffs
        SET status = 'completed',
            completed_at = ?2,
            completed_by = ?3,
            updated_at = ?2
        WHERE handoff_id = ?1
        "#,
        params![handoff_id, completed_at.to_rfc3339(), completed_by],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "task edit handoff {} not found",
            handoff_id
        )));
    }
    Ok(())
}

pub fn list_doc_plan_handoffs(
    conn: &Connection,
    status: Option<&str>,
    limit: usize,
) -> Result<Vec<DocPlanHandoff>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT handoff_id, doc_id, status, reason, requested_user_updated_at, created_by,
               created_at, updated_at, claimed_at, claimed_by, completed_at, completed_by
        FROM doc_plan_handoffs
        WHERE (:status IS NULL OR status = :status)
        ORDER BY updated_at DESC, created_at DESC
        LIMIT :limit
        "#,
    )?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":status": status,
            ":limit": limit as i64,
        },
        parse_doc_plan_handoff_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_doc_plan_handoff(
    conn: &Connection,
    handoff_id: &str,
) -> Result<Option<DocPlanHandoff>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT handoff_id, doc_id, status, reason, requested_user_updated_at, created_by,
               created_at, updated_at, claimed_at, claimed_by, completed_at, completed_by
        FROM doc_plan_handoffs
        WHERE handoff_id = ?1
        LIMIT 1
        "#,
    )?;
    stmt.query_row(params![handoff_id], parse_doc_plan_handoff_row)
        .optional()
        .map_err(Into::into)
}

pub fn get_active_doc_plan_handoff_for_doc(
    conn: &Connection,
    doc_id: &str,
) -> Result<Option<DocPlanHandoff>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT handoff_id, doc_id, status, reason, requested_user_updated_at, created_by,
               created_at, updated_at, claimed_at, claimed_by, completed_at, completed_by
        FROM doc_plan_handoffs
        WHERE doc_id = ?1
          AND status IN ('pending', 'claimed')
        ORDER BY updated_at DESC, created_at DESC
        LIMIT 1
        "#,
    )?;
    stmt.query_row(params![doc_id], parse_doc_plan_handoff_row)
        .optional()
        .map_err(Into::into)
}

pub fn insert_doc_plan_handoff(conn: &Connection, handoff: &DocPlanHandoff) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO doc_plan_handoffs(
            handoff_id, doc_id, status, reason, requested_user_updated_at, created_by,
            created_at, updated_at, claimed_at, claimed_by, completed_at, completed_by
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
        "#,
        params![
            handoff.handoff_id,
            handoff.doc_id,
            handoff.status,
            handoff.reason,
            handoff.requested_user_updated_at.to_rfc3339(),
            handoff.created_by,
            handoff.created_at.to_rfc3339(),
            handoff.updated_at.to_rfc3339(),
            handoff.claimed_at.map(|d| d.to_rfc3339()),
            handoff.claimed_by,
            handoff.completed_at.map(|d| d.to_rfc3339()),
            handoff.completed_by,
        ],
    )?;
    Ok(())
}

pub fn update_doc_plan_handoff(conn: &Connection, handoff: &DocPlanHandoff) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE doc_plan_handoffs
        SET doc_id = ?2,
            status = ?3,
            reason = ?4,
            requested_user_updated_at = ?5,
            created_by = ?6,
            created_at = ?7,
            updated_at = ?8,
            claimed_at = ?9,
            claimed_by = ?10,
            completed_at = ?11,
            completed_by = ?12
        WHERE handoff_id = ?1
        "#,
        params![
            handoff.handoff_id,
            handoff.doc_id,
            handoff.status,
            handoff.reason,
            handoff.requested_user_updated_at.to_rfc3339(),
            handoff.created_by,
            handoff.created_at.to_rfc3339(),
            handoff.updated_at.to_rfc3339(),
            handoff.claimed_at.map(|d| d.to_rfc3339()),
            handoff.claimed_by,
            handoff.completed_at.map(|d| d.to_rfc3339()),
            handoff.completed_by,
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "doc plan handoff {} not found",
            handoff.handoff_id
        )));
    }
    Ok(())
}

//
// Runs
//

pub fn insert_run(conn: &Connection, run: &RunRecord) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO runs(
            id, source, status, summary, automation_id, occurrence_id, task_id, doc_id,
            created_at, started_at, ended_at,
            error_kind, error_message,
            agent_brand, agent_name, agent_session_id, adapter_kind,
            craftship_session_id, craftship_session_node_id,
            company_id, agent_id, goal_id, ticket_id,
            openclaw_session_id, openclaw_agent_name
        )
        VALUES(
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8,
            ?9, ?10, ?11, ?12, ?13,
            ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23,
            ?24, ?25
        )
        "#,
        params![
            run.id,
            run.source,
            run.status,
            run.summary,
            run.automation_id,
            run.occurrence_id,
            run.task_id,
            run.doc_id,
            run.created_at.to_rfc3339(),
            run.started_at.map(|d| d.to_rfc3339()),
            run.ended_at.map(|d| d.to_rfc3339()),
            run.error_kind,
            run.error_message,
            run.agent_brand,
            run.agent_name,
            run.agent_session_id,
            run.adapter_kind,
            run.craftship_session_id,
            run.craftship_session_node_id,
            run.company_id,
            run.agent_id,
            run.goal_id,
            run.ticket_id,
            run.openclaw_session_id,
            run.openclaw_agent_name
        ],
    )?;
    Ok(())
}

pub fn update_run_status(
    conn: &Connection,
    run_id: &str,
    status: &str,
    started_at: Option<DateTime<Utc>>,
    ended_at: Option<DateTime<Utc>>,
    error_kind: Option<&str>,
    error_message: Option<&str>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE runs
        SET status=?2,
            started_at=COALESCE(?3, started_at),
            ended_at=COALESCE(?4, ended_at),
            error_kind=?5,
            error_message=?6
        WHERE id=?1
        "#,
        params![
            run_id,
            status,
            started_at.map(|d| d.to_rfc3339()),
            ended_at.map(|d| d.to_rfc3339()),
            error_kind,
            error_message
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!("run {} not found", run_id)));
    }
    Ok(())
}

pub fn get_run(conn: &Connection, run_id: &str) -> Result<Option<RunRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT id, source, status, summary, automation_id, occurrence_id, task_id, doc_id,
               created_at, started_at, ended_at,
               error_kind, error_message,
               agent_brand, agent_name, agent_session_id, adapter_kind,
               craftship_session_id, craftship_session_node_id,
               company_id, agent_id, goal_id, ticket_id,
               openclaw_session_id, openclaw_agent_name
        FROM runs
        WHERE id=?1
        "#,
    )?;

    let row = stmt.query_row(params![run_id], parse_run_row).optional()?;
    Ok(row)
}

pub fn list_runs(
    conn: &Connection,
    status: Option<&str>,
    limit: usize,
) -> Result<Vec<RunRecord>, BtError> {
    let sql = r#"
        SELECT id, source, status, summary, automation_id, occurrence_id, task_id, doc_id,
               created_at, started_at, ended_at,
               error_kind, error_message,
               agent_brand, agent_name, agent_session_id, adapter_kind,
               craftship_session_id, craftship_session_node_id,
               company_id, agent_id, goal_id, ticket_id,
               openclaw_session_id, openclaw_agent_name
        FROM runs
        WHERE (:status IS NULL OR status = :status)
        ORDER BY created_at DESC
        LIMIT :limit
    "#;

    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":status": status,
            ":limit": limit as i64,
        },
        parse_run_row,
    )?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn list_runs_in_range(
    conn: &Connection,
    source: Option<&str>,
    from: DateTime<Utc>,
    to: DateTime<Utc>,
    limit: usize,
) -> Result<Vec<RunRecord>, BtError> {
    let sql = r#"
        SELECT id, source, status, summary, automation_id, occurrence_id, task_id, doc_id,
               created_at, started_at, ended_at,
               error_kind, error_message,
               agent_brand, agent_name, agent_session_id, adapter_kind,
               craftship_session_id, craftship_session_node_id,
               company_id, agent_id, goal_id, ticket_id,
               openclaw_session_id, openclaw_agent_name
        FROM runs
        WHERE (:source IS NULL OR source = :source)
          AND COALESCE(started_at, created_at) >= :from
          AND COALESCE(started_at, created_at) <= :to
        ORDER BY COALESCE(started_at, created_at) ASC
        LIMIT :limit
    "#;
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":source": source,
            ":from": from.to_rfc3339(),
            ":to": to.to_rfc3339(),
            ":limit": limit as i64,
        },
        parse_run_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn parse_run_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RunRecord> {
    let created: String = row.get(8)?;
    let started: Option<String> = row.get(9)?;
    let ended: Option<String> = row.get(10)?;

    Ok(RunRecord {
        id: row.get(0)?,
        source: row.get(1)?,
        status: row.get(2)?,
        summary: row.get(3)?,
        automation_id: row.get(4)?,
        occurrence_id: row.get(5)?,
        task_id: row.get(6)?,
        doc_id: row.get(7)?,
        created_at: parse_dt(&created),
        started_at: parse_opt_dt(started),
        ended_at: parse_opt_dt(ended),
        error_kind: row.get(11)?,
        error_message: row.get(12)?,
        agent_brand: row.get(13)?,
        agent_name: row.get(14)?,
        agent_session_id: row.get(15)?,
        adapter_kind: row.get(16)?,
        craftship_session_id: row.get(17)?,
        craftship_session_node_id: row.get(18)?,
        company_id: row.get(19)?,
        agent_id: row.get(20)?,
        goal_id: row.get(21)?,
        ticket_id: row.get(22)?,
        openclaw_session_id: row.get(23)?,
        openclaw_agent_name: row.get(24)?,
    })
}

pub fn insert_run_artifact(conn: &Connection, artifact: &RunArtifact) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO run_artifacts(id, run_id, kind, path, content_inline, sha256, meta_json, created_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        "#,
        params![
            artifact.id,
            artifact.run_id,
            artifact.kind,
            artifact.path,
            artifact.content_inline,
            artifact.sha256,
            artifact.meta_json.as_ref().map(|m| m.to_string()),
            artifact.created_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn list_run_artifacts(conn: &Connection, run_id: &str) -> Result<Vec<RunArtifact>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT id, run_id, kind, path, content_inline, sha256, meta_json, created_at
        FROM run_artifacts
        WHERE run_id=?1
        ORDER BY created_at ASC
        "#,
    )?;
    let rows = stmt.query_map(params![run_id], |row| {
        let created: String = row.get(7)?;
        let meta_raw: Option<String> = row.get(6)?;
        Ok(RunArtifact {
            id: row.get(0)?,
            run_id: row.get(1)?,
            kind: row.get(2)?,
            path: row.get(3)?,
            content_inline: row.get(4)?,
            sha256: row.get(5)?,
            meta_json: parse_opt_json_value(meta_raw),
            created_at: parse_dt(&created),
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn list_all_run_artifacts(conn: &Connection) -> Result<Vec<RunArtifact>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT id, run_id, kind, path, content_inline, sha256, meta_json, created_at
        FROM run_artifacts
        ORDER BY created_at ASC
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        let created: String = row.get(7)?;
        let meta_raw: Option<String> = row.get(6)?;
        Ok(RunArtifact {
            id: row.get(0)?,
            run_id: row.get(1)?,
            kind: row.get(2)?,
            path: row.get(3)?,
            content_inline: row.get(4)?,
            sha256: row.get(5)?,
            meta_json: parse_opt_json_value(meta_raw),
            created_at: parse_dt(&created),
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

//
// Automations
//

pub fn insert_automation(conn: &Connection, automation: &AutomationRecord) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO automations(
            id, executor_kind, executor_config_json, title, prompt_template,
            doc_id, task_id, shared_context_key,
            schedule_kind, schedule_json, retry_policy_json,
            concurrency_policy, timezone, enabled,
            company_id, goal_id, brand_id, adapter_kind,
            created_at, updated_at, paused_at, last_planned_at
        )
        VALUES(
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
            ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22
        )
        "#,
        params![
            automation.id,
            automation.executor_kind,
            automation.executor_config_json.to_string(),
            automation.title,
            automation.prompt_template,
            automation.doc_id,
            automation.task_id,
            automation.shared_context_key,
            automation.schedule_kind,
            automation.schedule_json.to_string(),
            automation.retry_policy_json.to_string(),
            automation.concurrency_policy,
            automation.timezone,
            automation.enabled as i64,
            automation.company_id,
            automation.goal_id,
            automation.brand_id,
            automation.adapter_kind,
            automation.created_at.to_rfc3339(),
            automation.updated_at.to_rfc3339(),
            automation.paused_at.map(|d| d.to_rfc3339()),
            automation.last_planned_at.map(|d| d.to_rfc3339()),
        ],
    )?;
    Ok(())
}

pub fn update_automation(conn: &Connection, automation: &AutomationRecord) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE automations
        SET executor_kind=?2,
            executor_config_json=?3,
            title=?4,
            prompt_template=?5,
            doc_id=?6,
            task_id=?7,
            shared_context_key=?8,
            schedule_kind=?9,
            schedule_json=?10,
            retry_policy_json=?11,
            concurrency_policy=?12,
            timezone=?13,
            enabled=?14,
            company_id=?15,
            goal_id=?16,
            brand_id=?17,
            adapter_kind=?18,
            updated_at=?19,
            paused_at=?20,
            last_planned_at=?21
        WHERE id=?1
        "#,
        params![
            automation.id,
            automation.executor_kind,
            automation.executor_config_json.to_string(),
            automation.title,
            automation.prompt_template,
            automation.doc_id,
            automation.task_id,
            automation.shared_context_key,
            automation.schedule_kind,
            automation.schedule_json.to_string(),
            automation.retry_policy_json.to_string(),
            automation.concurrency_policy,
            automation.timezone,
            automation.enabled as i64,
            automation.company_id,
            automation.goal_id,
            automation.brand_id,
            automation.adapter_kind,
            automation.updated_at.to_rfc3339(),
            automation.paused_at.map(|d| d.to_rfc3339()),
            automation.last_planned_at.map(|d| d.to_rfc3339()),
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "automation {} not found",
            automation.id
        )));
    }
    Ok(())
}

pub fn get_automation(
    conn: &Connection,
    automation_id: &str,
) -> Result<Option<AutomationRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT id, executor_kind, executor_config_json, title, prompt_template,
               doc_id, task_id, shared_context_key,
               schedule_kind, schedule_json, retry_policy_json,
               concurrency_policy, timezone, enabled,
               company_id, goal_id, brand_id, adapter_kind,
               created_at, updated_at, paused_at, last_planned_at
        FROM automations
        WHERE id=?1
        "#,
    )?;
    stmt.query_row(params![automation_id], parse_automation_row)
        .optional()
        .map_err(Into::into)
}

pub fn list_automations(
    conn: &Connection,
    enabled: Option<bool>,
    executor_kind: Option<&str>,
    limit: usize,
) -> Result<Vec<AutomationRecord>, BtError> {
    let sql = r#"
        SELECT id, executor_kind, executor_config_json, title, prompt_template,
               doc_id, task_id, shared_context_key,
               schedule_kind, schedule_json, retry_policy_json,
               concurrency_policy, timezone, enabled,
               company_id, goal_id, brand_id, adapter_kind,
               created_at, updated_at, paused_at, last_planned_at
        FROM automations
        WHERE (:enabled IS NULL OR enabled = :enabled)
          AND (:executor_kind IS NULL OR executor_kind = :executor_kind)
        ORDER BY updated_at DESC
        LIMIT :limit
    "#;

    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":enabled": enabled.map(|v| if v { 1i64 } else { 0i64 }),
            ":executor_kind": executor_kind,
            ":limit": limit as i64,
        },
        parse_automation_row,
    )?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn delete_automation(conn: &Connection, automation_id: &str) -> Result<(), BtError> {
    let changed = conn.execute(
        "DELETE FROM automations WHERE id=?1",
        params![automation_id],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "automation {} not found",
            automation_id
        )));
    }
    Ok(())
}

pub fn set_automation_enabled(
    conn: &Connection,
    automation_id: &str,
    enabled: bool,
    ts: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        "UPDATE automations SET enabled=?2, updated_at=?3, paused_at=?4 WHERE id=?1",
        params![
            automation_id,
            enabled as i64,
            ts.to_rfc3339(),
            if enabled {
                None::<String>
            } else {
                Some(ts.to_rfc3339())
            }
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "automation {} not found",
            automation_id
        )));
    }
    Ok(())
}

pub fn set_automation_last_planned(
    conn: &Connection,
    automation_id: &str,
    ts: DateTime<Utc>,
) -> Result<(), BtError> {
    conn.execute(
        "UPDATE automations SET last_planned_at=?2, updated_at=?2 WHERE id=?1",
        params![automation_id, ts.to_rfc3339()],
    )?;
    Ok(())
}

fn parse_automation_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AutomationRecord> {
    let created: String = row.get(18)?;
    let updated: String = row.get(19)?;
    Ok(AutomationRecord {
        id: row.get(0)?,
        executor_kind: row.get(1)?,
        executor_config_json: parse_json_value(&row.get::<_, String>(2)?),
        title: row.get(3)?,
        prompt_template: row.get(4)?,
        doc_id: row.get(5)?,
        task_id: row.get(6)?,
        shared_context_key: row.get(7)?,
        schedule_kind: row.get(8)?,
        schedule_json: parse_json_value(&row.get::<_, String>(9)?),
        retry_policy_json: parse_json_value(&row.get::<_, String>(10)?),
        concurrency_policy: row.get(11)?,
        timezone: row.get(12)?,
        enabled: row.get::<_, i64>(13)? != 0,
        company_id: row.get(14)?,
        goal_id: row.get(15)?,
        brand_id: row.get(16)?,
        adapter_kind: row.get(17)?,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
        paused_at: parse_opt_dt(row.get(20)?),
        last_planned_at: parse_opt_dt(row.get(21)?),
    })
}

//
// Crafting
//

pub fn insert_crafting_framework(
    conn: &Connection,
    framework: &CraftingFramework,
) -> Result<(), BtError> {
    let chain_of_thought_json = serde_json::to_string(&framework.chain_of_thought)
        .map_err(|e| BtError::Validation(e.to_string()))?;
    let chain_of_knowledge_json = serde_json::to_string(&framework.chain_of_knowledge)
        .map_err(|e| BtError::Validation(e.to_string()))?;
    conn.execute(
        r#"
        INSERT INTO crafting_frameworks(
            framework_id, name, custom_instruction, enhanced_instruction,
            chain_of_thought_json, chain_of_knowledge_json,
            archived, created_at, updated_at, enhancement_version
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        "#,
        params![
            framework.framework_id,
            framework.name,
            framework.custom_instruction,
            framework.enhanced_instruction,
            chain_of_thought_json,
            chain_of_knowledge_json,
            framework.archived as i64,
            framework.created_at.to_rfc3339(),
            framework.updated_at.to_rfc3339(),
            framework.enhancement_version,
        ],
    )?;
    Ok(())
}

pub fn update_crafting_framework(
    conn: &Connection,
    framework: &CraftingFramework,
) -> Result<(), BtError> {
    let chain_of_thought_json = serde_json::to_string(&framework.chain_of_thought)
        .map_err(|e| BtError::Validation(e.to_string()))?;
    let chain_of_knowledge_json = serde_json::to_string(&framework.chain_of_knowledge)
        .map_err(|e| BtError::Validation(e.to_string()))?;
    let changed = conn.execute(
        r#"
        UPDATE crafting_frameworks
        SET name=?2,
            custom_instruction=?3,
            enhanced_instruction=?4,
            chain_of_thought_json=?5,
            chain_of_knowledge_json=?6,
            archived=?7,
            updated_at=?8,
            enhancement_version=?9
        WHERE framework_id=?1
        "#,
        params![
            framework.framework_id,
            framework.name,
            framework.custom_instruction,
            framework.enhanced_instruction,
            chain_of_thought_json,
            chain_of_knowledge_json,
            framework.archived as i64,
            framework.updated_at.to_rfc3339(),
            framework.enhancement_version,
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "crafting framework {} not found",
            framework.framework_id
        )));
    }
    Ok(())
}

pub fn list_crafting_frameworks(
    conn: &Connection,
    include_archived: bool,
) -> Result<Vec<CraftingFramework>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT framework_id, name, custom_instruction, enhanced_instruction,
               chain_of_thought_json, chain_of_knowledge_json,
               archived, created_at, updated_at, enhancement_version
        FROM crafting_frameworks
        WHERE (?1 = 1 OR archived = 0)
        ORDER BY updated_at DESC
        "#,
    )?;
    let rows = stmt.query_map(
        params![include_archived as i64],
        parse_crafting_framework_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_crafting_framework(
    conn: &Connection,
    framework_id: &str,
) -> Result<Option<CraftingFramework>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT framework_id, name, custom_instruction, enhanced_instruction,
               chain_of_thought_json, chain_of_knowledge_json,
               archived, created_at, updated_at, enhancement_version
        FROM crafting_frameworks
        WHERE framework_id=?1
        "#,
    )?;
    stmt.query_row(params![framework_id], parse_crafting_framework_row)
        .optional()
        .map_err(Into::into)
}

pub fn archive_crafting_framework(
    conn: &Connection,
    framework_id: &str,
    archived: bool,
    ts: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        "UPDATE crafting_frameworks SET archived=?2, updated_at=?3 WHERE framework_id=?1",
        params![framework_id, archived as i64, ts.to_rfc3339()],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "crafting framework {} not found",
            framework_id
        )));
    }
    Ok(())
}

fn parse_crafting_framework_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CraftingFramework> {
    let created: String = row.get(7)?;
    let updated: String = row.get(8)?;
    let chain_of_thought_raw: String = row.get(4)?;
    let chain_of_knowledge_raw: String = row.get(5)?;
    Ok(CraftingFramework {
        framework_id: row.get(0)?,
        name: row.get(1)?,
        custom_instruction: row.get(2)?,
        enhanced_instruction: row.get(3)?,
        chain_of_thought: parse_chain_of_thought_config(&chain_of_thought_raw),
        chain_of_knowledge: parse_chain_of_knowledge_config(&chain_of_knowledge_raw),
        archived: row.get::<_, i64>(6)? != 0,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
        enhancement_version: row.get(9)?,
    })
}

pub fn list_craftships(
    conn: &Connection,
    include_archived: bool,
) -> Result<Vec<Craftship>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT craftship_id, name, necessity, mode, archived,
               required_agent_enabled, required_agent_brand,
               created_at, updated_at
        FROM craftships
        WHERE (?1 = 1 OR archived = 0)
        ORDER BY updated_at DESC, name ASC
        "#,
    )?;
    let rows = stmt.query_map(params![include_archived as i64], parse_craftship_row)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_craftship(conn: &Connection, craftship_id: &str) -> Result<Option<Craftship>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT craftship_id, name, necessity, mode, archived,
               required_agent_enabled, required_agent_brand,
               created_at, updated_at
        FROM craftships
        WHERE craftship_id=?1
        "#,
    )?;
    stmt.query_row(params![craftship_id], parse_craftship_row)
        .optional()
        .map_err(Into::into)
}

pub fn insert_craftship(conn: &Connection, craftship: &Craftship) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO craftships(
            craftship_id, name, necessity, mode, archived,
            required_agent_enabled, required_agent_brand,
            created_at, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        "#,
        params![
            craftship.craftship_id,
            craftship.name,
            craftship.necessity,
            craftship.mode,
            craftship.archived as i64,
            craftship.required_agent_enabled as i64,
            craftship.required_agent_brand,
            craftship.created_at.to_rfc3339(),
            craftship.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn update_craftship(conn: &Connection, craftship: &Craftship) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE craftships
        SET name=?2,
            necessity=?3,
            mode=?4,
            archived=?5,
            required_agent_enabled=?6,
            required_agent_brand=?7,
            updated_at=?8
        WHERE craftship_id=?1
        "#,
        params![
            craftship.craftship_id,
            craftship.name,
            craftship.necessity,
            craftship.mode,
            craftship.archived as i64,
            craftship.required_agent_enabled as i64,
            craftship.required_agent_brand,
            craftship.updated_at.to_rfc3339(),
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "craftship {} not found",
            craftship.craftship_id
        )));
    }
    Ok(())
}

pub fn archive_craftship(
    conn: &Connection,
    craftship_id: &str,
    archived: bool,
    ts: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        "UPDATE craftships SET archived=?2, updated_at=?3 WHERE craftship_id=?1",
        params![craftship_id, archived as i64, ts.to_rfc3339()],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "craftship {} not found",
            craftship_id
        )));
    }
    Ok(())
}

pub fn list_craftship_nodes(
    conn: &Connection,
    craftship_id: &str,
) -> Result<Vec<CraftshipNode>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT node_id, craftship_id, parent_node_id, label, node_kind, framework_id,
               brand_id, sort_order, created_at, updated_at
        FROM craftship_nodes
        WHERE craftship_id=?1
        ORDER BY sort_order ASC, created_at ASC
        "#,
    )?;
    let rows = stmt.query_map(params![craftship_id], parse_craftship_node_row)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn replace_craftship_nodes(
    conn: &Connection,
    craftship_id: &str,
    nodes: &[CraftshipNode],
) -> Result<(), BtError> {
    conn.execute(
        "DELETE FROM craftship_nodes WHERE craftship_id=?1",
        params![craftship_id],
    )?;
    for node in nodes {
        conn.execute(
            r#"
            INSERT INTO craftship_nodes(
                node_id, craftship_id, parent_node_id, label, node_kind, framework_id,
                brand_id, sort_order, created_at, updated_at
            )
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
            params![
                node.node_id,
                node.craftship_id,
                node.parent_node_id,
                node.label,
                node.node_kind,
                node.framework_id,
                node.brand_id,
                node.sort_order,
                node.created_at.to_rfc3339(),
                node.updated_at.to_rfc3339(),
            ],
        )?;
    }
    Ok(())
}

pub fn list_craftship_sessions(
    conn: &Connection,
    craftship_id: Option<&str>,
    status: Option<&str>,
    include_archived: bool,
    limit: usize,
) -> Result<Vec<CraftshipSession>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT craftship_session_id, craftship_id, name, status, launch_mode, runtime_brand,
               doc_id, source_doc_id, last_context_pack_id, created_at, updated_at
        FROM craftship_sessions
        WHERE (?1 IS NULL OR craftship_id=?1)
          AND (?2 IS NULL OR status=?2)
          AND (?3 = 1 OR status != 'archived')
        ORDER BY updated_at DESC, created_at DESC
        LIMIT ?4
        "#,
    )?;
    let rows = stmt.query_map(
        params![craftship_id, status, include_archived as i64, limit as i64],
        parse_craftship_session_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_craftship_session(
    conn: &Connection,
    craftship_session_id: &str,
) -> Result<Option<CraftshipSession>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT craftship_session_id, craftship_id, name, status, launch_mode, runtime_brand,
               doc_id, source_doc_id, last_context_pack_id, created_at, updated_at
        FROM craftship_sessions
        WHERE craftship_session_id=?1
        "#,
    )?;
    stmt.query_row(params![craftship_session_id], parse_craftship_session_row)
        .optional()
        .map_err(Into::into)
}

pub fn insert_craftship_session(
    conn: &Connection,
    session: &CraftshipSession,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO craftship_sessions(
            craftship_session_id, craftship_id, name, status, launch_mode, runtime_brand,
            doc_id, source_doc_id, last_context_pack_id, created_at, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        "#,
        params![
            session.craftship_session_id,
            session.craftship_id,
            session.name,
            session.status,
            session.launch_mode,
            session.runtime_brand,
            session.doc_id,
            session.source_doc_id,
            session.last_context_pack_id,
            session.created_at.to_rfc3339(),
            session.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn update_craftship_session(
    conn: &Connection,
    session: &CraftshipSession,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE craftship_sessions
        SET craftship_id=?2,
            name=?3,
            status=?4,
            launch_mode=?5,
            runtime_brand=?6,
            doc_id=?7,
            source_doc_id=?8,
            last_context_pack_id=?9,
            updated_at=?10
        WHERE craftship_session_id=?1
        "#,
        params![
            session.craftship_session_id,
            session.craftship_id,
            session.name,
            session.status,
            session.launch_mode,
            session.runtime_brand,
            session.doc_id,
            session.source_doc_id,
            session.last_context_pack_id,
            session.updated_at.to_rfc3339(),
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "craftship session {} not found",
            session.craftship_session_id
        )));
    }
    Ok(())
}

pub fn delete_craftship_session(
    conn: &Connection,
    craftship_session_id: &str,
) -> Result<(), BtError> {
    let changed = conn.execute(
        "DELETE FROM craftship_sessions WHERE craftship_session_id=?1",
        params![craftship_session_id],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "craftship session {} not found",
            craftship_session_id
        )));
    }
    Ok(())
}

pub fn list_craftship_session_nodes(
    conn: &Connection,
    craftship_session_id: &str,
) -> Result<Vec<CraftshipSessionNode>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT session_node_id, craftship_session_id, template_node_id, parent_session_node_id,
               label, framework_id, brand_id, terminal_ref, run_id, worktree_path, branch_name,
               event_cursor, presence, agent_name, agent_token_id, status, sort_order, created_at, updated_at
        FROM craftship_session_nodes
        WHERE craftship_session_id=?1
        ORDER BY sort_order ASC, created_at ASC
        "#,
    )?;
    let rows = stmt.query_map(
        params![craftship_session_id],
        parse_craftship_session_node_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_craftship_session_node(
    conn: &Connection,
    session_node_id: &str,
) -> Result<Option<CraftshipSessionNode>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT session_node_id, craftship_session_id, template_node_id, parent_session_node_id,
               label, framework_id, brand_id, terminal_ref, run_id, worktree_path, branch_name,
               event_cursor, presence, agent_name, agent_token_id, status, sort_order, created_at, updated_at
        FROM craftship_session_nodes
        WHERE session_node_id=?1
        "#,
    )?;
    stmt.query_row(params![session_node_id], parse_craftship_session_node_row)
        .optional()
        .map_err(Into::into)
}

pub fn insert_craftship_session_node(
    conn: &Connection,
    node: &CraftshipSessionNode,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT OR IGNORE INTO craftship_session_nodes(
            session_node_id, craftship_session_id, template_node_id, parent_session_node_id,
            label, framework_id, brand_id, terminal_ref, run_id, worktree_path, branch_name,
            event_cursor, presence, agent_name, agent_token_id, status, sort_order, created_at, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
        "#,
        params![
            node.session_node_id,
            node.craftship_session_id,
            node.template_node_id,
            node.parent_session_node_id,
            node.label,
            node.framework_id,
            node.brand_id,
            node.terminal_ref,
            node.run_id,
            node.worktree_path,
            node.branch_name,
            node.event_cursor,
            node.presence,
            node.agent_name,
            node.agent_token_id,
            node.status,
            node.sort_order,
            node.created_at.to_rfc3339(),
            node.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn replace_craftship_session_nodes(
    conn: &Connection,
    craftship_session_id: &str,
    nodes: &[CraftshipSessionNode],
) -> Result<(), BtError> {
    conn.execute(
        "DELETE FROM craftship_session_nodes WHERE craftship_session_id=?1",
        params![craftship_session_id],
    )?;
    for node in nodes {
        conn.execute(
            r#"
            INSERT INTO craftship_session_nodes(
                session_node_id, craftship_session_id, template_node_id, parent_session_node_id,
                label, framework_id, brand_id, terminal_ref, run_id, worktree_path, branch_name,
                event_cursor, presence, agent_name, agent_token_id, status, sort_order, created_at, updated_at
            )
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
            "#,
            params![
                node.session_node_id,
                node.craftship_session_id,
                node.template_node_id,
                node.parent_session_node_id,
                node.label,
                node.framework_id,
                node.brand_id,
                node.terminal_ref,
                node.run_id,
                node.worktree_path,
                node.branch_name,
                node.event_cursor,
                node.presence,
                node.agent_name,
                node.agent_token_id,
                node.status,
                node.sort_order,
                node.created_at.to_rfc3339(),
                node.updated_at.to_rfc3339(),
            ],
        )?;
    }
    Ok(())
}

pub fn update_craftship_session_node(
    conn: &Connection,
    node: &CraftshipSessionNode,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE craftship_session_nodes
        SET craftship_session_id=?2,
            template_node_id=?3,
            parent_session_node_id=?4,
            label=?5,
            framework_id=?6,
            brand_id=?7,
            terminal_ref=?8,
            run_id=?9,
            worktree_path=?10,
            branch_name=?11,
            event_cursor=?12,
            presence=?13,
            agent_name=?14,
            agent_token_id=?15,
            status=?16,
            sort_order=?17,
            updated_at=?18
        WHERE session_node_id=?1
        "#,
        params![
            node.session_node_id,
            node.craftship_session_id,
            node.template_node_id,
            node.parent_session_node_id,
            node.label,
            node.framework_id,
            node.brand_id,
            node.terminal_ref,
            node.run_id,
            node.worktree_path,
            node.branch_name,
            node.event_cursor,
            node.presence,
            node.agent_name,
            node.agent_token_id,
            node.status,
            node.sort_order,
            node.updated_at.to_rfc3339(),
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "craftship session node {} not found",
            node.session_node_id
        )));
    }
    Ok(())
}

pub fn get_craftship_session_node_by_agent_token(
    conn: &Connection,
    craftship_session_id: &str,
    token_id: &str,
) -> Result<Option<CraftshipSessionNode>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT session_node_id, craftship_session_id, template_node_id, parent_session_node_id,
               label, framework_id, brand_id, terminal_ref, run_id, worktree_path, branch_name,
               event_cursor, presence, agent_name, agent_token_id, status, sort_order, created_at, updated_at
        FROM craftship_session_nodes
        WHERE craftship_session_id=?1
          AND agent_token_id=?2
        LIMIT 1
        "#,
    )?;
    stmt.query_row(
        params![craftship_session_id, token_id],
        parse_craftship_session_node_row,
    )
    .optional()
    .map_err(Into::into)
}

pub fn list_craftship_team_work_items(
    conn: &Connection,
    craftship_session_id: &str,
    status: Option<&str>,
    assigned_session_node_id: Option<&str>,
    include_closed: bool,
    limit: usize,
) -> Result<Vec<CraftshipTeamWorkItem>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT work_item_id, craftship_session_id, source_task_id, created_by_session_node_id,
               assigned_session_node_id, status, title, description_md, success_criteria_json,
               verification_hint, result_summary, worktree_ref, branch_name, changed_files_json,
               commit_hash, claimed_at, completed_at, created_at, updated_at
        FROM craftship_team_work_items
        WHERE craftship_session_id=?1
          AND (?2 IS NULL OR status=?2)
          AND (?3 IS NULL OR assigned_session_node_id=?3)
          AND (?4 = 1 OR status NOT IN ('completed', 'canceled'))
        ORDER BY
            CASE status
                WHEN 'blocked' THEN 0
                WHEN 'in_progress' THEN 1
                WHEN 'claimed' THEN 2
                WHEN 'assigned' THEN 3
                WHEN 'ready' THEN 4
                WHEN 'proposed' THEN 5
                ELSE 6
            END ASC,
            updated_at DESC,
            created_at ASC
        LIMIT ?5
        "#,
    )?;
    let rows = stmt.query_map(
        params![
            craftship_session_id,
            status,
            assigned_session_node_id,
            include_closed as i64,
            limit as i64
        ],
        parse_craftship_team_work_item_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_craftship_team_work_item(
    conn: &Connection,
    work_item_id: &str,
) -> Result<Option<CraftshipTeamWorkItem>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT work_item_id, craftship_session_id, source_task_id, created_by_session_node_id,
               assigned_session_node_id, status, title, description_md, success_criteria_json,
               verification_hint, result_summary, worktree_ref, branch_name, changed_files_json,
               commit_hash, claimed_at, completed_at, created_at, updated_at
        FROM craftship_team_work_items
        WHERE work_item_id=?1
        "#,
    )?;
    stmt.query_row(params![work_item_id], parse_craftship_team_work_item_row)
        .optional()
        .map_err(Into::into)
}

pub fn insert_craftship_team_work_item(
    conn: &Connection,
    item: &CraftshipTeamWorkItem,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO craftship_team_work_items(
            work_item_id, craftship_session_id, source_task_id, created_by_session_node_id,
            assigned_session_node_id, status, title, description_md, success_criteria_json,
            verification_hint, result_summary, worktree_ref, branch_name, changed_files_json,
            commit_hash, claimed_at, completed_at, created_at, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
        "#,
        params![
            item.work_item_id,
            item.craftship_session_id,
            item.source_task_id,
            item.created_by_session_node_id,
            item.assigned_session_node_id,
            item.status,
            item.title,
            item.description_md,
            serde_json::to_string(&item.success_criteria).unwrap_or_else(|_| "[]".to_string()),
            item.verification_hint,
            item.result_summary,
            item.worktree_ref,
            item.branch_name,
            serde_json::to_string(&item.changed_files).unwrap_or_else(|_| "[]".to_string()),
            item.commit_hash,
            item.claimed_at.map(|value| value.to_rfc3339()),
            item.completed_at.map(|value| value.to_rfc3339()),
            item.created_at.to_rfc3339(),
            item.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn update_craftship_team_work_item(
    conn: &Connection,
    item: &CraftshipTeamWorkItem,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE craftship_team_work_items
        SET craftship_session_id=?2,
            source_task_id=?3,
            created_by_session_node_id=?4,
            assigned_session_node_id=?5,
            status=?6,
            title=?7,
            description_md=?8,
            success_criteria_json=?9,
            verification_hint=?10,
            result_summary=?11,
            worktree_ref=?12,
            branch_name=?13,
            changed_files_json=?14,
            commit_hash=?15,
            claimed_at=?16,
            completed_at=?17,
            updated_at=?18
        WHERE work_item_id=?1
        "#,
        params![
            item.work_item_id,
            item.craftship_session_id,
            item.source_task_id,
            item.created_by_session_node_id,
            item.assigned_session_node_id,
            item.status,
            item.title,
            item.description_md,
            serde_json::to_string(&item.success_criteria).unwrap_or_else(|_| "[]".to_string()),
            item.verification_hint,
            item.result_summary,
            item.worktree_ref,
            item.branch_name,
            serde_json::to_string(&item.changed_files).unwrap_or_else(|_| "[]".to_string()),
            item.commit_hash,
            item.claimed_at.map(|value| value.to_rfc3339()),
            item.completed_at.map(|value| value.to_rfc3339()),
            item.updated_at.to_rfc3339(),
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "craftship team work item {} not found",
            item.work_item_id
        )));
    }
    Ok(())
}

pub fn insert_craftship_team_message(
    conn: &Connection,
    message: &CraftshipTeamMessage,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO craftship_team_messages(
            message_id, craftship_session_id, sender_session_node_id, message_kind, subject,
            body_md, created_at, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        "#,
        params![
            message.message_id,
            message.craftship_session_id,
            message.sender_session_node_id,
            message.message_kind,
            message.subject,
            message.body_md,
            message.created_at.to_rfc3339(),
            message.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn get_craftship_team_message(
    conn: &Connection,
    message_id: &str,
) -> Result<Option<CraftshipTeamMessage>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT message_id, craftship_session_id, sender_session_node_id, message_kind, subject,
               body_md, created_at, updated_at
        FROM craftship_team_messages
        WHERE message_id=?1
        "#,
    )?;
    stmt.query_row(params![message_id], parse_craftship_team_message_row)
        .optional()
        .map_err(Into::into)
}

pub fn insert_craftship_team_message_receipts(
    conn: &Connection,
    receipts: &[CraftshipTeamMessageReceipt],
) -> Result<(), BtError> {
    for receipt in receipts {
        conn.execute(
            r#"
            INSERT INTO craftship_team_message_receipts(
                receipt_id, message_id, recipient_session_node_id, state, delivered_at,
                acknowledged_at, created_at, updated_at
            )
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            "#,
            params![
                receipt.receipt_id,
                receipt.message_id,
                receipt.recipient_session_node_id,
                receipt.state,
                receipt.delivered_at.map(|value| value.to_rfc3339()),
                receipt.acknowledged_at.map(|value| value.to_rfc3339()),
                receipt.created_at.to_rfc3339(),
                receipt.updated_at.to_rfc3339(),
            ],
        )?;
    }
    Ok(())
}

pub fn get_craftship_team_message_receipt(
    conn: &Connection,
    message_id: &str,
    recipient_session_node_id: &str,
) -> Result<Option<CraftshipTeamMessageReceipt>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT receipt_id, message_id, recipient_session_node_id, state, delivered_at,
               acknowledged_at, created_at, updated_at
        FROM craftship_team_message_receipts
        WHERE message_id=?1
          AND recipient_session_node_id=?2
        "#,
    )?;
    stmt.query_row(
        params![message_id, recipient_session_node_id],
        parse_craftship_team_message_receipt_row,
    )
    .optional()
    .map_err(Into::into)
}

pub fn update_craftship_team_message_receipt(
    conn: &Connection,
    receipt: &CraftshipTeamMessageReceipt,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE craftship_team_message_receipts
        SET state=?3,
            delivered_at=?4,
            acknowledged_at=?5,
            updated_at=?6
        WHERE message_id=?1
          AND recipient_session_node_id=?2
        "#,
        params![
            receipt.message_id,
            receipt.recipient_session_node_id,
            receipt.state,
            receipt.delivered_at.map(|value| value.to_rfc3339()),
            receipt.acknowledged_at.map(|value| value.to_rfc3339()),
            receipt.updated_at.to_rfc3339(),
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "craftship team message receipt {}:{} not found",
            receipt.message_id, receipt.recipient_session_node_id
        )));
    }
    Ok(())
}

pub fn list_craftship_team_inbox_entries(
    conn: &Connection,
    recipient_session_node_id: &str,
    include_acknowledged: bool,
    limit: usize,
) -> Result<Vec<CraftshipTeamInboxEntry>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT
            m.message_id, m.craftship_session_id, m.sender_session_node_id, m.message_kind,
            m.subject, m.body_md, m.created_at, m.updated_at,
            r.receipt_id, r.message_id, r.recipient_session_node_id, r.state, r.delivered_at,
            r.acknowledged_at, r.created_at, r.updated_at,
            sender.label
        FROM craftship_team_message_receipts r
        INNER JOIN craftship_team_messages m ON m.message_id = r.message_id
        LEFT JOIN craftship_session_nodes sender ON sender.session_node_id = m.sender_session_node_id
        WHERE r.recipient_session_node_id=?1
          AND (?2 = 1 OR r.state != 'acknowledged')
        ORDER BY
            CASE r.state
                WHEN 'pending' THEN 0
                WHEN 'delivered' THEN 1
                ELSE 2
            END ASC,
            m.created_at ASC
        LIMIT ?3
        "#,
    )?;
    let rows = stmt.query_map(
        params![
            recipient_session_node_id,
            include_acknowledged as i64,
            limit as i64
        ],
        parse_craftship_team_inbox_entry_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn count_pending_craftship_team_message_receipts(
    conn: &Connection,
    craftship_session_id: &str,
) -> Result<Vec<(String, i64)>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT r.recipient_session_node_id, COUNT(*)
        FROM craftship_team_message_receipts r
        INNER JOIN craftship_team_messages m ON m.message_id = r.message_id
        WHERE m.craftship_session_id=?1
          AND r.state='pending'
        GROUP BY r.recipient_session_node_id
        "#,
    )?;
    let rows = stmt.query_map(params![craftship_session_id], |row| {
        let node_id: String = row.get(0)?;
        let count: i64 = row.get(1)?;
        Ok((node_id, count))
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn parse_craftship_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Craftship> {
    // Column order must match the SELECT lists in `list_craftships` and
    // `get_craftship` exactly.
    let created: String = row.get(7)?;
    let updated: String = row.get(8)?;
    Ok(Craftship {
        craftship_id: row.get(0)?,
        name: row.get(1)?,
        necessity: row.get(2)?,
        mode: row.get(3)?,
        archived: row.get::<_, i64>(4)? != 0,
        required_agent_enabled: row.get::<_, i64>(5)? != 0,
        required_agent_brand: row.get(6)?,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

fn parse_craftship_node_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CraftshipNode> {
    let created: String = row.get(8)?;
    let updated: String = row.get(9)?;
    Ok(CraftshipNode {
        node_id: row.get(0)?,
        craftship_id: row.get(1)?,
        parent_node_id: row.get(2)?,
        label: row.get(3)?,
        node_kind: row.get(4)?,
        framework_id: row.get(5)?,
        brand_id: row.get(6)?,
        sort_order: row.get(7)?,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

fn parse_craftship_session_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CraftshipSession> {
    let created: String = row.get(9)?;
    let updated: String = row.get(10)?;
    Ok(CraftshipSession {
        craftship_session_id: row.get(0)?,
        craftship_id: row.get(1)?,
        name: row.get(2)?,
        status: row.get(3)?,
        launch_mode: row.get(4)?,
        runtime_brand: row.get(5)?,
        doc_id: row.get(6)?,
        source_doc_id: row.get(7)?,
        last_context_pack_id: row.get(8)?,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

fn parse_doc_plan_handoff_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DocPlanHandoff> {
    let requested_user_updated_at: String = row.get(4)?;
    let created_at: String = row.get(6)?;
    let updated_at: String = row.get(7)?;
    let claimed_at: Option<String> = row.get(8)?;
    let completed_at: Option<String> = row.get(10)?;
    Ok(DocPlanHandoff {
        handoff_id: row.get(0)?,
        doc_id: row.get(1)?,
        status: row.get(2)?,
        reason: row.get(3)?,
        requested_user_updated_at: parse_dt(&requested_user_updated_at),
        created_by: row.get(5)?,
        created_at: parse_dt(&created_at),
        updated_at: parse_dt(&updated_at),
        claimed_at: parse_opt_dt(claimed_at),
        claimed_by: row.get(9)?,
        completed_at: parse_opt_dt(completed_at),
        completed_by: row.get(11)?,
    })
}

fn parse_craftship_session_node_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<CraftshipSessionNode> {
    let created: String = row.get(17)?;
    let updated: String = row.get(18)?;
    Ok(CraftshipSessionNode {
        session_node_id: row.get(0)?,
        craftship_session_id: row.get(1)?,
        template_node_id: row.get(2)?,
        parent_session_node_id: row.get(3)?,
        label: row.get(4)?,
        framework_id: row.get(5)?,
        brand_id: row.get(6)?,
        terminal_ref: row.get(7)?,
        run_id: row.get(8)?,
        worktree_path: row.get(9)?,
        branch_name: row.get(10)?,
        event_cursor: row.get(11)?,
        presence: row.get(12)?,
        agent_name: row.get(13)?,
        agent_token_id: row.get(14)?,
        status: row.get(15)?,
        sort_order: row.get(16)?,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

fn parse_craftship_team_work_item_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<CraftshipTeamWorkItem> {
    let claimed_at: Option<String> = row.get(15)?;
    let completed_at: Option<String> = row.get(16)?;
    let created: String = row.get(17)?;
    let updated: String = row.get(18)?;
    Ok(CraftshipTeamWorkItem {
        work_item_id: row.get(0)?,
        craftship_session_id: row.get(1)?,
        source_task_id: row.get(2)?,
        created_by_session_node_id: row.get(3)?,
        assigned_session_node_id: row.get(4)?,
        status: row.get(5)?,
        title: row.get(6)?,
        description_md: row.get(7)?,
        success_criteria: parse_string_list_json(row.get(8)?),
        verification_hint: row.get(9)?,
        result_summary: row.get(10)?,
        worktree_ref: row.get(11)?,
        branch_name: row.get(12)?,
        changed_files: parse_string_list_json(row.get(13)?),
        commit_hash: row.get(14)?,
        claimed_at: parse_opt_dt(claimed_at),
        completed_at: parse_opt_dt(completed_at),
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

fn parse_craftship_team_message_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<CraftshipTeamMessage> {
    let created: String = row.get(6)?;
    let updated: String = row.get(7)?;
    Ok(CraftshipTeamMessage {
        message_id: row.get(0)?,
        craftship_session_id: row.get(1)?,
        sender_session_node_id: row.get(2)?,
        message_kind: row.get(3)?,
        subject: row.get(4)?,
        body_md: row.get(5)?,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

fn parse_craftship_team_message_receipt_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<CraftshipTeamMessageReceipt> {
    let delivered_at: Option<String> = row.get(4)?;
    let acknowledged_at: Option<String> = row.get(5)?;
    let created: String = row.get(6)?;
    let updated: String = row.get(7)?;
    Ok(CraftshipTeamMessageReceipt {
        receipt_id: row.get(0)?,
        message_id: row.get(1)?,
        recipient_session_node_id: row.get(2)?,
        state: row.get(3)?,
        delivered_at: parse_opt_dt(delivered_at),
        acknowledged_at: parse_opt_dt(acknowledged_at),
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

fn parse_craftship_team_inbox_entry_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<CraftshipTeamInboxEntry> {
    let message_created: String = row.get(6)?;
    let message_updated: String = row.get(7)?;
    let delivered_at: Option<String> = row.get(12)?;
    let acknowledged_at: Option<String> = row.get(13)?;
    let receipt_created: String = row.get(14)?;
    let receipt_updated: String = row.get(15)?;

    Ok(CraftshipTeamInboxEntry {
        message: CraftshipTeamMessage {
            message_id: row.get(0)?,
            craftship_session_id: row.get(1)?,
            sender_session_node_id: row.get(2)?,
            message_kind: row.get(3)?,
            subject: row.get(4)?,
            body_md: row.get(5)?,
            created_at: parse_dt(&message_created),
            updated_at: parse_dt(&message_updated),
        },
        receipt: CraftshipTeamMessageReceipt {
            receipt_id: row.get(8)?,
            message_id: row.get(9)?,
            recipient_session_node_id: row.get(10)?,
            state: row.get(11)?,
            delivered_at: parse_opt_dt(delivered_at),
            acknowledged_at: parse_opt_dt(acknowledged_at),
            created_at: parse_dt(&receipt_created),
            updated_at: parse_dt(&receipt_updated),
        },
        sender_label: row.get(16)?,
    })
}

//
// Brands + Adapters
//

pub fn list_brands(conn: &Connection) -> Result<Vec<BrandRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT brand_id, label, adapter_kind, enabled, metadata_json, created_at, updated_at
        FROM brands
        ORDER BY label ASC
        "#,
    )?;
    let rows = stmt.query_map([], parse_brand_row)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_brand(conn: &Connection, brand_id: &str) -> Result<Option<BrandRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT brand_id, label, adapter_kind, enabled, metadata_json, created_at, updated_at
        FROM brands
        WHERE brand_id=?1
        "#,
    )?;
    stmt.query_row(params![brand_id], parse_brand_row)
        .optional()
        .map_err(Into::into)
}

pub fn upsert_brand(conn: &Connection, brand: &BrandRecord) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO brands(brand_id, label, adapter_kind, enabled, metadata_json, created_at, updated_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(brand_id) DO UPDATE SET
            label=excluded.label,
            adapter_kind=excluded.adapter_kind,
            enabled=excluded.enabled,
            metadata_json=excluded.metadata_json,
            updated_at=excluded.updated_at
        "#,
        params![
            brand.brand_id,
            brand.label,
            brand.adapter_kind,
            brand.enabled as i64,
            brand.metadata_json.to_string(),
            brand.created_at.to_rfc3339(),
            brand.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

fn parse_brand_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<BrandRecord> {
    let created: String = row.get(5)?;
    let updated: String = row.get(6)?;
    Ok(BrandRecord {
        brand_id: row.get(0)?,
        label: row.get(1)?,
        adapter_kind: row.get(2)?,
        enabled: row.get::<_, i64>(3)? != 0,
        metadata_json: parse_json_value(&row.get::<_, String>(4)?),
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

pub fn list_adapters(conn: &Connection) -> Result<Vec<AdapterRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT adapter_kind, display_name, enabled, config_json, created_at, updated_at
        FROM adapters
        ORDER BY adapter_kind ASC
        "#,
    )?;
    let rows = stmt.query_map([], parse_adapter_row)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_adapter(
    conn: &Connection,
    adapter_kind: &str,
) -> Result<Option<AdapterRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT adapter_kind, display_name, enabled, config_json, created_at, updated_at
        FROM adapters
        WHERE adapter_kind=?1
        "#,
    )?;
    stmt.query_row(params![adapter_kind], parse_adapter_row)
        .optional()
        .map_err(Into::into)
}

pub fn upsert_adapter(conn: &Connection, adapter: &AdapterRecord) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO adapters(adapter_kind, display_name, enabled, config_json, created_at, updated_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(adapter_kind) DO UPDATE SET
            display_name=excluded.display_name,
            enabled=excluded.enabled,
            config_json=excluded.config_json,
            updated_at=excluded.updated_at
        "#,
        params![
            adapter.adapter_kind,
            adapter.display_name,
            adapter.enabled as i64,
            adapter.config_json.to_string(),
            adapter.created_at.to_rfc3339(),
            adapter.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn has_adapter_kind(conn: &Connection, adapter_kind: &str) -> Result<bool, BtError> {
    let mut stmt =
        conn.prepare("SELECT EXISTS(SELECT 1 FROM adapters WHERE adapter_kind=?1 AND enabled=1)")?;
    let exists: i64 = stmt.query_row(params![adapter_kind], |row| row.get(0))?;
    Ok(exists == 1)
}

fn parse_adapter_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AdapterRecord> {
    let created: String = row.get(4)?;
    let updated: String = row.get(5)?;
    Ok(AdapterRecord {
        adapter_kind: row.get(0)?,
        display_name: row.get(1)?,
        enabled: row.get::<_, i64>(2)? != 0,
        config_json: parse_json_value(&row.get::<_, String>(3)?),
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

//
// Company / Agent / Goal
//

pub fn list_companies(conn: &Connection) -> Result<Vec<CompanyRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT company_id, name, mission, active, created_at, updated_at
        FROM companies
        ORDER BY name ASC
        "#,
    )?;
    let rows = stmt.query_map([], parse_company_row)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_company(conn: &Connection, company_id: &str) -> Result<Option<CompanyRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT company_id, name, mission, active, created_at, updated_at
        FROM companies
        WHERE company_id=?1
        "#,
    )?;
    stmt.query_row(params![company_id], parse_company_row)
        .optional()
        .map_err(Into::into)
}

pub fn upsert_company(conn: &Connection, company: &CompanyRecord) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO companies(company_id, name, mission, active, created_at, updated_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(company_id) DO UPDATE SET
            name=excluded.name,
            mission=excluded.mission,
            active=excluded.active,
            updated_at=excluded.updated_at
        "#,
        params![
            company.company_id,
            company.name,
            company.mission,
            company.active as i64,
            company.created_at.to_rfc3339(),
            company.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

fn parse_company_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CompanyRecord> {
    let created: String = row.get(4)?;
    let updated: String = row.get(5)?;
    Ok(CompanyRecord {
        company_id: row.get(0)?,
        name: row.get(1)?,
        mission: row.get(2)?,
        active: row.get::<_, i64>(3)? != 0,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

pub fn list_agents(
    conn: &Connection,
    company_id: Option<&str>,
) -> Result<Vec<AgentRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT agent_id, company_id, display_name, role_title, role_description, manager_agent_id,
               brand_id, adapter_kind, runtime_mode, budget_monthly_cap_usd, budget_warn_percent,
               state, policy_json, created_at, updated_at, paused_at
        FROM agents
        WHERE (:company_id IS NULL OR company_id=:company_id)
        ORDER BY display_name ASC
        "#,
    )?;
    let rows = stmt.query_map(
        rusqlite::named_params! { ":company_id": company_id },
        parse_agent_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_agent(conn: &Connection, agent_id: &str) -> Result<Option<AgentRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT agent_id, company_id, display_name, role_title, role_description, manager_agent_id,
               brand_id, adapter_kind, runtime_mode, budget_monthly_cap_usd, budget_warn_percent,
               state, policy_json, created_at, updated_at, paused_at
        FROM agents
        WHERE agent_id=?1
        "#,
    )?;
    stmt.query_row(params![agent_id], parse_agent_row)
        .optional()
        .map_err(Into::into)
}

pub fn upsert_agent(conn: &Connection, agent: &AgentRecord) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO agents(
            agent_id, company_id, display_name, role_title, role_description, manager_agent_id,
            brand_id, adapter_kind, runtime_mode, budget_monthly_cap_usd, budget_warn_percent,
            state, policy_json, created_at, updated_at, paused_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
        ON CONFLICT(agent_id) DO UPDATE SET
            company_id=excluded.company_id,
            display_name=excluded.display_name,
            role_title=excluded.role_title,
            role_description=excluded.role_description,
            manager_agent_id=excluded.manager_agent_id,
            brand_id=excluded.brand_id,
            adapter_kind=excluded.adapter_kind,
            runtime_mode=excluded.runtime_mode,
            budget_monthly_cap_usd=excluded.budget_monthly_cap_usd,
            budget_warn_percent=excluded.budget_warn_percent,
            state=excluded.state,
            policy_json=excluded.policy_json,
            updated_at=excluded.updated_at,
            paused_at=excluded.paused_at
        "#,
        params![
            agent.agent_id,
            agent.company_id,
            agent.display_name,
            agent.role_title,
            agent.role_description,
            agent.manager_agent_id,
            agent.brand_id,
            agent.adapter_kind,
            agent.runtime_mode,
            agent.budget_monthly_cap_usd,
            agent.budget_warn_percent,
            agent.state,
            agent.policy_json.to_string(),
            agent.created_at.to_rfc3339(),
            agent.updated_at.to_rfc3339(),
            agent.paused_at.map(|d| d.to_rfc3339()),
        ],
    )?;
    Ok(())
}

pub fn set_agent_runtime_mode(
    conn: &Connection,
    agent_id: &str,
    runtime_mode: &str,
    state: Option<&str>,
    paused_at: Option<DateTime<Utc>>,
    updated_at: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE agents
        SET runtime_mode=?2,
            state=COALESCE(?3, state),
            paused_at=?4,
            updated_at=?5
        WHERE agent_id=?1
        "#,
        params![
            agent_id,
            runtime_mode,
            state,
            paused_at.map(|d| d.to_rfc3339()),
            updated_at.to_rfc3339(),
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!("agent {} not found", agent_id)));
    }
    Ok(())
}

pub fn set_agent_state(
    conn: &Connection,
    agent_id: &str,
    state: &str,
    paused_at: Option<DateTime<Utc>>,
    updated_at: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE agents
        SET state=?2, paused_at=?3, updated_at=?4
        WHERE agent_id=?1
        "#,
        params![
            agent_id,
            state,
            paused_at.map(|d| d.to_rfc3339()),
            updated_at.to_rfc3339(),
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!("agent {} not found", agent_id)));
    }
    Ok(())
}

fn parse_agent_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentRecord> {
    let created: String = row.get(13)?;
    let updated: String = row.get(14)?;
    Ok(AgentRecord {
        agent_id: row.get(0)?,
        company_id: row.get(1)?,
        display_name: row.get(2)?,
        role_title: row.get(3)?,
        role_description: row.get(4)?,
        manager_agent_id: row.get(5)?,
        brand_id: row.get(6)?,
        adapter_kind: row.get(7)?,
        runtime_mode: row.get(8)?,
        budget_monthly_cap_usd: row.get(9)?,
        budget_warn_percent: row.get(10)?,
        state: row.get(11)?,
        policy_json: parse_json_value(&row.get::<_, String>(12)?),
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
        paused_at: parse_opt_dt(row.get(15)?),
    })
}

pub fn list_goals(
    conn: &Connection,
    company_id: Option<&str>,
    parent_goal_id: Option<&str>,
) -> Result<Vec<GoalRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT goal_id, company_id, parent_goal_id, kind, title, description, status, owner_agent_id, created_at, updated_at
        FROM goals
        WHERE (:company_id IS NULL OR company_id=:company_id)
          AND (:parent_goal_id IS NULL OR parent_goal_id=:parent_goal_id)
        ORDER BY updated_at DESC
        "#,
    )?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":company_id": company_id,
            ":parent_goal_id": parent_goal_id,
        },
        parse_goal_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_goal(conn: &Connection, goal_id: &str) -> Result<Option<GoalRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT goal_id, company_id, parent_goal_id, kind, title, description, status, owner_agent_id, created_at, updated_at
        FROM goals
        WHERE goal_id=?1
        "#,
    )?;
    stmt.query_row(params![goal_id], parse_goal_row)
        .optional()
        .map_err(Into::into)
}

pub fn upsert_goal(conn: &Connection, goal: &GoalRecord) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO goals(
            goal_id, company_id, parent_goal_id, kind, title, description, status, owner_agent_id, created_at, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT(goal_id) DO UPDATE SET
            company_id=excluded.company_id,
            parent_goal_id=excluded.parent_goal_id,
            kind=excluded.kind,
            title=excluded.title,
            description=excluded.description,
            status=excluded.status,
            owner_agent_id=excluded.owner_agent_id,
            updated_at=excluded.updated_at
        "#,
        params![
            goal.goal_id,
            goal.company_id,
            goal.parent_goal_id,
            goal.kind,
            goal.title,
            goal.description,
            goal.status,
            goal.owner_agent_id,
            goal.created_at.to_rfc3339(),
            goal.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

fn parse_goal_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<GoalRecord> {
    let created: String = row.get(8)?;
    let updated: String = row.get(9)?;
    Ok(GoalRecord {
        goal_id: row.get(0)?,
        company_id: row.get(1)?,
        parent_goal_id: row.get(2)?,
        kind: row.get(3)?,
        title: row.get(4)?,
        description: row.get(5)?,
        status: row.get(6)?,
        owner_agent_id: row.get(7)?,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

//
// Ticket threads
//

pub fn list_tickets(
    conn: &Connection,
    company_id: Option<&str>,
    status: Option<&str>,
) -> Result<Vec<TicketRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT ticket_id, company_id, goal_id, task_id, title, status, priority, assigned_agent_id,
               current_run_id, plan_required, plan_id, created_at, updated_at
        FROM tickets
        WHERE (:company_id IS NULL OR company_id=:company_id)
          AND (:status IS NULL OR status=:status)
        ORDER BY updated_at DESC
        "#,
    )?;
    let rows = stmt.query_map(
        rusqlite::named_params! { ":company_id": company_id, ":status": status },
        parse_ticket_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_ticket(conn: &Connection, ticket_id: &str) -> Result<Option<TicketRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT ticket_id, company_id, goal_id, task_id, title, status, priority, assigned_agent_id,
               current_run_id, plan_required, plan_id, created_at, updated_at
        FROM tickets
        WHERE ticket_id=?1
        "#,
    )?;
    stmt.query_row(params![ticket_id], parse_ticket_row)
        .optional()
        .map_err(Into::into)
}

pub fn upsert_ticket(conn: &Connection, ticket: &TicketRecord) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO tickets(
            ticket_id, company_id, goal_id, task_id, title, status, priority, assigned_agent_id,
            current_run_id, plan_required, plan_id, created_at, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
        ON CONFLICT(ticket_id) DO UPDATE SET
            company_id=excluded.company_id,
            goal_id=excluded.goal_id,
            task_id=excluded.task_id,
            title=excluded.title,
            status=excluded.status,
            priority=excluded.priority,
            assigned_agent_id=excluded.assigned_agent_id,
            current_run_id=excluded.current_run_id,
            plan_required=excluded.plan_required,
            plan_id=excluded.plan_id,
            updated_at=excluded.updated_at
        "#,
        params![
            ticket.ticket_id,
            ticket.company_id,
            ticket.goal_id,
            ticket.task_id,
            ticket.title,
            ticket.status,
            ticket.priority,
            ticket.assigned_agent_id,
            ticket.current_run_id,
            ticket.plan_required as i64,
            ticket.plan_id,
            ticket.created_at.to_rfc3339(),
            ticket.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn set_ticket_plan(
    conn: &Connection,
    ticket_id: &str,
    plan_id: Option<&str>,
    updated_at: DateTime<Utc>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE tickets
        SET plan_id=?2, updated_at=?3
        WHERE ticket_id=?1
        "#,
        params![ticket_id, plan_id, updated_at.to_rfc3339()],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!("ticket {} not found", ticket_id)));
    }
    Ok(())
}

fn parse_ticket_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<TicketRecord> {
    let created: String = row.get(11)?;
    let updated: String = row.get(12)?;
    Ok(TicketRecord {
        ticket_id: row.get(0)?,
        company_id: row.get(1)?,
        goal_id: row.get(2)?,
        task_id: row.get(3)?,
        title: row.get(4)?,
        status: row.get(5)?,
        priority: row.get(6)?,
        assigned_agent_id: row.get(7)?,
        current_run_id: row.get(8)?,
        plan_required: row.get::<_, i64>(9)? != 0,
        plan_id: row.get(10)?,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

pub fn insert_ticket_message(
    conn: &Connection,
    message: &TicketThreadMessage,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO ticket_thread_messages(message_id, ticket_id, run_id, actor_type, actor_id, body_md, created_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        "#,
        params![
            message.message_id,
            message.ticket_id,
            message.run_id,
            message.actor_type,
            message.actor_id,
            message.body_md,
            message.created_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn list_ticket_messages(
    conn: &Connection,
    ticket_id: &str,
    limit: usize,
) -> Result<Vec<TicketThreadMessage>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT message_id, ticket_id, run_id, actor_type, actor_id, body_md, created_at
        FROM ticket_thread_messages
        WHERE ticket_id=?1
        ORDER BY created_at ASC
        LIMIT ?2
        "#,
    )?;
    let rows = stmt.query_map(params![ticket_id, limit as i64], parse_ticket_message_row)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn parse_ticket_message_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<TicketThreadMessage> {
    let created: String = row.get(6)?;
    Ok(TicketThreadMessage {
        message_id: row.get(0)?,
        ticket_id: row.get(1)?,
        run_id: row.get(2)?,
        actor_type: row.get(3)?,
        actor_id: row.get(4)?,
        body_md: row.get(5)?,
        created_at: parse_dt(&created),
    })
}

pub fn insert_ticket_decision(conn: &Connection, decision: &TicketDecision) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO ticket_decisions(decision_id, ticket_id, run_id, decision_type, decision_text, created_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6)
        "#,
        params![
            decision.decision_id,
            decision.ticket_id,
            decision.run_id,
            decision.decision_type,
            decision.decision_text,
            decision.created_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn list_ticket_decisions(
    conn: &Connection,
    ticket_id: &str,
    limit: usize,
) -> Result<Vec<TicketDecision>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT decision_id, ticket_id, run_id, decision_type, decision_text, created_at
        FROM ticket_decisions
        WHERE ticket_id=?1
        ORDER BY created_at ASC
        LIMIT ?2
        "#,
    )?;
    let rows = stmt.query_map(params![ticket_id, limit as i64], parse_ticket_decision_row)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn parse_ticket_decision_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<TicketDecision> {
    let created: String = row.get(5)?;
    Ok(TicketDecision {
        decision_id: row.get(0)?,
        ticket_id: row.get(1)?,
        run_id: row.get(2)?,
        decision_type: row.get(3)?,
        decision_text: row.get(4)?,
        created_at: parse_dt(&created),
    })
}

pub fn insert_ticket_trace(conn: &Connection, trace: &TicketToolTrace) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO ticket_tool_traces(trace_id, ticket_id, run_id, tool_name, input_json, output_json, created_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        "#,
        params![
            trace.trace_id,
            trace.ticket_id,
            trace.run_id,
            trace.tool_name,
            trace.input_json.to_string(),
            trace.output_json.to_string(),
            trace.created_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn list_ticket_traces(
    conn: &Connection,
    ticket_id: &str,
    limit: usize,
) -> Result<Vec<TicketToolTrace>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT trace_id, ticket_id, run_id, tool_name, input_json, output_json, created_at
        FROM ticket_tool_traces
        WHERE ticket_id=?1
        ORDER BY created_at ASC
        LIMIT ?2
        "#,
    )?;
    let rows = stmt.query_map(params![ticket_id, limit as i64], parse_ticket_trace_row)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn parse_ticket_trace_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<TicketToolTrace> {
    let created: String = row.get(6)?;
    Ok(TicketToolTrace {
        trace_id: row.get(0)?,
        ticket_id: row.get(1)?,
        run_id: row.get(2)?,
        tool_name: row.get(3)?,
        input_json: parse_json_value(&row.get::<_, String>(4)?),
        output_json: parse_json_value(&row.get::<_, String>(5)?),
        created_at: parse_dt(&created),
    })
}

//
// Budget + Governance + Plans
//

pub fn insert_budget_usage(conn: &Connection, usage: &BudgetUsageEntry) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO budget_monthly_usage(usage_id, company_id, agent_id, run_id, month_key, usd_cost, source, created_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        "#,
        params![
            usage.usage_id,
            usage.company_id,
            usage.agent_id,
            usage.run_id,
            usage.month_key,
            usage.usd_cost,
            usage.source,
            usage.created_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn sum_budget_usage_for_month(
    conn: &Connection,
    company_id: &str,
    agent_id: &str,
    month_key: &str,
) -> Result<f64, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT COALESCE(SUM(usd_cost), 0)
        FROM budget_monthly_usage
        WHERE company_id=?1 AND agent_id=?2 AND month_key=?3
        "#,
    )?;
    let total: f64 = stmt.query_row(params![company_id, agent_id, month_key], |row| row.get(0))?;
    Ok(total)
}

pub fn insert_budget_override(
    conn: &Connection,
    override_row: &BudgetOverrideRecord,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO budget_overrides(override_id, company_id, agent_id, reason, approved_by, active, expires_at, created_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        "#,
        params![
            override_row.override_id,
            override_row.company_id,
            override_row.agent_id,
            override_row.reason,
            override_row.approved_by,
            override_row.active as i64,
            override_row.expires_at.map(|d| d.to_rfc3339()),
            override_row.created_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn get_active_budget_override(
    conn: &Connection,
    agent_id: &str,
    now: DateTime<Utc>,
) -> Result<Option<BudgetOverrideRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT override_id, company_id, agent_id, reason, approved_by, active, expires_at, created_at
        FROM budget_overrides
        WHERE agent_id=?1
          AND active=1
          AND (expires_at IS NULL OR expires_at > ?2)
        ORDER BY created_at DESC
        LIMIT 1
        "#,
    )?;
    stmt.query_row(
        params![agent_id, now.to_rfc3339()],
        parse_budget_override_row,
    )
    .optional()
    .map_err(Into::into)
}

fn parse_budget_override_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<BudgetOverrideRecord> {
    let created: String = row.get(7)?;
    Ok(BudgetOverrideRecord {
        override_id: row.get(0)?,
        company_id: row.get(1)?,
        agent_id: row.get(2)?,
        reason: row.get(3)?,
        approved_by: row.get(4)?,
        active: row.get::<_, i64>(5)? != 0,
        expires_at: parse_opt_dt(row.get(6)?),
        created_at: parse_dt(&created),
    })
}

pub fn insert_plan(conn: &Connection, plan: &PlanRecord) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO plans(
            plan_id, company_id, ticket_id, task_id, agent_id, status, plan_path, latest_revision,
            submitted_by, approved_by, approved_at, review_note, created_at, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
        "#,
        params![
            plan.plan_id,
            plan.company_id,
            plan.ticket_id,
            plan.task_id,
            plan.agent_id,
            plan.status,
            plan.plan_path,
            plan.latest_revision,
            plan.submitted_by,
            plan.approved_by,
            plan.approved_at.map(|d| d.to_rfc3339()),
            plan.review_note,
            plan.created_at.to_rfc3339(),
            plan.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn update_plan(conn: &Connection, plan: &PlanRecord) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE plans
        SET company_id=?2,
            ticket_id=?3,
            task_id=?4,
            agent_id=?5,
            status=?6,
            plan_path=?7,
            latest_revision=?8,
            submitted_by=?9,
            approved_by=?10,
            approved_at=?11,
            review_note=?12,
            updated_at=?13
        WHERE plan_id=?1
        "#,
        params![
            plan.plan_id,
            plan.company_id,
            plan.ticket_id,
            plan.task_id,
            plan.agent_id,
            plan.status,
            plan.plan_path,
            plan.latest_revision,
            plan.submitted_by,
            plan.approved_by,
            plan.approved_at.map(|d| d.to_rfc3339()),
            plan.review_note,
            plan.updated_at.to_rfc3339(),
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "plan {} not found",
            plan.plan_id
        )));
    }
    Ok(())
}

pub fn get_plan(conn: &Connection, plan_id: &str) -> Result<Option<PlanRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT plan_id, company_id, ticket_id, task_id, agent_id, status, plan_path, latest_revision,
               submitted_by, approved_by, approved_at, review_note, created_at, updated_at
        FROM plans
        WHERE plan_id=?1
        "#,
    )?;
    stmt.query_row(params![plan_id], parse_plan_row)
        .optional()
        .map_err(Into::into)
}

pub fn list_plans(
    conn: &Connection,
    ticket_id: Option<&str>,
    task_id: Option<&str>,
    status: Option<&str>,
    limit: usize,
) -> Result<Vec<PlanRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT plan_id, company_id, ticket_id, task_id, agent_id, status, plan_path, latest_revision,
               submitted_by, approved_by, approved_at, review_note, created_at, updated_at
        FROM plans
        WHERE (:ticket_id IS NULL OR ticket_id=:ticket_id)
          AND (:task_id IS NULL OR task_id=:task_id)
          AND (:status IS NULL OR status=:status)
        ORDER BY updated_at DESC
        LIMIT :limit
        "#,
    )?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":ticket_id": ticket_id,
            ":task_id": task_id,
            ":status": status,
            ":limit": limit as i64,
        },
        parse_plan_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn latest_approved_plan_for_ticket_or_task(
    conn: &Connection,
    ticket_id: Option<&str>,
    task_id: Option<&str>,
) -> Result<Option<PlanRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT plan_id, company_id, ticket_id, task_id, agent_id, status, plan_path, latest_revision,
               submitted_by, approved_by, approved_at, review_note, created_at, updated_at
        FROM plans
        WHERE status='plan_approved'
          AND (
            (:ticket_id IS NOT NULL AND ticket_id=:ticket_id)
            OR (:task_id IS NOT NULL AND task_id=:task_id)
          )
        ORDER BY updated_at DESC
        LIMIT 1
        "#,
    )?;
    stmt.query_row(
        rusqlite::named_params! {
            ":ticket_id": ticket_id,
            ":task_id": task_id,
        },
        parse_plan_row,
    )
    .optional()
    .map_err(Into::into)
}

fn parse_plan_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<PlanRecord> {
    let created: String = row.get(12)?;
    let updated: String = row.get(13)?;
    Ok(PlanRecord {
        plan_id: row.get(0)?,
        company_id: row.get(1)?,
        ticket_id: row.get(2)?,
        task_id: row.get(3)?,
        agent_id: row.get(4)?,
        status: row.get(5)?,
        plan_path: row.get(6)?,
        latest_revision: row.get(7)?,
        submitted_by: row.get(8)?,
        approved_by: row.get(9)?,
        approved_at: parse_opt_dt(row.get(10)?),
        review_note: row.get(11)?,
        created_at: parse_dt(&created),
        updated_at: parse_dt(&updated),
    })
}

pub fn insert_plan_revision(
    conn: &Connection,
    revision: &PlanRevisionRecord,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO plan_revisions(
            revision_id, plan_id, revision_number, file_path, content_md, submitted_by,
            submitted_at, review_status, review_comment
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        "#,
        params![
            revision.revision_id,
            revision.plan_id,
            revision.revision_number,
            revision.file_path,
            revision.content_md,
            revision.submitted_by,
            revision.submitted_at.to_rfc3339(),
            revision.review_status,
            revision.review_comment,
        ],
    )?;
    Ok(())
}

pub fn list_plan_revisions(
    conn: &Connection,
    plan_id: &str,
) -> Result<Vec<PlanRevisionRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT revision_id, plan_id, revision_number, file_path, content_md, submitted_by,
               submitted_at, review_status, review_comment
        FROM plan_revisions
        WHERE plan_id=?1
        ORDER BY revision_number ASC
        "#,
    )?;
    let rows = stmt.query_map(params![plan_id], parse_plan_revision_row)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn parse_plan_revision_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<PlanRevisionRecord> {
    let submitted: String = row.get(6)?;
    Ok(PlanRevisionRecord {
        revision_id: row.get(0)?,
        plan_id: row.get(1)?,
        revision_number: row.get(2)?,
        file_path: row.get(3)?,
        content_md: row.get(4)?,
        submitted_by: row.get(5)?,
        submitted_at: parse_dt(&submitted),
        review_status: row.get(7)?,
        review_comment: row.get(8)?,
    })
}

pub fn insert_governance_approval(
    conn: &Connection,
    approval: &GovernanceApproval,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO governance_approvals(
            approval_id, company_id, subject_type, subject_id, action, payload_json, requested_by,
            status, reviewed_by, reviewed_at, created_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        "#,
        params![
            approval.approval_id,
            approval.company_id,
            approval.subject_type,
            approval.subject_id,
            approval.action,
            approval.payload_json.to_string(),
            approval.requested_by,
            approval.status,
            approval.reviewed_by,
            approval.reviewed_at.map(|d| d.to_rfc3339()),
            approval.created_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn get_governance_approval(
    conn: &Connection,
    approval_id: &str,
) -> Result<Option<GovernanceApproval>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT approval_id, company_id, subject_type, subject_id, action, payload_json, requested_by,
               status, reviewed_by, reviewed_at, created_at
        FROM governance_approvals
        WHERE approval_id=?1
        "#,
    )?;
    stmt.query_row(params![approval_id], parse_governance_approval_row)
        .optional()
        .map_err(Into::into)
}

pub fn list_governance_approvals(
    conn: &Connection,
    company_id: Option<&str>,
    status: Option<&str>,
    limit: usize,
) -> Result<Vec<GovernanceApproval>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT approval_id, company_id, subject_type, subject_id, action, payload_json, requested_by,
               status, reviewed_by, reviewed_at, created_at
        FROM governance_approvals
        WHERE (:company_id IS NULL OR company_id=:company_id)
          AND (:status IS NULL OR status=:status)
        ORDER BY created_at DESC
        LIMIT :limit
        "#,
    )?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":company_id": company_id,
            ":status": status,
            ":limit": limit as i64,
        },
        parse_governance_approval_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn update_governance_approval(
    conn: &Connection,
    approval_id: &str,
    status: &str,
    reviewed_by: Option<&str>,
    reviewed_at: Option<DateTime<Utc>>,
) -> Result<(), BtError> {
    let changed = conn.execute(
        r#"
        UPDATE governance_approvals
        SET status=?2, reviewed_by=?3, reviewed_at=?4
        WHERE approval_id=?1
        "#,
        params![
            approval_id,
            status,
            reviewed_by,
            reviewed_at.map(|d| d.to_rfc3339()),
        ],
    )?;
    if changed == 0 {
        return Err(BtError::NotFound(format!(
            "approval {} not found",
            approval_id
        )));
    }
    Ok(())
}

fn parse_governance_approval_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<GovernanceApproval> {
    let created: String = row.get(10)?;
    Ok(GovernanceApproval {
        approval_id: row.get(0)?,
        company_id: row.get(1)?,
        subject_type: row.get(2)?,
        subject_id: row.get(3)?,
        action: row.get(4)?,
        payload_json: parse_json_value(&row.get::<_, String>(5)?),
        requested_by: row.get(6)?,
        status: row.get(7)?,
        reviewed_by: row.get(8)?,
        reviewed_at: parse_opt_dt(row.get(9)?),
        created_at: parse_dt(&created),
    })
}

pub fn insert_config_revision(conn: &Connection, revision: &ConfigRevision) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO config_revisions(
            revision_id, company_id, config_scope, config_json, previous_revision_id, created_by, created_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        "#,
        params![
            revision.revision_id,
            revision.company_id,
            revision.config_scope,
            revision.config_json.to_string(),
            revision.previous_revision_id,
            revision.created_by,
            revision.created_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn latest_config_revision(
    conn: &Connection,
    company_id: &str,
    config_scope: &str,
) -> Result<Option<ConfigRevision>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT revision_id, company_id, config_scope, config_json, previous_revision_id, created_by, created_at
        FROM config_revisions
        WHERE company_id=?1 AND config_scope=?2
        ORDER BY created_at DESC
        LIMIT 1
        "#,
    )?;
    stmt.query_row(params![company_id, config_scope], parse_config_revision_row)
        .optional()
        .map_err(Into::into)
}

pub fn list_config_revisions(
    conn: &Connection,
    company_id: &str,
    config_scope: Option<&str>,
    limit: usize,
) -> Result<Vec<ConfigRevision>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT revision_id, company_id, config_scope, config_json, previous_revision_id, created_by, created_at
        FROM config_revisions
        WHERE company_id=?1
          AND (?2 IS NULL OR config_scope=?2)
        ORDER BY created_at DESC
        LIMIT ?3
        "#,
    )?;
    let rows = stmt.query_map(
        params![company_id, config_scope, limit as i64],
        parse_config_revision_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn parse_config_revision_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<ConfigRevision> {
    let created: String = row.get(6)?;
    Ok(ConfigRevision {
        revision_id: row.get(0)?,
        company_id: row.get(1)?,
        config_scope: row.get(2)?,
        config_json: parse_json_value(&row.get::<_, String>(3)?),
        previous_revision_id: row.get(4)?,
        created_by: row.get(5)?,
        created_at: parse_dt(&created),
    })
}

pub fn insert_occurrence_if_absent(
    conn: &Connection,
    occurrence: &AutomationOccurrence,
) -> Result<bool, BtError> {
    let changed = conn.execute(
        r#"
        INSERT OR IGNORE INTO automation_occurrences(
            id, automation_id, attempt, trigger_reason,
            planned_at, ready_at, leased_at, started_at, finished_at,
            status, dedupe_key, lease_owner, lease_expires_at, last_heartbeat_at,
            run_id, failure_kind, failure_message, retry_count, created_at, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
        "#,
        params![
            occurrence.id,
            occurrence.automation_id,
            occurrence.attempt,
            occurrence.trigger_reason,
            occurrence.planned_at.to_rfc3339(),
            occurrence.ready_at.map(|d| d.to_rfc3339()),
            occurrence.leased_at.map(|d| d.to_rfc3339()),
            occurrence.started_at.map(|d| d.to_rfc3339()),
            occurrence.finished_at.map(|d| d.to_rfc3339()),
            occurrence.status,
            occurrence.dedupe_key,
            occurrence.lease_owner,
            occurrence.lease_expires_at.map(|d| d.to_rfc3339()),
            occurrence.last_heartbeat_at.map(|d| d.to_rfc3339()),
            occurrence.run_id,
            occurrence.failure_kind,
            occurrence.failure_message,
            occurrence.retry_count,
            occurrence.created_at.to_rfc3339(),
            occurrence.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(changed > 0)
}

pub fn get_occurrence(
    conn: &Connection,
    occurrence_id: &str,
) -> Result<Option<AutomationOccurrence>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT id, automation_id, attempt, trigger_reason,
               planned_at, ready_at, leased_at, started_at, finished_at,
               status, dedupe_key, lease_owner, lease_expires_at, last_heartbeat_at,
               run_id, failure_kind, failure_message, retry_count, created_at, updated_at
        FROM automation_occurrences
        WHERE id=?1
        "#,
    )?;
    stmt.query_row(params![occurrence_id], parse_occurrence_row)
        .optional()
        .map_err(Into::into)
}

pub fn get_occurrence_by_dedupe(
    conn: &Connection,
    dedupe_key: &str,
) -> Result<Option<AutomationOccurrence>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT id, automation_id, attempt, trigger_reason,
               planned_at, ready_at, leased_at, started_at, finished_at,
               status, dedupe_key, lease_owner, lease_expires_at, last_heartbeat_at,
               run_id, failure_kind, failure_message, retry_count, created_at, updated_at
        FROM automation_occurrences
        WHERE dedupe_key=?1
        "#,
    )?;
    stmt.query_row(params![dedupe_key], parse_occurrence_row)
        .optional()
        .map_err(Into::into)
}

pub fn list_occurrences(
    conn: &Connection,
    automation_id: Option<&str>,
    status: Option<&str>,
    from: Option<DateTime<Utc>>,
    to: Option<DateTime<Utc>>,
    limit: usize,
) -> Result<Vec<AutomationOccurrence>, BtError> {
    let sql = r#"
        SELECT id, automation_id, attempt, trigger_reason,
               planned_at, ready_at, leased_at, started_at, finished_at,
               status, dedupe_key, lease_owner, lease_expires_at, last_heartbeat_at,
               run_id, failure_kind, failure_message, retry_count, created_at, updated_at
        FROM automation_occurrences
        WHERE (:automation_id IS NULL OR automation_id = :automation_id)
          AND (:status IS NULL OR status = :status)
          AND (:from_ts IS NULL OR planned_at >= :from_ts)
          AND (:to_ts IS NULL OR planned_at <= :to_ts)
        ORDER BY planned_at ASC
        LIMIT :limit
    "#;
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":automation_id": automation_id,
            ":status": status,
            ":from_ts": from.map(|d| d.to_rfc3339()),
            ":to_ts": to.map(|d| d.to_rfc3339()),
            ":limit": limit as i64,
        },
        parse_occurrence_row,
    )?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn promote_due_occurrences(conn: &Connection, now: DateTime<Utc>) -> Result<usize, BtError> {
    Ok(conn.execute(
        r#"
        UPDATE automation_occurrences
        SET status='ready',
            ready_at=COALESCE(ready_at, ?1),
            updated_at=?1
        WHERE status='scheduled'
          AND planned_at <= ?1
        "#,
        params![now.to_rfc3339()],
    )?)
}

pub fn has_active_occurrence(conn: &Connection, automation_id: &str) -> Result<bool, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT EXISTS(
            SELECT 1
            FROM automation_occurrences
            WHERE automation_id=?1
              AND status IN ('ready', 'leased', 'running', 'retry_ready')
        )
        "#,
    )?;
    let exists: i64 = stmt.query_row(params![automation_id], |row| row.get(0))?;
    Ok(exists == 1)
}

pub fn claim_occurrence(
    conn: &Connection,
    occurrence_id: &str,
    lease_owner: &str,
    leased_at: DateTime<Utc>,
    lease_expires_at: DateTime<Utc>,
) -> Result<bool, BtError> {
    let changed = conn.execute(
        r#"
        UPDATE automation_occurrences
        SET status='leased',
            lease_owner=?2,
            leased_at=?3,
            lease_expires_at=?4,
            last_heartbeat_at=?3,
            updated_at=?3
        WHERE id=?1
          AND status IN ('ready', 'retry_ready')
          AND (lease_expires_at IS NULL OR lease_expires_at <= ?3 OR lease_owner IS NULL)
        "#,
        params![
            occurrence_id,
            lease_owner,
            leased_at.to_rfc3339(),
            lease_expires_at.to_rfc3339()
        ],
    )?;
    Ok(changed > 0)
}

pub fn heartbeat_occurrence(
    conn: &Connection,
    occurrence_id: &str,
    lease_owner: &str,
    now: DateTime<Utc>,
    lease_expires_at: DateTime<Utc>,
) -> Result<bool, BtError> {
    let changed = conn.execute(
        r#"
        UPDATE automation_occurrences
        SET lease_expires_at=?4,
            last_heartbeat_at=?3,
            updated_at=?3
        WHERE id=?1
          AND lease_owner=?2
          AND status IN ('leased', 'running')
        "#,
        params![
            occurrence_id,
            lease_owner,
            now.to_rfc3339(),
            lease_expires_at.to_rfc3339()
        ],
    )?;
    Ok(changed > 0)
}

pub fn start_occurrence(
    conn: &Connection,
    occurrence_id: &str,
    lease_owner: &str,
    started_at: DateTime<Utc>,
    run_id: Option<&str>,
) -> Result<bool, BtError> {
    let changed = conn.execute(
        r#"
        UPDATE automation_occurrences
        SET status='running',
            started_at=COALESCE(started_at, ?3),
            run_id=COALESCE(?4, run_id),
            updated_at=?3
        WHERE id=?1
          AND lease_owner=?2
          AND status IN ('leased', 'ready', 'retry_ready')
        "#,
        params![occurrence_id, lease_owner, started_at.to_rfc3339(), run_id,],
    )?;
    Ok(changed > 0)
}

pub fn finish_occurrence(
    conn: &Connection,
    occurrence_id: &str,
    lease_owner: Option<&str>,
    status: &str,
    finished_at: DateTime<Utc>,
    run_id: Option<&str>,
    failure_kind: Option<&str>,
    failure_message: Option<&str>,
    retry_count: i64,
) -> Result<bool, BtError> {
    let changed = conn.execute(
        r#"
        UPDATE automation_occurrences
        SET status=?3,
            finished_at=?4,
            run_id=COALESCE(?5, run_id),
            failure_kind=?6,
            failure_message=?7,
            retry_count=?8,
            lease_owner=NULL,
            lease_expires_at=NULL,
            updated_at=?4
        WHERE id=?1
          AND (?2 IS NULL OR lease_owner=?2 OR lease_owner IS NULL)
        "#,
        params![
            occurrence_id,
            lease_owner,
            status,
            finished_at.to_rfc3339(),
            run_id,
            failure_kind,
            failure_message,
            retry_count,
        ],
    )?;
    Ok(changed > 0)
}

pub fn mark_occurrence_ready(
    conn: &Connection,
    occurrence_id: &str,
    status: &str,
    ready_at: DateTime<Utc>,
    retry_count: i64,
) -> Result<bool, BtError> {
    let changed = conn.execute(
        r#"
        UPDATE automation_occurrences
        SET status=?2,
            ready_at=?3,
            retry_count=?4,
            lease_owner=NULL,
            lease_expires_at=NULL,
            updated_at=?3
        WHERE id=?1
          AND status IN ('scheduled', 'leased', 'running', 'failed')
        "#,
        params![occurrence_id, status, ready_at.to_rfc3339(), retry_count],
    )?;
    Ok(changed > 0)
}

pub fn recover_expired_occurrences(
    conn: &Connection,
    now: DateTime<Utc>,
) -> Result<usize, BtError> {
    Ok(conn.execute(
        r#"
        UPDATE automation_occurrences
        SET status='retry_ready',
            retry_count=retry_count + 1,
            lease_owner=NULL,
            lease_expires_at=NULL,
            failure_kind=COALESCE(failure_kind, 'lease_expired'),
            failure_message=COALESCE(failure_message, 'worker lease expired'),
            updated_at=?1
        WHERE status IN ('leased', 'running')
          AND lease_expires_at IS NOT NULL
          AND lease_expires_at <= ?1
        "#,
        params![now.to_rfc3339()],
    )?)
}

pub fn latest_success_for_automation(
    conn: &Connection,
    automation_id: &str,
) -> Result<Option<DateTime<Utc>>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT finished_at
        FROM automation_occurrences
        WHERE automation_id=?1
          AND status='succeeded'
          AND finished_at IS NOT NULL
        ORDER BY finished_at DESC
        LIMIT 1
        "#,
    )?;
    let finished_at: Option<String> = stmt
        .query_row(params![automation_id], |row| row.get(0))
        .optional()?;
    Ok(parse_opt_dt(finished_at))
}

fn parse_occurrence_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AutomationOccurrence> {
    Ok(AutomationOccurrence {
        id: row.get(0)?,
        automation_id: row.get(1)?,
        attempt: row.get(2)?,
        trigger_reason: row.get(3)?,
        planned_at: parse_dt(&row.get::<_, String>(4)?),
        ready_at: parse_opt_dt(row.get(5)?),
        leased_at: parse_opt_dt(row.get(6)?),
        started_at: parse_opt_dt(row.get(7)?),
        finished_at: parse_opt_dt(row.get(8)?),
        status: row.get(9)?,
        dedupe_key: row.get(10)?,
        lease_owner: row.get(11)?,
        lease_expires_at: parse_opt_dt(row.get(12)?),
        last_heartbeat_at: parse_opt_dt(row.get(13)?),
        run_id: row.get(14)?,
        failure_kind: row.get(15)?,
        failure_message: row.get(16)?,
        retry_count: row.get(17)?,
        created_at: parse_dt(&row.get::<_, String>(18)?),
        updated_at: parse_dt(&row.get::<_, String>(19)?),
    })
}

pub fn upsert_worker_cursor(conn: &Connection, cursor: &WorkerCursor) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO worker_cursors(
            worker_id, consumer_group, executor_kind, last_event_id,
            last_heartbeat_at, status, lease_count, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ON CONFLICT(worker_id) DO UPDATE SET
            consumer_group=excluded.consumer_group,
            executor_kind=excluded.executor_kind,
            last_event_id=excluded.last_event_id,
            last_heartbeat_at=excluded.last_heartbeat_at,
            status=excluded.status,
            lease_count=excluded.lease_count,
            updated_at=excluded.updated_at
        "#,
        params![
            cursor.worker_id,
            cursor.consumer_group,
            cursor.executor_kind,
            cursor.last_event_id,
            cursor.last_heartbeat_at.to_rfc3339(),
            cursor.status,
            cursor.lease_count,
            cursor.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn get_worker_cursor(
    conn: &Connection,
    worker_id: &str,
) -> Result<Option<WorkerCursor>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT worker_id, consumer_group, executor_kind, last_event_id,
               last_heartbeat_at, status, lease_count, updated_at
        FROM worker_cursors
        WHERE worker_id=?1
        "#,
    )?;
    stmt.query_row(params![worker_id], parse_worker_cursor_row)
        .optional()
        .map_err(Into::into)
}

pub fn list_worker_cursors(conn: &Connection) -> Result<Vec<WorkerCursor>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT worker_id, consumer_group, executor_kind, last_event_id,
               last_heartbeat_at, status, lease_count, updated_at
        FROM worker_cursors
        ORDER BY updated_at DESC
        "#,
    )?;
    let rows = stmt.query_map([], parse_worker_cursor_row)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn parse_worker_cursor_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<WorkerCursor> {
    Ok(WorkerCursor {
        worker_id: row.get(0)?,
        consumer_group: row.get(1)?,
        executor_kind: row.get(2)?,
        last_event_id: row.get(3)?,
        last_heartbeat_at: parse_dt(&row.get::<_, String>(4)?),
        status: row.get(5)?,
        lease_count: row.get(6)?,
        updated_at: parse_dt(&row.get::<_, String>(7)?),
    })
}

pub fn upsert_run_evaluation(conn: &Connection, evaluation: &RunEvaluation) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO run_evaluations(
            run_id, quality_score, completion_class, intervention_count,
            retry_count, lateness_seconds, evaluated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(run_id) DO UPDATE SET
            quality_score=excluded.quality_score,
            completion_class=excluded.completion_class,
            intervention_count=excluded.intervention_count,
            retry_count=excluded.retry_count,
            lateness_seconds=excluded.lateness_seconds,
            evaluated_at=excluded.evaluated_at
        "#,
        params![
            evaluation.run_id,
            evaluation.quality_score,
            evaluation.completion_class,
            evaluation.intervention_count,
            evaluation.retry_count,
            evaluation.lateness_seconds,
            evaluation.evaluated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn get_run_evaluation(
    conn: &Connection,
    run_id: &str,
) -> Result<Option<RunEvaluation>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT run_id, quality_score, completion_class, intervention_count,
               retry_count, lateness_seconds, evaluated_at
        FROM run_evaluations
        WHERE run_id=?1
        "#,
    )?;
    stmt.query_row(params![run_id], |row| {
        Ok(RunEvaluation {
            run_id: row.get(0)?,
            quality_score: row.get(1)?,
            completion_class: row.get(2)?,
            intervention_count: row.get(3)?,
            retry_count: row.get(4)?,
            lateness_seconds: row.get(5)?,
            evaluated_at: parse_dt(&row.get::<_, String>(6)?),
        })
    })
    .optional()
    .map_err(Into::into)
}

pub fn upsert_shared_context(
    conn: &Connection,
    context: &SharedContextRecord,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO shared_contexts(
            context_key, automation_id, latest_run_id, latest_occurrence_id,
            state_json, artifact_path, updated_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(context_key) DO UPDATE SET
            automation_id=excluded.automation_id,
            latest_run_id=excluded.latest_run_id,
            latest_occurrence_id=excluded.latest_occurrence_id,
            state_json=excluded.state_json,
            artifact_path=excluded.artifact_path,
            updated_at=excluded.updated_at
        "#,
        params![
            context.context_key,
            context.automation_id,
            context.latest_run_id,
            context.latest_occurrence_id,
            context.state_json.to_string(),
            context.artifact_path,
            context.updated_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn get_shared_context(
    conn: &Connection,
    context_key: &str,
) -> Result<Option<SharedContextRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT context_key, automation_id, latest_run_id, latest_occurrence_id,
               state_json, artifact_path, updated_at
        FROM shared_contexts
        WHERE context_key=?1
        "#,
    )?;
    stmt.query_row(params![context_key], |row| {
        Ok(SharedContextRecord {
            context_key: row.get(0)?,
            automation_id: row.get(1)?,
            latest_run_id: row.get(2)?,
            latest_occurrence_id: row.get(3)?,
            state_json: parse_json_value(&row.get::<_, String>(4)?),
            artifact_path: row.get(5)?,
            updated_at: parse_dt(&row.get::<_, String>(6)?),
        })
    })
    .optional()
    .map_err(Into::into)
}

pub fn list_shared_contexts(conn: &Connection) -> Result<Vec<SharedContextRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT context_key, automation_id, latest_run_id, latest_occurrence_id,
               state_json, artifact_path, updated_at
        FROM shared_contexts
        ORDER BY updated_at DESC
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(SharedContextRecord {
            context_key: row.get(0)?,
            automation_id: row.get(1)?,
            latest_run_id: row.get(2)?,
            latest_occurrence_id: row.get(3)?,
            state_json: parse_json_value(&row.get::<_, String>(4)?),
            artifact_path: row.get(5)?,
            updated_at: parse_dt(&row.get::<_, String>(6)?),
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn insert_context_pack(conn: &Connection, pack: &ContextPackRecord) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO context_packs(
            context_id, brand, session_id, doc_id, status, source_hash,
            token_estimate, citation_count, unresolved_citation_count,
            previous_context_id, manifest_path, summary_path, created_at, superseded_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
        "#,
        params![
            pack.context_id,
            pack.brand,
            pack.session_id,
            pack.doc_id,
            pack.status,
            pack.source_hash,
            pack.token_estimate,
            pack.citation_count,
            pack.unresolved_citation_count,
            pack.previous_context_id,
            pack.manifest_path,
            pack.summary_path,
            pack.created_at.to_rfc3339(),
            pack.superseded_at.map(|row| row.to_rfc3339()),
        ],
    )?;
    Ok(())
}

pub fn supersede_active_context_packs(
    conn: &Connection,
    brand: &str,
    session_id: Option<&str>,
    doc_id: Option<&str>,
    superseded_at: DateTime<Utc>,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        UPDATE context_packs
        SET superseded_at=?4
        WHERE brand=?1
          AND superseded_at IS NULL
          AND ((session_id IS NULL AND ?2 IS NULL) OR session_id=?2)
          AND ((doc_id IS NULL AND ?3 IS NULL) OR doc_id=?3)
        "#,
        params![brand, session_id, doc_id, superseded_at.to_rfc3339()],
    )?;
    Ok(())
}

pub fn replace_context_pack_sources(
    conn: &Connection,
    context_id: &str,
    sources: &[ContextPackSourceRecord],
) -> Result<(), BtError> {
    conn.execute(
        "DELETE FROM context_pack_sources WHERE context_id=?1",
        params![context_id],
    )?;

    for source in sources {
        conn.execute(
            r#"
            INSERT INTO context_pack_sources(
                context_id, source_kind, source_ref, source_path,
                source_hash, source_rank, locator_json
            )
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                source.context_id,
                source.source_kind,
                source.source_ref,
                source.source_path,
                source.source_hash,
                source.source_rank,
                source.locator_json.to_string(),
            ],
        )?;
    }

    Ok(())
}

pub fn get_context_pack(
    conn: &Connection,
    context_id: &str,
) -> Result<Option<ContextPackRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT context_id, brand, session_id, doc_id, status, source_hash,
               token_estimate, citation_count, unresolved_citation_count,
               previous_context_id, manifest_path, summary_path, created_at, superseded_at
        FROM context_packs
        WHERE context_id=?1
        "#,
    )?;
    stmt.query_row(params![context_id], parse_context_pack_row)
        .optional()
        .map_err(Into::into)
}

pub fn get_latest_context_pack(
    conn: &Connection,
    brand: Option<&str>,
    session_id: Option<&str>,
    doc_id: Option<&str>,
) -> Result<Option<ContextPackRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT context_id, brand, session_id, doc_id, status, source_hash,
               token_estimate, citation_count, unresolved_citation_count,
               previous_context_id, manifest_path, summary_path, created_at, superseded_at
        FROM context_packs
        WHERE (?1 IS NULL OR brand=?1)
          AND (?2 IS NULL OR session_id=?2)
          AND (?3 IS NULL OR doc_id=?3)
        ORDER BY created_at DESC
        LIMIT 1
        "#,
    )?;
    stmt.query_row(params![brand, session_id, doc_id], parse_context_pack_row)
        .optional()
        .map_err(Into::into)
}

pub fn list_context_packs(
    conn: &Connection,
    brand: Option<&str>,
    session_id: Option<&str>,
    doc_id: Option<&str>,
    limit: usize,
) -> Result<Vec<ContextPackRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT context_id, brand, session_id, doc_id, status, source_hash,
               token_estimate, citation_count, unresolved_citation_count,
               previous_context_id, manifest_path, summary_path, created_at, superseded_at
        FROM context_packs
        WHERE (?1 IS NULL OR brand=?1)
          AND (?2 IS NULL OR session_id=?2)
          AND (?3 IS NULL OR doc_id=?3)
        ORDER BY created_at DESC
        LIMIT ?4
        "#,
    )?;
    let rows = stmt.query_map(
        params![brand, session_id, doc_id, limit as i64],
        parse_context_pack_row,
    )?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn list_context_pack_sources(
    conn: &Connection,
    context_id: &str,
) -> Result<Vec<ContextPackSourceRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT id, context_id, source_kind, source_ref, source_path,
               source_hash, source_rank, locator_json
        FROM context_pack_sources
        WHERE context_id=?1
        ORDER BY source_rank ASC, id ASC
        "#,
    )?;
    let rows = stmt.query_map(params![context_id], |row| {
        Ok(ContextPackSourceRecord {
            id: row.get(0)?,
            context_id: row.get(1)?,
            source_kind: row.get(2)?,
            source_ref: row.get(3)?,
            source_path: row.get(4)?,
            source_hash: row.get(5)?,
            source_rank: row.get(6)?,
            locator_json: parse_json_value(&row.get::<_, String>(7)?),
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn insert_agent_context_event(
    conn: &Connection,
    event: &AgentContextEventRecord,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO agent_context_events(
            event_id, agent_name, session_id, project_id, event_kind,
            context_id, node_id, reason, payload_json, created_at
        )
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        "#,
        params![
            event.event_id,
            event.agent_name,
            event.session_id,
            event.project_id,
            event.event_kind,
            event.context_id,
            event.node_id,
            event.reason,
            event.payload_json.to_string(),
            event.created_at.to_rfc3339(),
        ],
    )?;
    Ok(())
}

pub fn list_agent_context_events(
    conn: &Connection,
    limit: usize,
) -> Result<Vec<AgentContextEventRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT event_id, agent_name, session_id, project_id, event_kind,
               context_id, node_id, reason, payload_json, created_at
        FROM agent_context_events
        ORDER BY created_at DESC
        LIMIT ?1
        "#,
    )?;
    let rows = stmt.query_map(params![limit as i64], |row| {
        let payload: String = row.get(8)?;
        let created_at: String = row.get(9)?;
        Ok(AgentContextEventRecord {
            event_id: row.get(0)?,
            agent_name: row.get(1)?,
            session_id: row.get(2)?,
            project_id: row.get(3)?,
            event_kind: row.get(4)?,
            context_id: row.get(5)?,
            node_id: row.get(6)?,
            reason: row.get(7)?,
            payload_json: parse_json_value(&payload),
            created_at: parse_dt(&created_at),
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn parse_context_pack_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<ContextPackRecord> {
    Ok(ContextPackRecord {
        context_id: row.get(0)?,
        brand: row.get(1)?,
        session_id: row.get(2)?,
        doc_id: row.get(3)?,
        status: row.get(4)?,
        source_hash: row.get(5)?,
        token_estimate: row.get(6)?,
        citation_count: row.get(7)?,
        unresolved_citation_count: row.get(8)?,
        previous_context_id: row.get(9)?,
        manifest_path: row.get(10)?,
        summary_path: row.get(11)?,
        created_at: parse_dt(&row.get::<_, String>(12)?),
        superseded_at: parse_opt_dt(row.get(13)?),
    })
}

pub fn count_interventions_for_run(conn: &Connection, run_id: &str) -> Result<i64, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT COUNT(*)
        FROM audit
        WHERE run_id = ?1
          AND actor_type IN ('user_ui', 'cli_user', 'system')
        "#,
    )?;
    stmt.query_row(params![run_id], |row| row.get(0))
        .map_err(Into::into)
}

pub fn count_occurrences_by_status(conn: &Connection, statuses: &[&str]) -> Result<i64, BtError> {
    if statuses.is_empty() {
        return Ok(0);
    }

    let placeholders = (0..statuses.len())
        .map(|_| "?")
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "SELECT COUNT(*) FROM automation_occurrences WHERE status IN ({})",
        placeholders
    );
    let mut stmt = conn.prepare(&sql)?;
    let count: i64 = stmt.query_row(
        rusqlite::params_from_iter(statuses.iter().copied()),
        |row| row.get(0),
    )?;
    Ok(count)
}

pub fn insert_suggestion(conn: &Connection, suggestion: &Suggestion) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO suggestions(id, doc_id, format, patch, summary, status, created_by, created_at, applied_at, rejected_at)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        "#,
        params![
            suggestion.id,
            suggestion.doc_id,
            suggestion.format,
            suggestion.patch.to_string(),
            suggestion.summary,
            suggestion.status,
            suggestion.created_by,
            suggestion.created_at.to_rfc3339(),
            suggestion.applied_at.map(|d| d.to_rfc3339()),
            suggestion.rejected_at.map(|d| d.to_rfc3339())
        ],
    )?;
    Ok(())
}

pub fn list_suggestions(
    conn: &Connection,
    doc_id: Option<&str>,
    status: Option<&str>,
) -> Result<Vec<Suggestion>, BtError> {
    let sql = r#"
        SELECT id, doc_id, format, patch, summary, status, created_by, created_at, applied_at, rejected_at
        FROM suggestions
        WHERE (:doc_id IS NULL OR doc_id = :doc_id)
          AND (:status IS NULL OR status = :status)
        ORDER BY created_at DESC
    "#;

    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":doc_id": doc_id,
            ":status": status,
        },
        parse_suggestion_row,
    )?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_suggestion(
    conn: &Connection,
    suggestion_id: &str,
) -> Result<Option<Suggestion>, BtError> {
    let mut stmt = conn.prepare(
        "SELECT id, doc_id, format, patch, summary, status, created_by, created_at, applied_at, rejected_at FROM suggestions WHERE id=?1",
    )?;
    let row = stmt
        .query_row(params![suggestion_id], parse_suggestion_row)
        .optional()?;
    Ok(row)
}

fn parse_suggestion_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Suggestion> {
    let created: String = row.get(7)?;
    let applied: Option<String> = row.get(8)?;
    let rejected: Option<String> = row.get(9)?;
    let patch_raw: String = row.get(3)?;

    Ok(Suggestion {
        id: row.get(0)?,
        doc_id: row.get(1)?,
        format: row.get(2)?,
        patch: serde_json::from_str(&patch_raw)
            .unwrap_or_else(|_| serde_json::json!({ "raw": patch_raw })),
        summary: row.get(4)?,
        status: row.get(5)?,
        created_by: row.get(6)?,
        created_at: DateTime::parse_from_rfc3339(&created)
            .map(|d| d.with_timezone(&Utc))
            .unwrap_or_else(|_| Utc::now()),
        applied_at: applied
            .and_then(|d| DateTime::parse_from_rfc3339(&d).ok())
            .map(|d| d.with_timezone(&Utc)),
        rejected_at: rejected
            .and_then(|d| DateTime::parse_from_rfc3339(&d).ok())
            .map(|d| d.with_timezone(&Utc)),
    })
}

pub fn set_suggestion_applied(
    conn: &Connection,
    suggestion_id: &str,
    ts: DateTime<Utc>,
) -> Result<(), BtError> {
    conn.execute(
        "UPDATE suggestions SET status='applied', applied_at=?2 WHERE id=?1",
        params![suggestion_id, ts.to_rfc3339()],
    )?;
    Ok(())
}

pub fn set_suggestion_rejected(
    conn: &Connection,
    suggestion_id: &str,
    ts: DateTime<Utc>,
) -> Result<(), BtError> {
    conn.execute(
        "UPDATE suggestions SET status='rejected', rejected_at=?2 WHERE id=?1",
        params![suggestion_id, ts.to_rfc3339()],
    )?;
    Ok(())
}

pub fn insert_audit(conn: &Connection, entry: &AuditEntry) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO audit(ts, actor_type, actor_id, action, args_hash, doc_id, run_id, result, details_json)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        "#,
        params![
            entry.ts.to_rfc3339(),
            entry.actor_type,
            entry.actor_id,
            entry.action,
            entry.args_hash,
            entry.doc_id,
            entry.run_id,
            entry.result,
            entry.details.to_string()
        ],
    )?;
    Ok(())
}

pub fn tail_audit(
    conn: &Connection,
    since: Option<&str>,
    limit: usize,
) -> Result<Vec<Value>, BtError> {
    let sql = r#"
        SELECT ts, actor_type, actor_id, action, args_hash, doc_id, run_id, result, details_json
        FROM audit
        WHERE (:since IS NULL OR ts >= :since)
        ORDER BY id DESC
        LIMIT :limit
    "#;

    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":since": since,
            ":limit": limit as i64,
        },
        |row| {
            let details_raw: String = row.get(8)?;
            let details = serde_json::from_str::<Value>(&details_raw).unwrap_or(Value::Null);
            Ok(serde_json::json!({
                "ts": row.get::<_, String>(0)?,
                "actor_type": row.get::<_, String>(1)?,
                "actor_id": row.get::<_, String>(2)?,
                "action": row.get::<_, String>(3)?,
                "args_hash": row.get::<_, String>(4)?,
                "doc_id": row.get::<_, Option<String>>(5)?,
                "run_id": row.get::<_, Option<String>>(6)?,
                "result": row.get::<_, String>(7)?,
                "details": details,
            }))
        },
    )?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

//
// Events
//

pub fn insert_event(
    conn: &Connection,
    r#type: &str,
    actor_type: &str,
    actor_id: &str,
    doc_id: Option<&str>,
    run_id: Option<&str>,
    payload: &Value,
    dedupe_key: Option<&str>,
) -> Result<i64, BtError> {
    let changed = conn.execute(
        r#"
        INSERT OR IGNORE INTO events(ts, type, actor_type, actor_id, doc_id, run_id, payload_json, dedupe_key)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        "#,
        params![
            Utc::now().to_rfc3339(),
            r#type,
            actor_type,
            actor_id,
            doc_id,
            run_id,
            payload.to_string(),
            dedupe_key,
        ],
    )?;

    if changed > 0 {
        return Ok(conn.last_insert_rowid());
    }

    if let Some(dedupe_key) = dedupe_key {
        let mut stmt = conn.prepare("SELECT event_id FROM events WHERE dedupe_key=?1 LIMIT 1")?;
        let event_id: i64 = stmt.query_row(params![dedupe_key], |row| row.get(0))?;
        return Ok(event_id);
    }

    Err(BtError::Conflict(
        "event insert ignored unexpectedly".to_string(),
    ))
}

pub fn tail_events(
    conn: &Connection,
    after_event_id: Option<i64>,
    limit: usize,
) -> Result<Vec<EventRecord>, BtError> {
    let sql = r#"
        SELECT event_id, ts, type, actor_type, actor_id, doc_id, run_id, payload_json, dedupe_key
        FROM events
        WHERE (:after IS NULL OR event_id > :after)
        ORDER BY event_id ASC
        LIMIT :limit
    "#;

    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":after": after_event_id,
            ":limit": limit as i64,
        },
        |row| {
            let ts: String = row.get(1)?;
            let payload_raw: String = row.get(7)?;
            let payload = serde_json::from_str::<Value>(&payload_raw).unwrap_or(Value::Null);
            Ok(EventRecord {
                event_id: row.get(0)?,
                ts: DateTime::parse_from_rfc3339(&ts)
                    .map(|d| d.with_timezone(&Utc))
                    .unwrap_or_else(|_| Utc::now()),
                r#type: row.get(2)?,
                actor_type: row.get(3)?,
                actor_id: row.get(4)?,
                doc_id: row.get(5)?,
                run_id: row.get(6)?,
                payload,
                dedupe_key: row.get(8)?,
            })
        },
    )?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn list_events_latest(conn: &Connection, limit: usize) -> Result<Vec<EventRecord>, BtError> {
    let sql = r#"
        SELECT event_id, ts, type, actor_type, actor_id, doc_id, run_id, payload_json, dedupe_key
        FROM events
        ORDER BY event_id DESC
        LIMIT :limit
    "#;

    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(
        rusqlite::named_params! {
            ":limit": limit as i64,
        },
        |row| {
            let ts: String = row.get(1)?;
            let payload_raw: String = row.get(7)?;
            let payload = serde_json::from_str::<Value>(&payload_raw).unwrap_or(Value::Null);
            Ok(EventRecord {
                event_id: row.get(0)?,
                ts: DateTime::parse_from_rfc3339(&ts)
                    .map(|d| d.with_timezone(&Utc))
                    .unwrap_or_else(|_| Utc::now()),
                r#type: row.get(2)?,
                actor_type: row.get(3)?,
                actor_id: row.get(4)?,
                doc_id: row.get(5)?,
                run_id: row.get(6)?,
                payload,
                dedupe_key: row.get(8)?,
            })
        },
    )?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    out.reverse();
    Ok(out)
}

pub fn list_events_all(conn: &Connection) -> Result<Vec<EventRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT event_id, ts, type, actor_type, actor_id, doc_id, run_id, payload_json, dedupe_key
        FROM events
        ORDER BY event_id ASC
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        let ts: String = row.get(1)?;
        let payload_raw: String = row.get(7)?;
        let payload = serde_json::from_str::<Value>(&payload_raw).unwrap_or(Value::Null);
        Ok(EventRecord {
            event_id: row.get(0)?,
            ts: parse_dt(&ts),
            r#type: row.get(2)?,
            actor_type: row.get(3)?,
            actor_id: row.get(4)?,
            doc_id: row.get(5)?,
            run_id: row.get(6)?,
            payload,
            dedupe_key: row.get(8)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn replace_graph_projection(
    conn: &Connection,
    nodes: &[GraphNodeRecord],
    edges: &[GraphEdgeRecord],
) -> Result<(), BtError> {
    let tx = conn.unchecked_transaction()?;
    tx.execute("DELETE FROM graph_edges", [])?;
    tx.execute("DELETE FROM graph_nodes", [])?;

    {
        let mut stmt = tx.prepare(
            r#"
            INSERT INTO graph_nodes(
                node_id, kind, ref_id, label, secondary_label,
                group_key, search_text, sort_time, payload_json
            )
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
        )?;
        for node in nodes {
            stmt.execute(params![
                node.node_id,
                node.kind,
                node.ref_id,
                node.label,
                node.secondary_label,
                node.group_key,
                node.search_text,
                node.sort_time.map(|d| d.to_rfc3339()),
                node.payload.to_string(),
            ])?;
        }
    }

    {
        let mut stmt = tx.prepare(
            r#"
            INSERT INTO graph_edges(
                edge_id, kind, source_id, target_id, search_text, sort_time, payload_json
            )
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )?;
        for edge in edges {
            stmt.execute(params![
                edge.edge_id,
                edge.kind,
                edge.source_id,
                edge.target_id,
                edge.search_text,
                edge.sort_time.map(|d| d.to_rfc3339()),
                edge.payload.to_string(),
            ])?;
        }
    }

    tx.commit()?;
    Ok(())
}

pub fn list_graph_nodes(conn: &Connection) -> Result<Vec<GraphNodeRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT node_id, kind, ref_id, label, secondary_label, group_key, search_text, sort_time, payload_json
        FROM graph_nodes
        ORDER BY kind ASC, label COLLATE NOCASE ASC
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        let sort_time: Option<String> = row.get(7)?;
        Ok(GraphNodeRecord {
            node_id: row.get(0)?,
            kind: row.get(1)?,
            ref_id: row.get(2)?,
            label: row.get(3)?,
            secondary_label: row.get(4)?,
            group_key: row.get(5)?,
            search_text: row.get(6)?,
            sort_time: parse_opt_dt(sort_time),
            payload: parse_json_value(&row.get::<_, String>(8)?),
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_graph_node(
    conn: &Connection,
    node_id: &str,
) -> Result<Option<GraphNodeRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT node_id, kind, ref_id, label, secondary_label, group_key, search_text, sort_time, payload_json
        FROM graph_nodes
        WHERE node_id=?1
        "#,
    )?;
    stmt.query_row(params![node_id], |row| {
        let sort_time: Option<String> = row.get(7)?;
        Ok(GraphNodeRecord {
            node_id: row.get(0)?,
            kind: row.get(1)?,
            ref_id: row.get(2)?,
            label: row.get(3)?,
            secondary_label: row.get(4)?,
            group_key: row.get(5)?,
            search_text: row.get(6)?,
            sort_time: parse_opt_dt(sort_time),
            payload: parse_json_value(&row.get::<_, String>(8)?),
        })
    })
    .optional()
    .map_err(Into::into)
}

pub fn list_graph_edges(conn: &Connection) -> Result<Vec<GraphEdgeRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT edge_id, kind, source_id, target_id, search_text, sort_time, payload_json
        FROM graph_edges
        ORDER BY kind ASC, edge_id ASC
        "#,
    )?;
    let rows = stmt.query_map([], |row| {
        let sort_time: Option<String> = row.get(5)?;
        Ok(GraphEdgeRecord {
            edge_id: row.get(0)?,
            kind: row.get(1)?,
            source_id: row.get(2)?,
            target_id: row.get(3)?,
            search_text: row.get(4)?,
            sort_time: parse_opt_dt(sort_time),
            payload: parse_json_value(&row.get::<_, String>(6)?),
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn list_graph_edges_for_node(
    conn: &Connection,
    node_id: &str,
) -> Result<Vec<GraphEdgeRecord>, BtError> {
    let mut stmt = conn.prepare(
        r#"
        SELECT edge_id, kind, source_id, target_id, search_text, sort_time, payload_json
        FROM graph_edges
        WHERE source_id=?1 OR target_id=?1
        ORDER BY kind ASC, edge_id ASC
        "#,
    )?;
    let rows = stmt.query_map(params![node_id], |row| {
        let sort_time: Option<String> = row.get(5)?;
        Ok(GraphEdgeRecord {
            edge_id: row.get(0)?,
            kind: row.get(1)?,
            source_id: row.get(2)?,
            target_id: row.get(3)?,
            search_text: row.get(4)?,
            sort_time: parse_opt_dt(sort_time),
            payload: parse_json_value(&row.get::<_, String>(6)?),
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn touch_agent_activity(
    conn: &Connection,
    doc_id: &str,
    token_id: &str,
    ts: DateTime<Utc>,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO agent_activity(doc_id, token_id, last_seen_at)
        VALUES(?1, ?2, ?3)
        ON CONFLICT(doc_id, token_id) DO UPDATE SET
            last_seen_at=excluded.last_seen_at
        "#,
        params![doc_id, token_id, ts.to_rfc3339()],
    )?;
    Ok(())
}

pub fn has_recent_agent_activity(
    conn: &Connection,
    doc_id: &str,
    seconds: i64,
) -> Result<bool, BtError> {
    let threshold = (Utc::now() - chrono::Duration::seconds(seconds)).to_rfc3339();
    let mut stmt = conn.prepare(
        "SELECT EXISTS(SELECT 1 FROM agent_activity WHERE doc_id = ?1 AND last_seen_at >= ?2)",
    )?;
    let exists: i64 = stmt.query_row(params![doc_id, threshold], |row| row.get(0))?;
    Ok(exists == 1)
}
