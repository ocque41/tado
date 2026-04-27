//! Phase 3 — deterministic enrichment pipeline.
//!
//! Background workers drain `pending_enrichment` (created in
//! migration 23) and turn raw notes/runs/retros into typed entities +
//! provenance edges on `graph_nodes` / `graph_edges`. Pure
//! deterministic logic — no LLM in the loop, no model dependency
//! beyond Qwen3 (which the deduper *can* use for semantic dedup but
//! falls back to content-hash exact match when the runtime isn't
//! loaded).
//!
//! Design constraints (from the v0.10 plan):
//! - **Async, never on the write path.** A `dome_note_write` commits
//!   doc + chunks + embeddings, full stop. Enrichment runs on a
//!   tokio queue at low priority; agents racing the enricher see
//!   deterministic-extracted fields synchronously and survive
//!   without async-enriched ones.
//! - **Idempotent by content_hash.** Every job recomputes the hash
//!   of its inputs and skips if the output node already has that
//!   hash. Restart-safety is free.
//! - **Backpressure is the queue itself.** Long queue → retrieval
//!   reads `entities` as-of-now, missing freshly-enriched fields.
//!   That's correct: query results stay consistent, deepening lazily.
//! - **No watchdogs.** Per CLAUDE.md convention. Failures bubble up
//!   into `pending_enrichment.last_error`; the worker keeps going
//!   on the next item.
//!
//! Six modules:
//! - [`extractor`] — markdown → typed graph_nodes + graph_edges.
//! - [`linker`]    — resolve dangling refs by content_hash / ref_id.
//! - [`deduper`]   — content_hash exact-match → supersede edges.
//! - [`decayer`]   — TTL + retention sweep, soft-deletes stale rows.
//! - [`worker`]    — tokio task pool that drives the queue.
//! - public types  — `EnrichmentKind`, `EnrichmentJob`, `enqueue`.

use crate::error::BtError;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use uuid::Uuid;

pub mod deduper;
pub mod decayer;
pub mod extractor;
pub mod linker;
pub mod worker;

pub use worker::{spawn_workers, EnrichmentSettings, EnrichmentTaskHandles};

/// Discrete enrichment phases. Each maps to one tokio worker that
/// drains `pending_enrichment WHERE enrichment_kind = ?`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EnrichmentKind {
    /// Parse a doc's markdown body into typed entities + edges.
    Extract,
    /// Resolve dangling references emitted by extractor.
    Link,
    /// Detect duplicate entities and chain them via supersede edges.
    Dedupe,
    /// Walk graph_nodes for expired/retention-aged rows; soft-delete.
    Decay,
    /// Backfill on schema upgrade — same as Extract but a different
    /// queue lane so a backfill drain doesn't starve live writes.
    BackfillExtract,
}

impl EnrichmentKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            EnrichmentKind::Extract => "extract",
            EnrichmentKind::Link => "link",
            EnrichmentKind::Dedupe => "dedupe",
            EnrichmentKind::Decay => "decay",
            EnrichmentKind::BackfillExtract => "backfill_extract",
        }
    }
}

impl FromStr for EnrichmentKind {
    type Err = BtError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "extract" => EnrichmentKind::Extract,
            "link" => EnrichmentKind::Link,
            "dedupe" => EnrichmentKind::Dedupe,
            "decay" => EnrichmentKind::Decay,
            "backfill_extract" => EnrichmentKind::BackfillExtract,
            other => {
                return Err(BtError::Validation(format!(
                    "unknown enrichment_kind '{other}'"
                )))
            }
        })
    }
}

/// What an enrichment job points at.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EnrichmentTargetKind {
    Doc,
    GraphNode,
    Run,
    Retro,
}

impl EnrichmentTargetKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            EnrichmentTargetKind::Doc => "doc",
            EnrichmentTargetKind::GraphNode => "graph_node",
            EnrichmentTargetKind::Run => "run",
            EnrichmentTargetKind::Retro => "retro",
        }
    }
}

/// In-memory mirror of a `pending_enrichment` row. `Clone` is
/// load-bearing: `worker::drain_once` clones the job before passing
/// the original into a `catch_unwind` so it can update the row
/// regardless of whether the closure panicked.
#[derive(Debug, Clone)]
pub struct EnrichmentJob {
    pub job_id: String,
    pub target_kind: String,
    pub target_id: String,
    pub enrichment_kind: EnrichmentKind,
    pub project_id: Option<String>,
    pub attempts: i64,
    pub payload: serde_json::Value,
}

