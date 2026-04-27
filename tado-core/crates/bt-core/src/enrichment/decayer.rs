//! Decayer pass — soft-deletes stale rows by sliding `archived_at`.
//!
//! Two trigger paths:
//!
//! 1. **Explicit TTL** — when a graph_node has `expires_at` set in the
//!    past, set `archived_at = now()`. Used by Eternal/Dispatch retros
//!    that the user wants to auto-rotate after N sprints.
//!
//! 2. **Per-kind retention** — for kinds with a default retention
//!    window, archive nodes where `archived_at IS NULL AND created_at <
//!    now - retention(kind)`. Defaults are conservative; users can
//!    extend via the `dome.retention.<kind>` config knob (out of scope
//!    for v0.10 — the constants stand in for now).
//!
//! Hard delete is reserved for explicit user action via Knowledge →
//! System; the decayer never deletes rows. Soft archival means a
//! search rerank can still read the row (with a heavy demotion via
//! the supersede penalty path) for audit, but it falls below every
//! live entity.

use crate::enrichment::EnrichmentJob;
use crate::error::BtError;
use rusqlite::{params, Connection};

/// Per-kind retention window in days. None = retain forever (no
/// auto-archive path; explicit TTL via `expires_at` still applies).
fn retention_days(kind: &str) -> Option<i64> {
    match kind {
        // Stub nodes that never resolved are noise; archive after a week.
        "doc" | "file" | "agent" | "run" | "external" => None,
        // Heading-extracted typed nodes are durable.
        "decision" | "intent" | "outcome" | "caveat" => None,
        // Retros decay slowly — 18 months is "one product cycle".
        "retro" => Some(540),
        // Default: no auto-decay.
        _ => None,
    }
}

