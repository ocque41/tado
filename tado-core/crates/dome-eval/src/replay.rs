//! `dome-eval replay` — replay logged retrievals against a vault.
//!
//! Reads every `retrieval_log` row in the time window, decodes the
//! ranked result list + scopes, and computes precision@k / recall@k /
//! nDCG using the implicit `was_consumed` ground-truth signal: a result
//! is "relevant" if the row was eventually consumed (an
//! `agent_used_context` event flipped `was_consumed = 1`).
//!
//! Limitations:
//! - Implicit feedback only — `was_consumed` is at the *log row* grain,
//!   not per-result. We treat the whole result set as relevant when the
//!   row was consumed; this overstates precision but is the correct
//!   regression signal (a ranking change that breaks consumption shows
//!   up immediately).
//! - Rows older than the daily NDJSON rotation are not reachable; the
//!   in-process daemon is the only writer of `retrieval_log` so this
//!   stays in scope of the live SQLite file.

use anyhow::{Context, Result};
use chrono::{DateTime, Duration, Utc};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

use crate::{
    precision_at_k, recall_at_k, ndcg_at_k, AggregateMetrics, PerCaseMetrics,
};

/// One decoded row of `retrieval_log`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplayRow {
    pub log_id: String,
    pub created_at: String,
    pub actor_kind: String,
    pub tool: String,
    pub query: String,
    pub knowledge_scope: String,
    pub project_id: Option<String>,
    pub result_ids: Vec<String>,
    pub result_scopes: Vec<String>,
    pub latency_ms: i64,
    pub was_consumed: bool,
    pub pack_id: Option<String>,
}

/// `replay` summary: per-row metrics + aggregate plus the consumption
/// rate (fraction of logged calls whose pack was actually used).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplayReport {
    pub window_start: Option<String>,
    pub window_end: Option<String>,
    pub n_rows: usize,
    pub consumption_rate: f64,
    pub mean_latency_ms: f64,
    pub aggregate: AggregateMetrics,
    pub rows: Vec<PerCaseMetrics>,
}

/// Replay the last `since` worth of `retrieval_log`. `since = None` →
/// every row in the table.
pub fn replay(conn: &Connection, since: Option<Duration>) -> Result<ReplayReport> {
    let cutoff = since.map(|d| Utc::now() - d);
    let raw = load_rows(conn, cutoff)?;

    if raw.is_empty() {
        return Ok(ReplayReport {
            window_start: cutoff.map(|c| c.to_rfc3339()),
            window_end: Some(Utc::now().to_rfc3339()),
            n_rows: 0,
            consumption_rate: 0.0,
            mean_latency_ms: 0.0,
            aggregate: AggregateMetrics::from_per_case(&[]),
            rows: Vec::new(),
        });
    }

    let consumed = raw.iter().filter(|r| r.was_consumed).count();
    let consumption_rate = consumed as f64 / raw.len() as f64;
    let mean_latency_ms =
        raw.iter().map(|r| r.latency_ms as f64).sum::<f64>() / raw.len() as f64;

    let per_case: Vec<PerCaseMetrics> = raw
        .iter()
        .map(|r| {
            // Implicit relevance: if the row was consumed, the entire
            // ranked list is "relevant" for precision purposes
            // (consumption means the agent acted on this pack). If
            // not, treat as no relevant — the case contributes 0 to
            // precision and recall, which is what we want: stale
            // rankings that don't lead to consumption pull metrics
            // down.
            let relevant: HashSet<String> = if r.was_consumed {
                r.result_ids.iter().cloned().collect()
            } else {
                HashSet::new()
            };
            PerCaseMetrics {
                case_id: r.log_id.clone(),
                query: r.query.clone(),
                precision_at_5: precision_at_k(&r.result_ids, &relevant, 5),
                precision_at_10: precision_at_k(&r.result_ids, &relevant, 10),
                recall_at_10: recall_at_k(&r.result_ids, &relevant, 10),
                ndcg_at_10: ndcg_at_k(&r.result_ids, &relevant, 10),
                top1_freshness: 0.0, // replay does not pull doc metadata; explain does
                retrieved: r.result_ids.clone(),
                relevant: relevant.into_iter().collect(),
            }
        })
        .collect();

    Ok(ReplayReport {
        window_start: cutoff.map(|c| c.to_rfc3339()),
        window_end: Some(Utc::now().to_rfc3339()),
        n_rows: raw.len(),
        consumption_rate,
        mean_latency_ms,
        aggregate: AggregateMetrics::from_per_case(&per_case),
        rows: per_case,
    })
}

