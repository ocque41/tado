//! `dome-eval corpus run` — replay a hand-labeled corpus.
//!
//! The corpus is a YAML fixture that ships with the crate (see
//! `tests/corpus/`). It carries:
//!
//! - **fixtures.docs** — the docs to seed (id, topic, title, scope, body).
//! - **fixtures.project_id** — when non-empty, every doc and case
//!   inherits this id, so scope-aware retrieval can be exercised.
//! - **cases** — the labeled queries: `(id, query, scope, knowledge_scope,
//!   relevant_doc_ids, optional thresholds)`.
//!
//! Run:
//!
//! 1. Open an in-memory SQLite, migrate to v23.
//! 2. Insert each doc into `docs` + `fts_notes` + run
//!    `bt_core::notes::store::reindex_note` to chunk + embed (NoopEmbedder)
//!    + write `note_chunks`.
//! 3. For each case: build a `HybridQuery` with a `RetrievalCtx` so the
//!    rerank fires + the row hits `retrieval_log` (we re-use the
//!    production code, no test fork). Compute precision@k / recall@k /
//!    nDCG@k against the labeled relevant set.
//! 4. Compare against per-corpus thresholds; report pass/fail.
//!
//! Why YAML over JSON: the corpus files are hand-edited and
//! multi-line markdown bodies + per-case prose are vastly more readable.

use anyhow::{Context, Result};
use bt_core::notes::{HybridQuery, NoopEmbedder, RetrievalCtx};
use chrono::{DateTime, Utc};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::Path;
use uuid::Uuid;

use crate::{
    format_summary, ndcg_at_k, precision_at_k, recall_at_k, AggregateMetrics, PerCaseMetrics,
};

/// Pass/fail thresholds that gate `dome-eval corpus run` in CI.
///
/// `min_*` values: a corpus run fails if the aggregate dips below.
/// All defaults are the v0.10 baseline; later phases ratchet them up.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CorpusThresholds {
    #[serde(default = "default_min_p_at_5")]
    pub min_precision_at_5: f64,
    #[serde(default = "default_min_p_at_10")]
    pub min_precision_at_10: f64,
    #[serde(default = "default_min_r_at_10")]
    pub min_recall_at_10: f64,
    #[serde(default = "default_min_ndcg_at_10")]
    pub min_ndcg_at_10: f64,
}

fn default_min_p_at_5() -> f64 {
    // Each baseline case has 1 relevant doc, so P@5 ceiling is 0.20.
    // Default threshold 0.10 means "at least half the queries surface
    // the relevant doc in the top-5." Phase 3+ ratchets up.
    0.10
}
fn default_min_p_at_10() -> f64 {
    // P@10 ceiling with 1 relevant doc per case is 0.10.
    0.06
}
fn default_min_r_at_10() -> f64 {
    0.50
}
fn default_min_ndcg_at_10() -> f64 {
    0.40
}

impl Default for CorpusThresholds {
    fn default() -> Self {
        Self {
            min_precision_at_5: default_min_p_at_5(),
            min_precision_at_10: default_min_p_at_10(),
            min_recall_at_10: default_min_r_at_10(),
            min_ndcg_at_10: default_min_ndcg_at_10(),
        }
    }
}

/// One labeled case in the corpus.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CorpusCase {
    pub id: String,
    pub query: String,
    /// `'user' | 'agent' | 'all'` — the bare `scope` arg passed to
    /// `hybrid_search`.
    #[serde(default = "default_case_scope")]
    pub scope: String,
    /// Optional topic filter.
    #[serde(default)]
    pub topic: Option<String>,
    /// `'global' | 'project' | 'merged'`.
    #[serde(default = "default_knowledge_scope")]
    pub knowledge_scope: String,
    /// Doc ids that should appear in the top-k. Order doesn't matter
    /// for precision/recall, but contributes to nDCG.
    #[serde(default)]
    pub relevant_doc_ids: Vec<String>,
}

fn default_case_scope() -> String {
    "all".into()
}
fn default_knowledge_scope() -> String {
    "merged".into()
}

