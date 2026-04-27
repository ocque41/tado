//! Deduper pass — chains duplicate entities via supersede edges.
//!
//! Two paths:
//! 1. **Content-hash exact match**: any pair of `graph_nodes` with the
//!    same `content_hash`, same `kind`, same `project_id` (NULL counts
//!    as global), where neither is `archived_at`. The older row is
//!    marked `superseded_by = newer.node_id`; the newer row's
//!    `supersedes` mirrors the back-link. A `supersedes` edge is
//!    written with `source_signal='deterministic_extract'`. Audit-only
//!    — both rows survive so search can demote the old one without
//!    losing it.
//!
//! 2. **Embedding cosine ≥ 0.95**: deferred to a future pass once
//!    `graph_nodes.embedding` is populated by the extractor (extractor
//!    in v0.10 doesn't embed graph_node bodies — that lands in the
//!    same release as the deduper hooking into the runtime). The
//!    structural fields (`source_signal='agent_assertion'`,
//!    `signal_confidence=0.85`) are reserved.
//!
//! Idempotent — re-running on a chain leaves it unchanged because the
//! `supersedes/superseded_by` columns are already set.

use crate::enrichment::EnrichmentJob;
use crate::error::BtError;
use rusqlite::{params, Connection};
use sha2::{Digest, Sha256};

pub fn run(conn: &Connection, _job: &EnrichmentJob) -> Result<DedupeReport, BtError> {
    let tx = conn.unchecked_transaction()?;
    let mut report = DedupeReport::default();

    // Group candidates by (content_hash, kind, COALESCE(project_id, '__global__')).
    // Within each group, sort by sort_time ASC so the newest wins.
    let mut stmt = tx.prepare(
        r#"SELECT content_hash, kind, COALESCE(group_key, '__global__'), node_id, sort_time
             FROM graph_nodes
            WHERE content_hash IS NOT NULL
              AND content_hash != ''
              AND archived_at IS NULL
              AND superseded_by IS NULL
              AND (secondary_label IS NULL OR secondary_label != 'stub')
            ORDER BY content_hash, kind, sort_time ASC"#,
    )?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<String>>(4)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    drop(stmt);

    // Walk in groups.
    let mut current_key: Option<(String, String, String)> = None;
    let mut buffer: Vec<(String, Option<String>)> = Vec::new();

    for (hash, kind, group_key, node_id, sort_time) in rows {
        let key = (hash.clone(), kind.clone(), group_key.clone());
        if Some(&key) != current_key.as_ref() {
            if buffer.len() >= 2 {
                report = chain_supersede_group(&tx, &buffer, report)?;
            }
            buffer.clear();
            current_key = Some(key);
        }
        buffer.push((node_id, sort_time));
    }
    if buffer.len() >= 2 {
        report = chain_supersede_group(&tx, &buffer, report)?;
    }

    tx.commit()?;
    Ok(report)
}

fn chain_supersede_group(
    conn: &Connection,
    group: &[(String, Option<String>)],
    mut report: DedupeReport,
) -> Result<DedupeReport, BtError> {
    // Group is sorted ascending by sort_time. Last is newest.
    let newest = &group[group.len() - 1].0;
    for (older, _) in &group[..group.len() - 1] {
        // Skip self-pairs (shouldn't happen but defensive).
        if older == newest {
            continue;
        }
        // Mark older as superseded.
        let updated = conn.execute(
            r#"UPDATE graph_nodes
                SET superseded_by = ?1
                WHERE node_id = ?2
                  AND superseded_by IS NULL"#,
            params![newest, older],
        )?;
        if updated == 0 {
            continue; // Already chained.
        }
        // Mirror the back-link.
        conn.execute(
            r#"UPDATE graph_nodes
                SET supersedes = COALESCE(supersedes, ?1)
                WHERE node_id = ?2"#,
            params![older, newest],
        )?;
        // Emit a supersedes edge for the graph view.
        let edge_id = format!("edge_{}", short_hash(&format!("supersede:{older}->{newest}")));
        conn.execute(
            r#"INSERT INTO graph_edges(edge_id, kind, source_id, target_id,
                search_text, sort_time, payload_json,
                source_signal, signal_confidence, evidence_id)
                VALUES (?1, 'supersedes', ?2, ?3,
                        'supersedes', datetime('now'), '{}',
                        'deterministic_extract', 0.95, NULL)
                ON CONFLICT(edge_id) DO NOTHING"#,
            params![edge_id, newest, older],
        )?;
        report.pairs_chained += 1;
    }
    Ok(report)
}

fn short_hash(s: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(s.as_bytes());
    let hex = format!("{:x}", hasher.finalize());
    hex[..16].to_string()
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct DedupeReport {
    pub pairs_chained: usize,
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
            enrichment_kind: EnrichmentKind::Dedupe,
            project_id: None,
            attempts: 1,
            payload: serde_json::Value::Null,
        }
    }

    fn insert_node(conn: &Connection, id: &str, hash: &str, sort_time: &str) {
        conn.execute(
            r#"INSERT INTO graph_nodes(node_id, kind, ref_id, label, secondary_label,
                group_key, search_text, sort_time, payload_json, content_hash, entity_version)
                VALUES (?1, 'decision', ?1, ?1, NULL,
                        'p1', ?1, ?2, '{}', ?3, 1)"#,
            params![id, sort_time, hash],
        )
        .unwrap();
    }

    #[test]
    fn chains_duplicates_by_content_hash() {
        let conn = mem_db();
        insert_node(&conn, "old", "h-same", "2026-04-20T00:00:00Z");
        insert_node(&conn, "newer", "h-same", "2026-04-25T00:00:00Z");
        let report = run(&conn, &job()).unwrap();
        assert_eq!(report.pairs_chained, 1);
        let superseded_by: String = conn
            .query_row(
                "SELECT superseded_by FROM graph_nodes WHERE node_id = 'old'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(superseded_by, "newer");
        let supersedes: String = conn
            .query_row(
                "SELECT supersedes FROM graph_nodes WHERE node_id = 'newer'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(supersedes, "old");
    }

    #[test]
    fn dedupe_is_idempotent() {
        let conn = mem_db();
        insert_node(&conn, "a", "h", "2026-04-20T00:00:00Z");
        insert_node(&conn, "b", "h", "2026-04-25T00:00:00Z");
        run(&conn, &job()).unwrap();
        let report = run(&conn, &job()).unwrap();
        assert_eq!(report.pairs_chained, 0);
    }

    #[test]
    fn dedupe_skips_archived() {
        let conn = mem_db();
        insert_node(&conn, "old", "h", "2026-04-20T00:00:00Z");
        insert_node(&conn, "newer", "h", "2026-04-25T00:00:00Z");
        conn.execute(
            "UPDATE graph_nodes SET archived_at = datetime('now') WHERE node_id = 'old'",
            [],
        )
        .unwrap();
        let report = run(&conn, &job()).unwrap();
        assert_eq!(report.pairs_chained, 0);
    }

    #[test]
    fn dedupe_emits_supersedes_edge() {
        let conn = mem_db();
        insert_node(&conn, "old", "h", "2026-04-20T00:00:00Z");
        insert_node(&conn, "newer", "h", "2026-04-25T00:00:00Z");
        run(&conn, &job()).unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM graph_edges WHERE kind = 'supersedes' AND source_id = 'newer'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }
}