fn load_rows(conn: &Connection, cutoff: Option<DateTime<Utc>>) -> Result<Vec<ReplayRow>> {
    let sql = match cutoff {
        Some(_) => {
            r#"SELECT log_id, created_at, actor_kind, tool, query,
                       knowledge_scope, project_id, result_ids_json,
                       result_scopes_json, latency_ms, was_consumed, pack_id
                FROM retrieval_log
                WHERE created_at >= ?1
                ORDER BY created_at ASC"#
        }
        None => {
            r#"SELECT log_id, created_at, actor_kind, tool, query,
                       knowledge_scope, project_id, result_ids_json,
                       result_scopes_json, latency_ms, was_consumed, pack_id
                FROM retrieval_log
                ORDER BY created_at ASC"#
        }
    };

    let mut stmt = conn.prepare(sql)?;
    let mapper = |row: &rusqlite::Row<'_>| -> rusqlite::Result<(
        String,
        String,
        String,
        String,
        Option<String>,
        String,
        Option<String>,
        String,
        String,
        i64,
        i64,
        Option<String>,
    )> {
        Ok((
            row.get(0)?,
            row.get(1)?,
            row.get(2)?,
            row.get(3)?,
            row.get::<_, Option<String>>(4)?,
            row.get(5)?,
            row.get::<_, Option<String>>(6)?,
            row.get(7)?,
            row.get(8)?,
            row.get(9)?,
            row.get(10)?,
            row.get::<_, Option<String>>(11)?,
        ))
    };

    let raw_rows: Vec<_> = if let Some(c) = cutoff {
        let cs = c.to_rfc3339();
        stmt.query_map([cs], mapper)?.collect::<Result<Vec<_>, _>>()?
    } else {
        stmt.query_map([], mapper)?.collect::<Result<Vec<_>, _>>()?
    };

    let mut out = Vec::with_capacity(raw_rows.len());
    for (
        log_id,
        created_at,
        actor_kind,
        tool,
        query,
        knowledge_scope,
        project_id,
        result_ids_json,
        result_scopes_json,
        latency_ms,
        was_consumed,
        pack_id,
    ) in raw_rows
    {
        let result_ids: Vec<String> = serde_json::from_str(&result_ids_json)
            .with_context(|| format!("decoding result_ids_json for log {}", log_id))?;
        let result_scopes: Vec<String> = serde_json::from_str(&result_scopes_json)
            .with_context(|| format!("decoding result_scopes_json for log {}", log_id))?;
        out.push(ReplayRow {
            log_id,
            created_at,
            actor_kind,
            tool,
            query: query.unwrap_or_default(),
            knowledge_scope,
            project_id,
            result_ids,
            result_scopes,
            latency_ms,
            was_consumed: was_consumed != 0,
            pack_id,
        });
    }

    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mem_db_with_log() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE retrieval_log (
                log_id              TEXT PRIMARY KEY,
                created_at          TEXT NOT NULL DEFAULT (datetime('now')),
                actor_kind          TEXT NOT NULL,
                actor_id            TEXT,
                project_id          TEXT,
                knowledge_scope     TEXT NOT NULL,
                tool                TEXT NOT NULL,
                query               TEXT,
                result_ids_json     TEXT NOT NULL DEFAULT '[]',
                result_scopes_json  TEXT NOT NULL DEFAULT '[]',
                latency_ms          INTEGER NOT NULL DEFAULT 0,
                pack_id             TEXT,
                was_consumed        INTEGER NOT NULL DEFAULT 0
            );
            "#,
        )
        .unwrap();
        conn
    }

    #[test]
    fn replay_empty_log_returns_zero() {
        let conn = mem_db_with_log();
        let report = replay(&conn, None).unwrap();
        assert_eq!(report.n_rows, 0);
        assert_eq!(report.consumption_rate, 0.0);
        assert_eq!(report.aggregate.n_cases, 0);
    }

    #[test]
    fn replay_counts_consumption_rate() {
        let conn = mem_db_with_log();
        conn.execute(
            r#"INSERT INTO retrieval_log (log_id, actor_kind, knowledge_scope, tool,
                query, result_ids_json, result_scopes_json, latency_ms, was_consumed)
               VALUES ('l1','agent','project','dome_search','q1','["d1","d2"]','["user","user"]',12,1)"#,
            [],
        )
        .unwrap();
        conn.execute(
            r#"INSERT INTO retrieval_log (log_id, actor_kind, knowledge_scope, tool,
                query, result_ids_json, result_scopes_json, latency_ms, was_consumed)
               VALUES ('l2','agent','project','dome_search','q2','["d3"]','["user"]',8,0)"#,
            [],
        )
        .unwrap();
        let report = replay(&conn, None).unwrap();
        assert_eq!(report.n_rows, 2);
        assert!((report.consumption_rate - 0.5).abs() < 1e-9);
        assert_eq!(report.aggregate.n_cases, 2);
        assert!((report.mean_latency_ms - 10.0).abs() < 1e-9);
        // Consumed row: top-2 fully relevant → P@5 = 2/2.
        // Unconsumed row: empty relevant → P@5 = 0.
        assert!((report.aggregate.mean_precision_at_5 - 0.5).abs() < 1e-9);
    }

    #[test]
    fn replay_handles_malformed_json_gracefully() {
        let conn = mem_db_with_log();
        conn.execute(
            r#"INSERT INTO retrieval_log (log_id, actor_kind, knowledge_scope, tool,
                query, result_ids_json, result_scopes_json, latency_ms, was_consumed)
               VALUES ('bad','agent','project','dome_search','q','not_json','[]',0,0)"#,
            [],
        )
        .unwrap();
        let err = replay(&conn, None).unwrap_err();
        assert!(err.to_string().contains("decoding result_ids_json"));
    }
}