/// One doc fixture.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CorpusDoc {
    pub id: String,
    pub topic: String,
    #[serde(default)]
    pub slug: Option<String>,
    pub title: String,
    /// Stored as `note_chunks.scope`, also picked up by
    /// `result_scopes`. Use `'user'` by default.
    #[serde(default = "default_doc_scope")]
    pub scope: String,
    /// Owner scope for the docs row: `'global'` or `'project'`.
    #[serde(default = "default_owner_scope")]
    pub owner_scope: String,
    /// Knowledge kind: `'knowledge' | 'workflow' | 'decision' | 'system'`.
    #[serde(default = "default_knowledge_kind")]
    pub knowledge_kind: String,
    /// Optional explicit timestamp — overrides `now()`. Lets fixtures
    /// exercise freshness reranking.
    #[serde(default)]
    pub updated_at: Option<String>,
    pub body: String,
}

fn default_doc_scope() -> String {
    "user".into()
}
fn default_owner_scope() -> String {
    "global".into()
}
fn default_knowledge_kind() -> String {
    "knowledge".into()
}

/// Top-level corpus fixture.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Corpus {
    pub name: String,
    #[serde(default)]
    pub description: String,
    /// When set, every doc + case inherits this `project_id`; lets the
    /// corpus exercise scope-aware retrieval.
    #[serde(default)]
    pub project_id: Option<String>,
    /// Alpha for the convex combine `α·vector + (1-α)·lexical`.
    /// Default is `0.0` — the corpus measures the **lexical + rerank**
    /// path, which is the only signal CI can reproduce deterministically
    /// (the NoopEmbedder is hash-based, so vector hits are noise).
    /// Real model-driven retrieval is exercised by the e2e tests in
    /// `bt-core/tests/code_index_e2e.rs`, not this corpus.
    #[serde(default)]
    pub alpha: f32,
    #[serde(default)]
    pub thresholds: CorpusThresholds,
    pub docs: Vec<CorpusDoc>,
    pub cases: Vec<CorpusCase>,
}

impl Corpus {
    pub fn from_yaml_str(s: &str) -> Result<Self> {
        serde_yaml::from_str(s).context("parsing corpus YAML")
    }

    pub fn from_path(path: &Path) -> Result<Self> {
        let s = std::fs::read_to_string(path)
            .with_context(|| format!("reading corpus fixture {}", path.display()))?;
        Self::from_yaml_str(&s)
    }
}

/// Per-case outcome plus the threshold-pass flag.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CorpusResult {
    pub case: CorpusCase,
    pub metrics: PerCaseMetrics,
}

/// Full corpus report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CorpusReport {
    pub corpus: String,
    pub thresholds: CorpusThresholds,
    pub aggregate: AggregateMetrics,
    pub passed: bool,
    pub results: Vec<CorpusResult>,
    pub failures: Vec<String>,
}

impl CorpusReport {
    /// Tight one-line summary for CI logs.
    pub fn one_line(&self) -> String {
        format!(
            "{} ({}) {}",
            self.corpus,
            if self.passed { "PASS" } else { "FAIL" },
            format_summary(&self.corpus, &self.aggregate)
        )
    }
}

