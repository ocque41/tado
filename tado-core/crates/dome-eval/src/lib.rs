//! Measurable retrieval evaluation for Tado's Dome second brain.
//!
//! Three primitives:
//!
//! - [`Corpus`] — load a hand-labeled set of `(query, scope, relevant)`
//!   cases from a YAML fixture, run them against a freshly seeded vault,
//!   compute precision@k / recall / nDCG, and report pass/fail against
//!   per-corpus thresholds. CI gate.
//!
//! - [`replay`] — read every `retrieval_log` row from a real vault,
//!   recompute precision@k against the implicit `was_consumed` ground
//!   truth signal, and emit a regression-friendly summary. Operations
//!   tool.
//!
//! - [`explain`] — for a single `retrieval_log` row, reconstruct the
//!   per-result ranking decision: vector score, lexical score,
//!   freshness multiplier, scope-match multiplier, confidence
//!   multiplier, supersede penalty, final combined_score. The "why is
//!   this answer first?" tool.
//!
//! Phase 2 of the Knowledge Catalog upgrade. Phase 3 wires `dome-eval`
//! into CI; Phase 4+ uses it as the safety net before any rerank
//! tweak ships.

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::Path;

pub mod corpus;
pub mod replay;

pub use corpus::{Corpus, CorpusCase, CorpusReport, CorpusResult, CorpusThresholds};
pub use replay::{ReplayReport, ReplayRow};

/// Open an existing Dome vault SQLite file in read-only mode.
///
/// `dome-eval replay` and `dome-eval explain` only read — they never
/// mutate the live vault, so they refuse write access at the SQLite
/// layer. Corpus runs create their own in-memory DB instead.
pub fn open_vault_readonly(vault_db: &Path) -> Result<Connection> {
    let uri = format!(
        "file:{}?mode=ro",
        vault_db
            .to_str()
            .ok_or_else(|| anyhow!("vault path is not valid UTF-8: {:?}", vault_db))?
    );
    let conn = Connection::open_with_flags(
        &uri,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    )
    .with_context(|| format!("opening vault read-only at {}", vault_db.display()))?;
    Ok(conn)
}

/// In-process convenience entry for the v0.12+ `tado_dome_eval_replay`
/// FFI shim. Opens the vault read-only, runs `replay::replay`, and
/// returns the report — no subprocess, no PATH dependency, no extra
/// Cargo binary on disk.
///
/// `since_seconds <= 0` → replay every row in `retrieval_log`.
pub fn replay_for_vault(
    vault_db: &Path,
    since_seconds: i64,
) -> Result<replay::ReplayReport> {
    let conn = open_vault_readonly(vault_db)?;
    let since = if since_seconds > 0 {
        Some(chrono::Duration::seconds(since_seconds))
    } else {
        None
    };
    replay::replay(&conn, since)
}

/// Precision@k — fraction of the top-k results that are relevant.
pub fn precision_at_k<T: Eq + std::hash::Hash>(retrieved: &[T], relevant: &HashSet<T>, k: usize) -> f64 {
    if k == 0 {
        return 0.0;
    }
    let cutoff = retrieved.len().min(k);
    if cutoff == 0 {
        return 0.0;
    }
    let hits = retrieved.iter().take(cutoff).filter(|r| relevant.contains(r)).count();
    hits as f64 / cutoff as f64
}

/// Recall@k — fraction of relevant results that appear in top-k.
pub fn recall_at_k<T: Eq + std::hash::Hash>(retrieved: &[T], relevant: &HashSet<T>, k: usize) -> f64 {
    if relevant.is_empty() {
        return 0.0;
    }
    let cutoff = retrieved.len().min(k);
    let hits = retrieved.iter().take(cutoff).filter(|r| relevant.contains(r)).count();
    hits as f64 / relevant.len() as f64
}