/// Enqueue a new job. Returns the `job_id` (existing or newly minted).
/// Idempotent by `(target_kind, target_id, enrichment_kind)` for
/// queued/running rows — concurrent callers see exactly one row.
///
/// Wrapped in `BEGIN IMMEDIATE` so the SELECT-then-INSERT race window
/// is closed — without it, two concurrent writes for the same target
/// can both see "no row" and both insert, defeating the dedup
/// contract. The IMMEDIATE lock blocks other writers for the duration
/// of the call (~µs), which is acceptable on the write path.
pub fn enqueue(
    conn: &Connection,
    target_kind: EnrichmentTargetKind,
    target_id: &str,
    kind: EnrichmentKind,
    project_id: Option<&str>,
) -> Result<String, BtError> {
    let tx = conn.unchecked_transaction()?;
    let existing: Option<String> = tx
        .query_row(
            r#"SELECT job_id FROM pending_enrichment
                WHERE target_kind = ?1 AND target_id = ?2
                  AND enrichment_kind = ?3 AND status IN ('queued', 'running')
                LIMIT 1"#,
            params![target_kind.as_str(), target_id, kind.as_str()],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(id) = existing {
        tx.commit()?;
        return Ok(id);
    }
    let job_id = format!("enq_{}", Uuid::new_v4().simple());
    tx.execute(
        r#"INSERT INTO pending_enrichment(
            job_id, target_kind, target_id, enrichment_kind, project_id, payload_json
        ) VALUES (?1, ?2, ?3, ?4, ?5, '{}')"#,
        params![
            job_id,
            target_kind.as_str(),
            target_id,
            kind.as_str(),
            project_id,
        ],
    )?;
    tx.commit()?;
    Ok(job_id)
}

/// Claim up to `limit` queued jobs of a given `kind`, atomically
/// flipping them to `running`. Returns the claimed jobs in queue order.
///
/// Uses an explicit `BEGIN IMMEDIATE` so two workers running in
/// parallel can never claim the same row twice — `unchecked_transaction`
/// defaults to DEFERRED, which acquires the write lock lazily and
/// can lose the SELECT-then-UPDATE race under concurrent claim
/// pressure. IMMEDIATE acquires the lock up front; the second
/// worker blocks until the first's commit, then sees the rows
/// already flipped to `running` and skips them.
pub fn claim_batch(
    conn: &Connection,
    kind: EnrichmentKind,
    limit: usize,
) -> Result<Vec<EnrichmentJob>, BtError> {
    conn.execute_batch("BEGIN IMMEDIATE")?;
    // Use a closure so we can ROLLBACK on any error.
    let result = (|| -> Result<Vec<EnrichmentJob>, BtError> {
        let job_ids: Vec<String> = {
            let mut stmt = conn.prepare(
                r#"SELECT job_id FROM pending_enrichment
                    WHERE status = 'queued' AND enrichment_kind = ?1
                    ORDER BY enqueued_at ASC
                    LIMIT ?2"#,
            )?;
            let rows = stmt.query_map(params![kind.as_str(), limit as i64], |row| row.get(0))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        if job_ids.is_empty() {
            return Ok(Vec::new());
        }
        let placeholders = vec!["?"; job_ids.len()].join(",");
        let update_sql = format!(
            "UPDATE pending_enrichment SET status='running', started_at=datetime('now'),
                attempts = attempts + 1
             WHERE status='queued' AND job_id IN ({})",
            placeholders
        );
        conn.execute(
            &update_sql,
            rusqlite::params_from_iter(job_ids.iter().map(String::as_str)),
        )?;

        let select_sql = format!(
            r#"SELECT job_id, target_kind, target_id, enrichment_kind, project_id,
                      attempts, payload_json
                FROM pending_enrichment
                WHERE job_id IN ({})
                ORDER BY enqueued_at ASC"#,
            placeholders
        );
        let mut stmt = conn.prepare(&select_sql)?;
        let mut rows = stmt.query(rusqlite::params_from_iter(job_ids.iter().map(String::as_str)))?;
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            let kind_str: String = row.get(3)?;
            let payload_json: String = row.get(6)?;
            out.push(EnrichmentJob {
                job_id: row.get(0)?,
                target_kind: row.get(1)?,
                target_id: row.get(2)?,
                enrichment_kind: EnrichmentKind::from_str(&kind_str)?,
                project_id: row.get(4)?,
                attempts: row.get(5)?,
                payload: serde_json::from_str(&payload_json).unwrap_or(serde_json::Value::Null),
            });
        }
        Ok(out)
    })();

    match result {
        Ok(jobs) => {
            conn.execute_batch("COMMIT")?;
            Ok(jobs)
        }
        Err(e) => {
            // Best-effort rollback; surface the original error.
            let _ = conn.execute_batch("ROLLBACK");
            Err(e)
        }
    }
}