/// Run a corpus against an in-memory vault.
///
/// The function is deterministic given the same corpus YAML — uses
/// `NoopEmbedder` so CI doesn't need the Qwen3 model files. The noop
/// embedder is FNV-1a over chunk text, so vector hits are weak; the
/// corpus is sized so the FTS5 lexical lane carries the recall load.
pub fn run_corpus(corpus: &Corpus) -> Result<CorpusReport> {
    let conn = Connection::open_in_memory().context("opening in-memory corpus DB")?;
    bt_core::migrations::migrate(&conn).context("applying migrations to corpus DB")?;
    seed_vault(&conn, corpus)?;

    let embedder = NoopEmbedder;
    let mut per_case = Vec::with_capacity(corpus.cases.len());

    for case in &corpus.cases {
        let ctx = RetrievalCtx {
            actor_kind: "system".into(),
            actor_id: Some("dome-eval-corpus".into()),
            project_id: corpus.project_id.clone(),
            knowledge_scope: case.knowledge_scope.clone(),
            tool: "dome_eval_corpus".into(),
            preferred_scope: match case.knowledge_scope.as_str() {
                "project" | "merged" => Some("user".into()),
                _ => None,
            },
            pack_id: None,
        };
        let query = HybridQuery {
            text: case.query.as_str(),
            scope: case.scope.as_str(),
            topic: case.topic.as_deref(),
            limit: 10,
            alpha: corpus.alpha,
            ctx: Some(ctx),
        };
        let hits = bt_core::notes::hybrid_search(&conn, &query, &embedder)
            .with_context(|| format!("running case {}", case.id))?;

        let retrieved: Vec<String> = hits.iter().map(|h| h.doc_id.clone()).collect();
        let relevant: HashSet<String> = case.relevant_doc_ids.iter().cloned().collect();
        let top1_freshness = hits
            .first()
            .and_then(|h| h.updated_at.as_deref())
            .map(|u| {
                bt_core::notes::freshness_score(Some(u), None, None, Utc::now()) as f64
            })
            .unwrap_or(0.0);

        per_case.push(PerCaseMetrics {
            case_id: case.id.clone(),
            query: case.query.clone(),
            precision_at_5: precision_at_k(&retrieved, &relevant, 5),
            precision_at_10: precision_at_k(&retrieved, &relevant, 10),
            recall_at_10: recall_at_k(&retrieved, &relevant, 10),
            ndcg_at_10: ndcg_at_k(&retrieved, &relevant, 10),
            top1_freshness,
            retrieved,
            relevant: case.relevant_doc_ids.clone(),
        });
    }

    let aggregate = AggregateMetrics::from_per_case(&per_case);
    let mut failures = Vec::new();
    if aggregate.mean_precision_at_5 < corpus.thresholds.min_precision_at_5 {
        failures.push(format!(
            "P@5 {:.3} < threshold {:.3}",
            aggregate.mean_precision_at_5, corpus.thresholds.min_precision_at_5
        ));
    }
    if aggregate.mean_precision_at_10 < corpus.thresholds.min_precision_at_10 {
        failures.push(format!(
            "P@10 {:.3} < threshold {:.3}",
            aggregate.mean_precision_at_10, corpus.thresholds.min_precision_at_10
        ));
    }
    if aggregate.mean_recall_at_10 < corpus.thresholds.min_recall_at_10 {
        failures.push(format!(
            "R@10 {:.3} < threshold {:.3}",
            aggregate.mean_recall_at_10, corpus.thresholds.min_recall_at_10
        ));
    }
    if aggregate.mean_ndcg_at_10 < corpus.thresholds.min_ndcg_at_10 {
        failures.push(format!(
            "nDCG@10 {:.3} < threshold {:.3}",
            aggregate.mean_ndcg_at_10, corpus.thresholds.min_ndcg_at_10
        ));
    }
    let passed = failures.is_empty();

    let results: Vec<CorpusResult> = corpus
        .cases
        .iter()
        .zip(per_case.iter())
        .map(|(c, m)| CorpusResult {
            case: c.clone(),
            metrics: m.clone(),
        })
        .collect();

    Ok(CorpusReport {
        corpus: corpus.name.clone(),
        thresholds: corpus.thresholds.clone(),
        aggregate,
        passed,
        results,
        failures,
    })
}