/// nDCG@k with binary relevance (relevant = 1, non-relevant = 0).
///
/// Useful for ranking-quality regression because it's sensitive to
/// position — moving a relevant doc from rank 5 to rank 1 lifts the
/// score, while precision@5 stays the same.
pub fn ndcg_at_k<T: Eq + std::hash::Hash>(retrieved: &[T], relevant: &HashSet<T>, k: usize) -> f64 {
    if k == 0 || relevant.is_empty() {
        return 0.0;
    }
    let cutoff = retrieved.len().min(k);
    let dcg: f64 = retrieved
        .iter()
        .take(cutoff)
        .enumerate()
        .map(|(i, r)| {
            let rel = if relevant.contains(r) { 1.0 } else { 0.0 };
            // gain = (2^rel - 1) / log2(i+2). For binary rel it simplifies.
            rel / ((i as f64 + 2.0).log2())
        })
        .sum();
    // Ideal DCG: all relevant docs at the top.
    let ideal_count = relevant.len().min(k);
    let idcg: f64 = (0..ideal_count).map(|i| 1.0 / ((i as f64 + 2.0).log2())).sum();
    if idcg == 0.0 {
        0.0
    } else {
        dcg / idcg
    }
}

/// Aggregate per-query metrics into a corpus-level summary.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AggregateMetrics {
    pub n_cases: usize,
    pub mean_precision_at_5: f64,
    pub mean_precision_at_10: f64,
    pub mean_recall_at_10: f64,
    pub mean_ndcg_at_10: f64,
    /// Mean freshness of returned hits — captures whether reranking is
    /// actually keeping the corpus fresh-leaning.
    pub mean_top1_freshness: f64,
}

impl AggregateMetrics {
    pub fn from_per_case(per_case: &[PerCaseMetrics]) -> Self {
        if per_case.is_empty() {
            return Self {
                n_cases: 0,
                mean_precision_at_5: 0.0,
                mean_precision_at_10: 0.0,
                mean_recall_at_10: 0.0,
                mean_ndcg_at_10: 0.0,
                mean_top1_freshness: 0.0,
            };
        }
        let n = per_case.len() as f64;
        let mean = |f: fn(&PerCaseMetrics) -> f64| -> f64 {
            per_case.iter().map(f).sum::<f64>() / n
        };
        Self {
            n_cases: per_case.len(),
            mean_precision_at_5: mean(|c| c.precision_at_5),
            mean_precision_at_10: mean(|c| c.precision_at_10),
            mean_recall_at_10: mean(|c| c.recall_at_10),
            mean_ndcg_at_10: mean(|c| c.ndcg_at_10),
            mean_top1_freshness: mean(|c| c.top1_freshness),
        }
    }
}

/// Per-query metrics emitted by both `replay` and `corpus run`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PerCaseMetrics {
    pub case_id: String,
    pub query: String,
    pub precision_at_5: f64,
    pub precision_at_10: f64,
    pub recall_at_10: f64,
    pub ndcg_at_10: f64,
    /// Freshness score of the top-1 hit (or 0.0 if no hits).
    pub top1_freshness: f64,
    pub retrieved: Vec<String>,
    pub relevant: Vec<String>,
}

/// Pretty-print an `AggregateMetrics` as a one-line summary.
pub fn format_summary(label: &str, agg: &AggregateMetrics) -> String {
    format!(
        "{label}: n={} P@5={:.3} P@10={:.3} R@10={:.3} nDCG@10={:.3} top1_freshness={:.3}",
        agg.n_cases,
        agg.mean_precision_at_5,
        agg.mean_precision_at_10,
        agg.mean_recall_at_10,
        agg.mean_ndcg_at_10,
        agg.mean_top1_freshness
    )
}