pub fn run(conn: &Connection, _job: &EnrichmentJob) -> Result<DecayReport, BtError> {
    let tx = conn.unchecked_transaction()?;
    let mut report = DecayReport::default();

    // 1. Explicit TTL.
    let ttl_archived = tx.execute(
        r#"UPDATE graph_nodes
            SET archived_at = datetime('now')
            WHERE archived_at IS NULL
              AND expires_at IS NOT NULL
              AND expires_at < datetime('now')"#,
        [],
    )?;
    report.expired_by_ttl = ttl_archived;

    // 2. Per-kind retention. We use the SQLite julianday trick to
    //    compute "older than N days" without pulling timestamps into
    //    Rust. graph_nodes has no created_at column — sort_time is
    //    set on insert and is the closest analog (the extractor
    //    populates it with `datetime('now')` on first emit and only
    //    bumps it on supersede, so older retros keep their original
    //    sort_time and age out cleanly).
    for (kind, days) in [
        ("retro", retention_days("retro")),
    ] {
        if let Some(d) = days {
            let n = tx.execute(
                r#"UPDATE graph_nodes
                    SET archived_at = datetime('now')
                    WHERE archived_at IS NULL
                      AND kind = ?1
                      AND sort_time IS NOT NULL
                      AND julianday('now') - julianday(sort_time) > ?2"#,
                params![kind, d],
            )?;
            *report.archived_by_kind.entry(kind.to_string()).or_insert(0) += n;
        }
    }

    // 3. Stub nodes that never resolved (older than 14 days) — keep
    //    the doc id around but stop them from polluting the graph.
    let stub_archived = tx.execute(
        r#"UPDATE graph_nodes
            SET archived_at = datetime('now')
            WHERE archived_at IS NULL
              AND secondary_label = 'stub'
              AND julianday('now') - julianday(sort_time) > 14"#,
        [],
    )?;
    report.archived_stubs = stub_archived;

    // 4. retrieval_log retention: drop rows older than 90 days. At
    //    a steady ~60 k rows/day this keeps the table at ~5 M rows
    //    max — an order of magnitude below where index scans
    //    degrade. Operators can tighten with a future config knob.
    let log_pruned = tx.execute(
        r#"DELETE FROM retrieval_log
            WHERE julianday('now') - julianday(created_at) > 90"#,
        [],
    )?;
    report.retrieval_log_pruned = log_pruned;

    // 5. pending_enrichment retention: drop done/failed jobs older
    //    than 30 days. Live (queued/running) jobs are never pruned —
    //    if a worker crashed mid-batch they need explicit operator
    //    cleanup, not silent deletion.
    let queue_pruned = tx.execute(
        r#"DELETE FROM pending_enrichment
            WHERE status IN ('done', 'failed')
              AND finished_at IS NOT NULL
              AND julianday('now') - julianday(finished_at) > 30"#,
        [],
    )?;
    report.pending_enrichment_pruned = queue_pruned;

    tx.commit()?;
    Ok(report)
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct DecayReport {
    pub expired_by_ttl: usize,
    pub archived_stubs: usize,
    pub archived_by_kind: std::collections::HashMap<String, usize>,
    pub retrieval_log_pruned: usize,
    pub pending_enrichment_pruned: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrichment::EnrichmentKind;

    fn mem_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::migrations::migrate(&conn).unwrap();
        conn
    }

    fn job() -> EnrichmentJob {
        EnrichmentJob {
            job_id: "j1".into(),
            target_kind: "system".into(),
            target_id: "all".into(),
            enrichment_kind: EnrichmentKind::Decay,
            project_id: None,
            attempts: 1,
            payload: serde_json::Value::Null,
        }
    }

    fn insert_node(conn: &Connection, id: &str, kind: &str, expires_at: Option<&str>, sort_time: &str) {
        conn.execute(
            r#"INSERT INTO graph_nodes(node_id, kind, ref_id, label, secondary_label,
                group_key, search_text, sort_time, payload_json, content_hash,
                entity_version, expires_at)
                VALUES (?1, ?2, ?1, ?1, NULL,
                        'p1', ?1, ?3, '{}', ?1, 1, ?4)"#,
            params![id, kind, sort_time, expires_at],
        )
        .unwrap();
    }

    #[test]
    fn archives_rows_with_expired_ttl() {
        let conn = mem_db();
        insert_node(&conn, "n1", "decision", Some("2025-01-01T00:00:00Z"), "2025-01-01T00:00:00Z");
        let report = run(&conn, &job()).unwrap();
        assert_eq!(report.expired_by_ttl, 1);
        let archived: Option<String> = conn
            .query_row("SELECT archived_at FROM graph_nodes WHERE node_id = 'n1'", [], |r| r.get(0))
            .unwrap();
        assert!(archived.is_some());
    }

    #[test]
    fn skips_rows_with_future_ttl() {
        let conn = mem_db();
        insert_node(&conn, "n1", "decision", Some("2099-01-01T00:00:00Z"), "2025-01-01T00:00:00Z");
        run(&conn, &job()).unwrap();
        let archived: Option<String> = conn
            .query_row("SELECT archived_at FROM graph_nodes WHERE node_id = 'n1'", [], |r| r.get(0))
            .unwrap();
        assert!(archived.is_none());
    }

    #[test]
    fn archives_old_stubs() {
        let conn = mem_db();
        // 30-day-old stub.
        let thirty_days_ago = chrono::Utc::now()
            .checked_sub_signed(chrono::Duration::days(30))
            .unwrap()
            .to_rfc3339();
        conn.execute(
            r#"INSERT INTO graph_nodes(node_id, kind, ref_id, label, secondary_label,
                group_key, search_text, sort_time, payload_json, content_hash, entity_version)
                VALUES ('stale_stub', 'doc', 'doc-x', 'old', 'stub',
                        'global', 'old', ?1, '{}', 'h', 1)"#,
            params![thirty_days_ago],
        )
        .unwrap();
        let report = run(&conn, &job()).unwrap();
        assert_eq!(report.archived_stubs, 1);
    }

    #[test]
    fn decay_is_idempotent() {
        let conn = mem_db();
        insert_node(&conn, "n1", "decision", Some("2025-01-01T00:00:00Z"), "2025-01-01T00:00:00Z");
        run(&conn, &job()).unwrap();
        let report = run(&conn, &job()).unwrap();
        assert_eq!(report.expired_by_ttl, 0);
    }

    #[test]
    fn prunes_retrieval_log_older_than_90_days() {
        let conn = mem_db();
        let old_ts = chrono::Utc::now()
            .checked_sub_signed(chrono::Duration::days(120))
            .unwrap()
            .to_rfc3339();
        let recent_ts = chrono::Utc::now().to_rfc3339();
        // Old + recent rows (using the columns from migration_23).
        for (id, ts) in [("old", old_ts.as_str()), ("recent", recent_ts.as_str())] {
            conn.execute(
                r#"INSERT INTO retrieval_log (
                    log_id, created_at, actor_kind, knowledge_scope, tool,
                    query, result_ids_json, result_scopes_json, latency_ms
                ) VALUES (?1, ?2, 'agent', 'project', 'dome_search', ?1, '[]', '[]', 0)"#,
                params![id, ts],
            )
            .unwrap();
        }
        let report = run(&conn, &job()).unwrap();
        assert_eq!(report.retrieval_log_pruned, 1);
        let remaining: i64 = conn
            .query_row("SELECT COUNT(*) FROM retrieval_log", [], |r| r.get(0))
            .unwrap();
        assert_eq!(remaining, 1);
    }

    #[test]
    fn prunes_finished_pending_enrichment_older_than_30_days() {
        let conn = mem_db();
        let old_ts = chrono::Utc::now()
            .checked_sub_signed(chrono::Duration::days(60))
            .unwrap()
            .to_rfc3339();
        let recent_ts = chrono::Utc::now().to_rfc3339();
        // Old finished, recent finished, old queued. Only old finished prunes.
        conn.execute(
            r#"INSERT INTO pending_enrichment (job_id, target_kind, target_id,
                enrichment_kind, status, finished_at, enqueued_at)
                VALUES ('old_done', 'doc', 'd1', 'extract', 'done', ?1, ?1)"#,
            params![old_ts],
        )
        .unwrap();
        conn.execute(
            r#"INSERT INTO pending_enrichment (job_id, target_kind, target_id,
                enrichment_kind, status, finished_at, enqueued_at)
                VALUES ('recent_done', 'doc', 'd2', 'extract', 'done', ?1, ?1)"#,
            params![recent_ts],
        )
        .unwrap();
        conn.execute(
            r#"INSERT INTO pending_enrichment (job_id, target_kind, target_id,
                enrichment_kind, status, enqueued_at)
                VALUES ('old_queued', 'doc', 'd3', 'extract', 'queued', ?1)"#,
            params![old_ts],
        )
        .unwrap();
        let report = run(&conn, &job()).unwrap();
        assert_eq!(report.pending_enrichment_pruned, 1);
        let remaining: Vec<String> = conn
            .prepare("SELECT job_id FROM pending_enrichment ORDER BY job_id")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(remaining, vec!["old_queued".to_string(), "recent_done".to_string()]);
    }
}