/// Seed an in-memory v23 vault with the corpus fixtures. Uses
/// production write paths (`db::upsert_doc` analog + `reindex_note`)
/// so what we score is what production retrieves.
fn seed_vault(conn: &Connection, corpus: &Corpus) -> Result<()> {
    let now = Utc::now();
    let embedder = NoopEmbedder;

    for doc in &corpus.docs {
        let updated_at = doc
            .updated_at
            .as_deref()
            .and_then(parse_dt)
            .unwrap_or(now);
        let slug = doc.slug.clone().unwrap_or_else(|| slugify(&doc.title));
        let user_path = format!("topics/{}/{}.user.md", doc.topic, slug);
        let agent_path = format!("topics/{}/{}.agent.md", doc.topic, slug);
        let project_id = corpus.project_id.as_deref();

        // docs row.
        conn.execute(
            r#"INSERT OR REPLACE INTO docs (
                id, topic, slug, title, user_path, agent_path,
                created_at, updated_at, user_hash, agent_hash,
                owner_scope, project_id, project_root, knowledge_kind
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)"#,
            params![
                doc.id,
                doc.topic,
                slug,
                doc.title,
                user_path,
                agent_path,
                updated_at.to_rfc3339(),
                updated_at.to_rfc3339(),
                "0",
                "0",
                doc.owner_scope,
                project_id,
                project_id.map(|_| "/tmp/corpus"),
                doc.knowledge_kind,
            ],
        )
        .with_context(|| format!("inserting doc {}", doc.id))?;

        // fts_notes row (lexical lane).
        conn.execute(
            "INSERT INTO fts_notes(doc_id, scope, content) VALUES (?1, ?2, ?3)",
            params![doc.id, doc.scope, doc.body],
        )
        .with_context(|| format!("inserting fts row for doc {}", doc.id))?;

        // note_chunks (vector lane), via the production path so chunk
        // shapes / embedder metadata stay in sync with what the daemon
        // writes.
        bt_core::notes::store::reindex_note(conn, &doc.id, &doc.scope, &doc.body, &embedder)
            .with_context(|| format!("reindexing chunks for doc {}", doc.id))?;
    }

    Ok(())
}

fn parse_dt(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc))
        .ok()
}

fn slugify(title: &str) -> String {
    title
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

#[allow(dead_code)]
fn deterministic_id() -> String {
    Uuid::new_v4().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_collapses_punctuation() {
        assert_eq!(slugify("Auth refactor — 2026-04-26 retro!"), "auth-refactor-2026-04-26-retro");
        assert_eq!(slugify("Hello   world"), "hello-world");
        assert_eq!(slugify(""), "");
    }

    #[test]
    fn corpus_yaml_round_trips() {
        let yaml = r#"
name: "smoke-corpus"
description: "tiny fixture for unit tests"
docs:
  - id: "doc-1"
    topic: "inbox"
    title: "First-time setup"
    body: |
      # First-time setup

      Walk through onboarding for new teammates.
cases:
  - id: "case-1"
    query: "onboarding walkthrough"
    relevant_doc_ids: ["doc-1"]
"#;
        let corpus = Corpus::from_yaml_str(yaml).unwrap();
        assert_eq!(corpus.name, "smoke-corpus");
        assert_eq!(corpus.docs.len(), 1);
        assert_eq!(corpus.cases.len(), 1);
        assert_eq!(corpus.cases[0].knowledge_scope, "merged");
        assert_eq!(corpus.cases[0].scope, "all");
    }

    #[test]
    fn run_corpus_smoke() {
        let yaml = r#"
name: "smoke"
docs:
  - id: "doc-onboarding"
    topic: "inbox"
    title: "Onboarding"
    body: |
      onboarding walkthrough for new teammates that arrive on the canvas
  - id: "doc-deployment"
    topic: "inbox"
    title: "Deployment"
    body: |
      deployment runbook with manual gates
cases:
  - id: "find-onboarding"
    query: "onboarding"
    relevant_doc_ids: ["doc-onboarding"]
thresholds:
  min_precision_at_5: 0.4
  min_precision_at_10: 0.05
  min_recall_at_10: 0.5
  min_ndcg_at_10: 0.4
"#;
        let corpus = Corpus::from_yaml_str(yaml).unwrap();
        let report = run_corpus(&corpus).unwrap();
        assert_eq!(report.aggregate.n_cases, 1);
        // Lexical FTS5 lane finds "onboarding" → P@5 should be high.
        assert!(report.aggregate.mean_precision_at_5 >= 0.4);
        assert!(report.passed, "smoke corpus failed: {:?}", report.failures);
    }
}