/// Resolve a `retrieval_log` row by id and pull the data needed for
/// [`explain`]. Returns `None` if the row doesn't exist.
pub fn fetch_log_row(conn: &Connection, log_id: &str) -> Result<Option<ExplainSeed>> {
    let row = conn
        .query_row(
            r#"SELECT log_id, created_at, actor_kind, actor_id, project_id,
                       knowledge_scope, tool, query, result_ids_json,
                       result_scopes_json, latency_ms, pack_id, was_consumed
                FROM retrieval_log WHERE log_id = ?1"#,
            [log_id],
            |row| {
                Ok(ExplainSeed {
                    log_id: row.get(0)?,
                    created_at: row.get(1)?,
                    actor_kind: row.get(2)?,
                    actor_id: row.get(3)?,
                    project_id: row.get(4)?,
                    knowledge_scope: row.get(5)?,
                    tool: row.get(6)?,
                    query: row.get::<_, Option<String>>(7)?.unwrap_or_default(),
                    result_ids_json: row.get(8)?,
                    result_scopes_json: row.get(9)?,
                    latency_ms: row.get(10)?,
                    pack_id: row.get(11)?,
                    was_consumed: row.get::<_, i64>(12)? != 0,
                })
            },
        )
        .optional()?;
    Ok(row)
}

/// Raw retrieval-log payload used by `explain`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExplainSeed {
    pub log_id: String,
    pub created_at: String,
    pub actor_kind: String,
    pub actor_id: Option<String>,
    pub project_id: Option<String>,
    pub knowledge_scope: String,
    pub tool: String,
    pub query: String,
    pub result_ids_json: String,
    pub result_scopes_json: String,
    pub latency_ms: i64,
    pub pack_id: Option<String>,
    pub was_consumed: bool,
}

/// Per-result decision row produced by `explain`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExplainRow {
    pub rank: usize,
    pub doc_id: String,
    pub scope: String,
    pub title: Option<String>,
    pub topic: Option<String>,
    pub updated_at: Option<String>,
    pub last_referenced_at: Option<String>,
    pub confidence: Option<f64>,
    pub superseded_by: Option<String>,
    pub freshness: f64,
    pub scope_match: f64,
    pub supersede_penalty: f64,
}

