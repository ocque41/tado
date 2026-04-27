//! Linker pass — resolves dangling stub nodes emitted by the extractor.
//!
//! When the extractor encounters a `[label](dome://note/<id>)` link
//! inside doc A but doc B (the linked note) hasn't been extracted yet
//! (or doesn't exist), it writes a *stub* `graph_nodes` row keyed by
//! a deterministic hash of the target. The linker re-walks all stub
//! rows on its turn and rewrites their edges to point at the real
//! node when one materialises with a matching `ref_id`.
//!
//! Resolution rules:
//! - **note stub** (`kind='doc'`, `ref_id=<external_id>`) → if any
//!   non-stub graph_node has matching `ref_id`, redirect every edge
//!   pointing at the stub to the canonical node and mark the stub
//!   archived.
//! - **file stub** — file nodes are already canonical (one node per
//!   path); nothing to do beyond cleaning duplicate stubs.
//! - **agent stub** — same; promote to canonical when the matching
//!   agent_status_snapshot lands.
//!
//! Idempotent: re-running on the same DB is a no-op once stubs are
//! resolved.

use crate::enrichment::EnrichmentJob;
use crate::error::BtError;
use rusqlite::{params, Connection};

pub fn run(conn: &Connection, _job: &EnrichmentJob) -> Result<LinkReport, BtError> {
    let tx = conn.unchecked_transaction()?;
    let mut report = LinkReport::default();

    // Find every stub graph_node and try to resolve.
    let stub_rows: Vec<(String, String, String)> = {
        let mut stmt = tx.prepare(
            r#"SELECT node_id, kind, ref_id
                 FROM graph_nodes
                WHERE secondary_label = 'stub'
                  AND archived_at IS NULL"#,
        )?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };

    for (stub_id, kind, ref_id) in stub_rows {
        // Find a canonical (non-stub) node with matching kind + ref_id.
        let canonical: Option<String> = tx
            .query_row(
                r#"SELECT node_id FROM graph_nodes
                    WHERE kind = ?1 AND ref_id = ?2
                      AND (secondary_label IS NULL OR secondary_label != 'stub')
                      AND archived_at IS NULL
                    LIMIT 1"#,
                params![kind, ref_id],
                |row| row.get(0),
            )
            .ok();

        // For "doc" stubs, also try matching docs.id directly — the
        // doc may exist as a row but not yet be extracted.
        let canonical = canonical.or_else(|| {
            if kind == "doc" {
                tx.query_row(
                    "SELECT id FROM docs WHERE id = ?1 LIMIT 1",
                    params![ref_id],
                    |row| row.get::<_, String>(0),
                )
                .ok()
            } else {
                None
            }
        });

        let Some(canonical_id) = canonical else {
            continue;
        };
        if canonical_id == stub_id {
            continue;
        }

        // Redirect every edge pointing at the stub to the canonical id.
        let redirected_in = tx.execute(
            "UPDATE graph_edges SET target_id = ?1 WHERE target_id = ?2",
            params![canonical_id, stub_id],
        )?;
        let redirected_out = tx.execute(
            "UPDATE graph_edges SET source_id = ?1 WHERE source_id = ?2",
            params![canonical_id, stub_id],
        )?;
        report.edges_redirected += (redirected_in + redirected_out);

        // Soft-archive the stub.
        tx.execute(
            "UPDATE graph_nodes SET archived_at = datetime('now') WHERE node_id = ?1",
            params![stub_id],
        )?;
        report.stubs_resolved += 1;
    }

    tx.commit()?;
    Ok(report)
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct LinkReport {
    pub stubs_resolved: usize,
    pub edges_redirected: usize,
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
            enrichment_kind: EnrichmentKind::Link,
            project_id: None,
            attempts: 1,
            payload: serde_json::Value::Null,
        }
    }

    #[test]
    fn resolves_doc_stub_to_canonical_node() {
        let conn = mem_db();
        // Stub created by the extractor for a forward reference.
        conn.execute(
            r#"INSERT INTO graph_nodes(node_id, kind, ref_id, label, secondary_label,
                group_key, search_text, sort_time, payload_json, content_hash, entity_version)
                VALUES ('stub_x', 'doc', 'doc-real', 'old retro', 'stub',
                        'global', 'old retro', datetime('now'), '{}', 'h1', 1)"#,
            [],
        )
        .unwrap();
        // Edge pointing at the stub.
        conn.execute(
            r#"INSERT INTO graph_edges(edge_id, kind, source_id, target_id,
                search_text, sort_time, payload_json,
                source_signal, signal_confidence, evidence_id)
                VALUES ('e1', 'references', 'doc-source', 'stub_x',
                        'references', datetime('now'), '{}',
                        'deterministic_extract', 0.85, NULL)"#,
            [],
        )
        .unwrap();
        // Real doc landed.
        conn.execute(
            r#"INSERT INTO docs(id, topic, slug, title, user_path, agent_path,
                created_at, updated_at, user_hash, agent_hash,
                owner_scope, project_id, project_root, knowledge_kind)
                VALUES ('doc-real', 'inbox', 's', 't', 'a.md', 'b.md',
                        '2026-04-25T00:00:00Z', '2026-04-25T00:00:00Z',
                        '0', '0', 'global', NULL, NULL, 'knowledge')"#,
            [],
        )
        .unwrap();

        let report = run(&conn, &job()).unwrap();
        assert_eq!(report.stubs_resolved, 1);
        assert_eq!(report.edges_redirected, 1);

        let new_target: String = conn
            .query_row("SELECT target_id FROM graph_edges WHERE edge_id = 'e1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(new_target, "doc-real");

        let stub_archived: Option<String> = conn
            .query_row(
                "SELECT archived_at FROM graph_nodes WHERE node_id = 'stub_x'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(stub_archived.is_some());
    }

    #[test]
    fn linker_is_noop_on_clean_db() {
        let conn = mem_db();
        let report = run(&conn, &job()).unwrap();
        assert_eq!(report.stubs_resolved, 0);
        assert_eq!(report.edges_redirected, 0);
    }
}