/// Mark a job done.
pub fn mark_done(conn: &Connection, job_id: &str) -> Result<(), BtError> {
    conn.execute(
        r#"UPDATE pending_enrichment
            SET status='done', finished_at=datetime('now'), last_error=NULL
            WHERE job_id = ?1"#,
        params![job_id],
    )?;
    Ok(())
}

/// Mark a job failed and stash the error string. Failed jobs stay in
/// the table for `dome-eval` audit — no auto-retry, per the no-watchdog
/// rule.
pub fn mark_failed(conn: &Connection, job_id: &str, err: &str) -> Result<(), BtError> {
    conn.execute(
        r#"UPDATE pending_enrichment
            SET status='failed', finished_at=datetime('now'), last_error=?2
            WHERE job_id = ?1"#,
        params![job_id, err],
    )?;
    Ok(())
}

/// Compact summary of queue depth — handy for the Knowledge → System
/// backfill chip and for `dome-eval explain`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct QueueDepth {
    pub queued: i64,
    pub running: i64,
    pub done: i64,
    pub failed: i64,
}

pub fn queue_depth(conn: &Connection) -> Result<QueueDepth, BtError> {
    let mut stmt =
        conn.prepare("SELECT status, COUNT(*) FROM pending_enrichment GROUP BY status")?;
    let mut rows = stmt.query([])?;
    let mut depth = QueueDepth {
        queued: 0,
        running: 0,
        done: 0,
        failed: 0,
    };
    while let Some(row) = rows.next()? {
        let status: String = row.get(0)?;
        let count: i64 = row.get(1)?;
        match status.as_str() {
            "queued" => depth.queued = count,
            "running" => depth.running = count,
            "done" => depth.done = count,
            "failed" => depth.failed = count,
            _ => {}
        }
    }
    Ok(depth)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mem_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::migrations::migrate(&conn).unwrap();
        conn
    }

    #[test]
    fn enqueue_inserts_a_queued_row() {
        let conn = mem_db();
        let id = enqueue(
            &conn,
            EnrichmentTargetKind::Doc,
            "doc-1",
            EnrichmentKind::Extract,
            None,
        )
        .unwrap();
        assert!(id.starts_with("enq_"));
        let depth = queue_depth(&conn).unwrap();
        assert_eq!(depth.queued, 1);
    }

    #[test]
    fn enqueue_is_idempotent_for_pending_targets() {
        let conn = mem_db();
        let a = enqueue(
            &conn,
            EnrichmentTargetKind::Doc,
            "doc-1",
            EnrichmentKind::Extract,
            None,
        )
        .unwrap();
        let b = enqueue(
            &conn,
            EnrichmentTargetKind::Doc,
            "doc-1",
            EnrichmentKind::Extract,
            None,
        )
        .unwrap();
        assert_eq!(a, b);
        assert_eq!(queue_depth(&conn).unwrap().queued, 1);
    }

    #[test]
    fn enqueue_allows_new_job_after_done() {
        let conn = mem_db();
        let a = enqueue(
            &conn,
            EnrichmentTargetKind::Doc,
            "doc-1",
            EnrichmentKind::Extract,
            None,
        )
        .unwrap();
        mark_done(&conn, &a).unwrap();
        let b = enqueue(
            &conn,
            EnrichmentTargetKind::Doc,
            "doc-1",
            EnrichmentKind::Extract,
            None,
        )
        .unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn claim_batch_marks_running_and_returns_jobs() {
        let conn = mem_db();
        for n in 0..3 {
            enqueue(
                &conn,
                EnrichmentTargetKind::Doc,
                &format!("doc-{n}"),
                EnrichmentKind::Extract,
                None,
            )
            .unwrap();
        }
        let claimed = claim_batch(&conn, EnrichmentKind::Extract, 10).unwrap();
        assert_eq!(claimed.len(), 3);
        assert!(claimed.iter().all(|j| j.attempts == 1));
        let depth = queue_depth(&conn).unwrap();
        assert_eq!(depth.running, 3);
        assert_eq!(depth.queued, 0);
    }

    #[test]
    fn mark_failed_records_error() {
        let conn = mem_db();
        let id = enqueue(
            &conn,
            EnrichmentTargetKind::Doc,
            "doc-1",
            EnrichmentKind::Extract,
            None,
        )
        .unwrap();
        let claimed = claim_batch(&conn, EnrichmentKind::Extract, 1).unwrap();
        assert_eq!(claimed.len(), 1);
        mark_failed(&conn, &id, "boom").unwrap();
        let err: String = conn
            .query_row(
                "SELECT last_error FROM pending_enrichment WHERE job_id = ?1",
                [&id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(err, "boom");
        assert_eq!(queue_depth(&conn).unwrap().failed, 1);
    }
}