/// Reconstruct the rerank decision for one logged query.
///
/// Pulls each result's metadata from `docs` + `graph_nodes` and recomputes
/// the multipliers `hybrid_search` would have applied on the call.
pub fn explain(conn: &Connection, log_id: &str) -> Result<(ExplainSeed, Vec<ExplainRow>)> {
    let seed = fetch_log_row(conn, log_id)?
        .ok_or_else(|| anyhow!("retrieval_log row not found: {}", log_id))?;
    let result_ids: Vec<String> = serde_json::from_str(&seed.result_ids_json)
        .with_context(|| format!("decoding result_ids_json for log {}", seed.log_id))?;
    let result_scopes: Vec<String> = serde_json::from_str(&seed.result_scopes_json)
        .with_context(|| format!("decoding result_scopes_json for log {}", seed.log_id))?;

    let now: DateTime<Utc> = DateTime::parse_from_rfc3339(&seed.created_at)
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or_else(|_| Utc::now());

    let preferred_scope = match seed.knowledge_scope.as_str() {
        "project" | "merged" => Some("user".to_string()),
        _ => None,
    };

    let mut rows = Vec::with_capacity(result_ids.len());
    for (idx, doc_id) in result_ids.iter().enumerate() {
        let scope = result_scopes.get(idx).cloned().unwrap_or_else(|| "user".into());

        let doc_meta: Option<(Option<String>, Option<String>, Option<String>, Option<String>)> = conn
            .query_row(
                "SELECT topic, title, updated_at, created_at FROM docs WHERE id = ?1",
                [doc_id],
                |r| {
                    Ok((
                        r.get::<_, Option<String>>(0)?,
                        r.get::<_, Option<String>>(1)?,
                        r.get::<_, Option<String>>(2)?,
                        r.get::<_, Option<String>>(3)?,
                    ))
                },
            )
            .optional()?;

        let node_meta: Option<(Option<String>, Option<f64>, Option<String>)> = conn
            .query_row(
                r#"SELECT last_referenced_at, confidence, superseded_by
                   FROM graph_nodes WHERE ref_id = ?1
                   ORDER BY sort_time DESC LIMIT 1"#,
                [doc_id],
                |r| {
                    Ok((
                        r.get::<_, Option<String>>(0)?,
                        r.get::<_, Option<f64>>(1)?,
                        r.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .optional()?;

        let (topic, title, updated_at, created_at) = doc_meta
            .unwrap_or((None, None, None, None));
        let (last_referenced_at, confidence, superseded_by) = node_meta
            .unwrap_or((None, None, None));

        let freshness = bt_core::notes::freshness_score(
            updated_at.as_deref(),
            last_referenced_at.as_deref(),
            created_at.as_deref(),
            now,
        ) as f64;
        let scope_match = match &preferred_scope {
            Some(s) if s == &scope => 1.0,
            Some(_) => 0.6,
            None => 1.0,
        };
        let supersede_penalty = if superseded_by.is_some() { 0.3 } else { 1.0 };

        rows.push(ExplainRow {
            rank: idx + 1,
            doc_id: doc_id.clone(),
            scope,
            title,
            topic,
            updated_at,
            last_referenced_at,
            confidence,
            superseded_by,
            freshness,
            scope_match,
            supersede_penalty,
        });
    }

    Ok((seed, rows))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h<T: Eq + std::hash::Hash + Clone>(items: &[T]) -> HashSet<T> {
        items.iter().cloned().collect()
    }

    #[test]
    fn precision_at_k_handles_zero_k() {
        assert_eq!(precision_at_k(&["a", "b"], &h(&["a"]), 0), 0.0);
    }

    #[test]
    fn precision_at_k_handles_empty_retrieved() {
        let empty: Vec<&str> = vec![];
        assert_eq!(precision_at_k(&empty, &h(&["a"]), 5), 0.0);
    }

    #[test]
    fn precision_at_k_perfect() {
        assert_eq!(precision_at_k(&["a", "b", "c"], &h(&["a", "b", "c"]), 3), 1.0);
    }

    #[test]
    fn precision_at_k_partial() {
        // top-3 = a,b,c; relevant = a,c → 2/3
        let p = precision_at_k(&["a", "b", "c"], &h(&["a", "c"]), 3);
        assert!((p - 2.0 / 3.0).abs() < 1e-9);
    }

    #[test]
    fn recall_at_k_perfect() {
        assert_eq!(recall_at_k(&["a", "b"], &h(&["a", "b"]), 5), 1.0);
    }

    #[test]
    fn recall_at_k_partial() {
        // top-2 = a,b; relevant = a,b,c → 2/3 (one missing).
        let r = recall_at_k(&["a", "b"], &h(&["a", "b", "c"]), 2);
        assert!((r - 2.0 / 3.0).abs() < 1e-9);
    }

    #[test]
    fn ndcg_perfect_ranking_scores_one() {
        let s = ndcg_at_k(&["a", "b", "c"], &h(&["a", "b", "c"]), 3);
        assert!((s - 1.0).abs() < 1e-9);
    }

    #[test]
    fn ndcg_inverted_ranking_scores_lower() {
        let perfect = ndcg_at_k(&["a", "b"], &h(&["a", "b"]), 2);
        let inverted = ndcg_at_k(&["c", "a"], &h(&["a", "b"]), 2); // a slips to rank 2
        assert!(inverted < perfect);
        assert!(inverted > 0.0);
    }

    #[test]
    fn aggregate_handles_empty() {
        let agg = AggregateMetrics::from_per_case(&[]);
        assert_eq!(agg.n_cases, 0);
        assert_eq!(agg.mean_precision_at_5, 0.0);
    }

    #[test]
    fn aggregate_means_match_single_case() {
        let cases = vec![PerCaseMetrics {
            case_id: "c1".into(),
            query: "q".into(),
            precision_at_5: 0.6,
            precision_at_10: 0.4,
            recall_at_10: 0.8,
            ndcg_at_10: 0.7,
            top1_freshness: 0.5,
            retrieved: vec![],
            relevant: vec![],
        }];
        let agg = AggregateMetrics::from_per_case(&cases);
        assert_eq!(agg.n_cases, 1);
        assert!((agg.mean_precision_at_5 - 0.6).abs() < 1e-9);
        assert!((agg.mean_recall_at_10 - 0.8).abs() < 1e-9);
    }
}
