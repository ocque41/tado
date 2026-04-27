//! Hybrid search over the notes index.
//!
//! Two retrieval signals combined into one ranked list:
//!
//! - **Vector similarity** — cosine over the note-chunk embeddings
//!   stored in `note_chunks.embedding`. Matches *semantic* relatedness
//!   (e.g. a query about "onboarding" surfaces a note titled
//!   "first-time setup" even if no token overlaps).
//! - **Lexical FTS5** — the existing `fts_notes` virtual table at the
//!   document grain. Matches *keyword* relatedness (query "OAuth"
//!   surfaces notes that literally say OAuth).
//!
//! Results from both paths are joined on `(doc_id, scope)` and
//! reranked via a fixed convex combination: `score = alpha * vector +
//! (1 - alpha) * lexical`. Alpha defaults to 0.7 — slight preference
//! for semantic matches, since that's the bar lexical search already
//! clears and the hybrid is only worth it when the vector path earns
//! its keep.
//!
//! ## Why brute-force (for now)
//!
//! We iterate every chunk, compute cosine against the query
//! embedding, and keep top-K. At notes-app scale (≤ 10k chunks) this
//! is milliseconds on a laptop CPU and keeps the build free of
//! `sqlite-vec`. When the real embedder ships we'll either keep this
//! (if it stays fast enough) or swap in `sqlite-vec`'s virtual table
//! with no API change — [`hybrid_search`] is the single entry point.

use crate::error::BtError;
use crate::notes::embeddings::{cosine, Embedder};
use crate::notes::store::iter_all_chunks;
use chrono::{DateTime, Utc};
use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::time::Instant;
use uuid::Uuid;

/// A single result from [`hybrid_search`]. Ordered by descending
/// [`combined_score`].
#[derive(Debug, Clone, serde::Serialize)]
pub struct SearchHit {
    pub doc_id: String,
    pub scope: String,
    pub chunk_index: Option<i64>,
    pub topic: String,
    pub title: String,
    /// 30-char-ish excerpt taken from the matching chunk (vector path)
    /// or the FTS5 snippet (lexical path).
    pub excerpt: String,
    /// Raw cosine similarity for the best matching chunk in the hit,
    /// `None` if only the lexical path matched.
    pub vector_score: Option<f32>,
    /// Normalized lexical score (higher = better). `None` if only the
    /// vector path matched.
    pub lexical_score: Option<f32>,
    /// Combined rerank score used to sort `SearchHit`s.
    pub combined_score: f32,
    /// `docs.updated_at` for the matching doc, populated by
    /// [`attach_doc_metadata`]. Drives freshness in [`rerank`]. RFC3339.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    /// `docs.created_at` (or the equivalent for non-doc entities). Used
    /// as the freshness fallback when `updated_at` is missing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
    /// Phase 3 — `graph_nodes.last_referenced_at` for the matching
    /// doc's canonical entity (when one exists). Bumped by the
    /// `agent_used_context` event handler; feeds the freshness signal.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_referenced_at: Option<String>,
    /// Phase 3 — confidence in `[0.0, 1.0]` from `graph_nodes`. Used
    /// as the confidence multiplier in [`rerank`]. `None` ⇒ default 1.0
    /// so docs without a typed entity yet aren't penalised.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f32>,
    /// Phase 3 — `graph_nodes.superseded_by` (newer node id, if any).
    /// Triggers the supersede-penalty multiplier (0.3×) so retired
    /// facts demote below their replacements without disappearing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub superseded_by: Option<String>,
}

/// Input bundle for [`hybrid_search`].
#[derive(Debug, Clone)]
pub struct HybridQuery<'a> {
    pub text: &'a str,
    pub scope: &'a str,
    pub topic: Option<&'a str>,
    pub limit: usize,
    /// Weight on vector similarity in `[0.0, 1.0]`. The lexical
    /// weight is `1.0 - alpha`.
    pub alpha: f32,
    /// Optional retrieval context. When `Some`, [`hybrid_search`]
    /// applies the heuristic rerank (freshness × scope-match × …) and
    /// writes one row to `retrieval_log` for measurable evaluation.
    /// When `None`, behavior matches v0.9 exactly — no rerank, no log.
    pub ctx: Option<RetrievalCtx>,
}

impl<'a> HybridQuery<'a> {
    pub fn new(text: &'a str, scope: &'a str) -> Self {
        Self {
            text,
            scope,
            topic: None,
            limit: 25,
            alpha: 0.7,
            ctx: None,
        }
    }

    /// Builder-style: attach a retrieval context. Enables rerank +
    /// retrieval-log writes on the next [`hybrid_search`] call.
    pub fn with_ctx(mut self, ctx: RetrievalCtx) -> Self {
        self.ctx = Some(ctx);
        self
    }
}

/// Per-call context used by [`rerank`] and [`record_retrieval_log`].
///
/// Carries the *who* / *why* / *for what* of the search call so we can
/// (a) bias ranking toward the caller's expected scope and (b) log the
/// call to `retrieval_log` for replay against future Dome state.
#[derive(Debug, Clone)]
pub struct RetrievalCtx {
    /// `'agent' | 'user_ui' | 'system'` — matches `retrieval_log.actor_kind`.
    pub actor_kind: String,
    /// Agent session id / user id; nullable when actor is `system`.
    pub actor_id: Option<String>,
    /// Project this retrieval is "about" (for scoped logs + scope match).
    pub project_id: Option<String>,
    /// `'global' | 'project' | 'merged'` — matches the MCP query parameter.
    pub knowledge_scope: String,
    /// MCP tool name driving this call (`dome_search`, `dome_recipe_apply`, …).
    pub tool: String,
    /// When set, hits with a matching `scope` get a 1.0× multiplier;
    /// non-matching hits get 0.6×. Use this to bias toward project-scoped
    /// answers when the caller is a project-scoped agent.
    pub preferred_scope: Option<String>,
    /// If this retrieval is being served from a precomputed context pack,
    /// record the pack id so eval can stitch pack hits back to the call
    /// that built them.
    pub pack_id: Option<String>,
}

impl Default for RetrievalCtx {
    fn default() -> Self {
        Self {
            actor_kind: "system".into(),
            actor_id: None,
            project_id: None,
            knowledge_scope: "global".into(),
            tool: "search.query".into(),
            preferred_scope: None,
            pack_id: None,
        }
    }
}

/// Pure freshness score in `[0.0, 1.0]`. Exponential decay with a
/// 30-day half-life, anchored to the most recent of `updated_at` /
/// `last_referenced_at` / `created_at` (parsed as RFC3339).
///
/// Returns `0.5` when no timestamp is parseable — neutral, so
/// freshness can't *demote* unstamped docs (which would punish legacy
/// rows whose timestamps weren't yet ingested).
pub fn freshness_score(
    updated_at: Option<&str>,
    last_referenced_at: Option<&str>,
    created_at: Option<&str>,
    now: DateTime<Utc>,
) -> f32 {
    const HALF_LIFE_DAYS: f64 = 30.0;

    let candidates = [updated_at, last_referenced_at, created_at];
    let most_recent = candidates
        .iter()
        .filter_map(|s| s.and_then(parse_rfc3339))
        .max();

    let Some(dt) = most_recent else {
        return 0.5;
    };

    let age_days = (now - dt).num_seconds().max(0) as f64 / 86_400.0;
    let decay = (-std::f64::consts::LN_2 * age_days / HALF_LIFE_DAYS).exp();
    (decay as f32).clamp(0.0, 1.0)
}

fn parse_rfc3339(s: &str) -> Option<DateTime<Utc>> {
    // Try RFC3339 first, then SQLite's native `datetime('now')` shape
    // (`YYYY-MM-DD HH:MM:SS`) which omits the `T` and zone.
    DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc))
        .ok()
        .or_else(|| {
            chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S")
                .map(|n| DateTime::<Utc>::from_naive_utc_and_offset(n, Utc))
                .ok()
        })
}

/// Heuristic rerank applied after the convex combine.
///
/// Multiplies `combined_score` by:
/// - `0.5 + 0.5 * freshness` — keeps stale-but-relevant hits visible
///   (floor 0.5×) while doubling the boost for fresh ones. Freshness
///   reads `last_referenced_at` (bumped by `agent_used_context`),
///   `updated_at`, and `created_at` (fallback).
/// - `1.0` if `hit.scope` matches `ctx.preferred_scope`, else `0.6`.
/// - `confidence` from `graph_nodes` (`[0.4, 1.0]` typical via
///   `dome_verify`). Defaults to `1.0` when no typed entity exists.
/// - `0.3` when `superseded_by` is set — heavy demotion; retired
///   facts stay visible for audit but rank below their replacements.
///
/// v0.12 wires real values from `graph_nodes`; v0.10 had the same
/// shape with `confidence = 1.0` / `supersede_penalty = 1.0`
/// placeholders.
pub fn rerank(hit: &mut SearchHit, ctx: &RetrievalCtx, now: DateTime<Utc>) {
    let fresh = freshness_score(
        hit.updated_at.as_deref(),
        hit.last_referenced_at.as_deref(),
        hit.created_at.as_deref(),
        now,
    );
    let scope_match = match &ctx.preferred_scope {
        Some(s) if s == &hit.scope => 1.0_f32,
        Some(_) => 0.6_f32,
        None => 1.0_f32,
    };
    let confidence = hit.confidence.unwrap_or(1.0_f32).clamp(0.0, 1.0);
    let supersede_penalty = if hit.superseded_by.is_some() { 0.3_f32 } else { 1.0_f32 };

    hit.combined_score =
        hit.combined_score * (0.5 + 0.5 * fresh) * scope_match * confidence * supersede_penalty;
}

/// Append one row to `retrieval_log`. Best-effort — logging failure
/// must not fail the user-visible search call. Errors are returned so
/// callers can surface them at the daemon layer for debugging, but
/// `hybrid_search` swallows them deliberately.
pub fn record_retrieval_log(
    conn: &Connection,
    ctx: &RetrievalCtx,
    query: &str,
    hits: &[SearchHit],
    latency_ms: i64,
) -> Result<String, BtError> {
    let log_id = Uuid::new_v4().to_string();
    let result_ids: Vec<&str> = hits.iter().map(|h| h.doc_id.as_str()).collect();
    let result_scopes: Vec<&str> = hits.iter().map(|h| h.scope.as_str()).collect();

    let result_ids_json = serde_json::to_string(&result_ids)?;
    let result_scopes_json = serde_json::to_string(&result_scopes)?;

    conn.execute(
        r#"INSERT INTO retrieval_log (
            log_id, actor_kind, actor_id, project_id, knowledge_scope,
            tool, query, result_ids_json, result_scopes_json,
            latency_ms, pack_id
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)"#,
        params![
            log_id,
            ctx.actor_kind,
            ctx.actor_id,
            ctx.project_id,
            ctx.knowledge_scope,
            ctx.tool,
            query,
            result_ids_json,
            result_scopes_json,
            latency_ms,
            ctx.pack_id,
        ],
    )?;
    Ok(log_id)
}

/// Run a hybrid query. Returns up to `query.limit` hits, newest /
/// best scores first.
///
/// When `query.ctx` is `Some`, the heuristic [`rerank`] is applied
/// after the convex combine, and one row is appended to
/// `retrieval_log` with the call's measured latency. When `None`, the
/// behavior is identical to v0.9 — no rerank, no log — so existing
/// callers are unchanged.
pub fn hybrid_search<E: Embedder + ?Sized>(
    conn: &Connection,
    query: &HybridQuery<'_>,
    embedder: &E,
) -> Result<Vec<SearchHit>, BtError> {
    let trimmed = query.text.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }

    let started = Instant::now();

    let alpha = query.alpha.clamp(0.0, 1.0);
    let limit = query.limit.max(1);

    let vector_hits = vector_candidates(conn, trimmed, query.scope, limit * 4, embedder)?;
    let lexical_hits = lexical_candidates(conn, trimmed, query.scope, query.topic, limit * 4)?;

    let mut combined: HashMap<(String, String), SearchHit> = HashMap::new();

    // Normalize lexical scores to [0, 1] so alpha is interpretable.
    let max_lex = lexical_hits
        .iter()
        .map(|h| h.lexical_score.unwrap_or(0.0))
        .fold(0.0_f32, f32::max)
        .max(1.0);

    for hit in vector_hits.into_iter() {
        let key = (hit.doc_id.clone(), hit.scope.clone());
        combined.insert(key, hit);
    }

    for hit in lexical_hits {
        let key = (hit.doc_id.clone(), hit.scope.clone());
        let lex = hit.lexical_score.unwrap_or(0.0) / max_lex;
        if let Some(existing) = combined.get_mut(&key) {
            existing.lexical_score = Some(lex);
            if existing.title.is_empty() {
                existing.title = hit.title;
            }
            if existing.topic.is_empty() {
                existing.topic = hit.topic;
            }
            if existing.excerpt.is_empty() {
                existing.excerpt = hit.excerpt;
            }
            if existing.updated_at.is_none() {
                existing.updated_at = hit.updated_at;
            }
            if existing.created_at.is_none() {
                existing.created_at = hit.created_at;
            }
            if existing.confidence.is_none() {
                existing.confidence = hit.confidence;
            }
            if existing.superseded_by.is_none() {
                existing.superseded_by = hit.superseded_by;
            }
            if existing.last_referenced_at.is_none() {
                existing.last_referenced_at = hit.last_referenced_at;
            }
        } else {
            let mut normalized = hit;
            normalized.lexical_score = Some(lex);
            combined.insert(key, normalized);
        }
    }

    let mut ranked: Vec<SearchHit> = combined
        .into_values()
        .map(|mut hit| {
            let v = hit.vector_score.unwrap_or(0.0).max(0.0);
            let l = hit.lexical_score.unwrap_or(0.0).max(0.0);
            hit.combined_score = alpha * v + (1.0 - alpha) * l;
            hit
        })
        .collect();

    if let Some(ctx) = &query.ctx {
        let now = Utc::now();
        for hit in ranked.iter_mut() {
            rerank(hit, ctx, now);
        }
    }

    ranked.sort_by(|a, b| {
        b.combined_score
            .partial_cmp(&a.combined_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    ranked.truncate(limit);

    if let Some(ctx) = &query.ctx {
        let latency_ms = started.elapsed().as_millis() as i64;
        // Logging failures must never fail the user-visible search.
        let _ = record_retrieval_log(conn, ctx, trimmed, &ranked, latency_ms);
    }

    Ok(ranked)
}

/// Top-K chunks by cosine against the query embedding.
///
/// Uses `embed_query` (with the model's instruction prefix) for the
/// query side, while indexed chunks were written via `embed` (passage
/// path, no prefix). Per the Qwen3-Embedding model card this
/// asymmetric pairing is what the model was trained on; using
/// `embed` for both sides costs ~10% retrieval recall.
pub fn vector_candidates<E: Embedder + ?Sized>(
    conn: &Connection,
    text: &str,
    scope: &str,
    limit: usize,
    embedder: &E,
) -> Result<Vec<SearchHit>, BtError> {
    let query_vec = embedder.embed_query(text);
    let chunks = iter_all_chunks(conn, scope)?;

    let mut scored: Vec<(f32, crate::notes::store::StoredChunk)> = chunks
        .into_iter()
        .map(|c| (cosine(&query_vec, &c.embedding), c))
        .collect();

    // Drop anything that scored effectively zero; these are false
    // positives against the zero-vector case (empty text, untrained
    // embedder).
    scored.retain(|(s, _)| s.abs() > 1e-6);

    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(limit.max(1));

    // Collapse chunks to one hit per (doc_id, scope), keeping the
    // highest-scoring chunk.
    let mut best_per_doc: HashMap<(String, String), (f32, crate::notes::store::StoredChunk)> =
        HashMap::new();
    for (score, chunk) in scored {
        let key = (chunk.doc_id.clone(), chunk.scope.clone());
        match best_per_doc.get(&key) {
            Some((existing, _)) if *existing >= score => {}
            _ => {
                best_per_doc.insert(key, (score, chunk));
            }
        }
    }

    let mut hits: Vec<SearchHit> = best_per_doc
        .into_values()
        .map(|(score, chunk)| {
            let excerpt = short_excerpt(&chunk.text, 180);
            SearchHit {
                doc_id: chunk.doc_id.clone(),
                scope: chunk.scope.clone(),
                chunk_index: Some(chunk.chunk_index),
                topic: String::new(),
                title: String::new(),
                excerpt,
                vector_score: Some(score),
                lexical_score: None,
                combined_score: 0.0,
                updated_at: None,
                created_at: None,
                last_referenced_at: None,
                confidence: None,
                superseded_by: None,
            }
        })
        .collect();

    // Join with docs to attach topic + title + timestamps for rerank.
    attach_doc_metadata(conn, &mut hits)?;
    Ok(hits)
}

/// Sanitize a free-text query for FTS5 MATCH.
///
/// FTS5 has a small query language: bare hyphens, colons, parens, stars,
/// double quotes, and `^` are interpreted as operators or column
/// qualifiers. An agent that types `auth-cookies` or `Rust-first` would
/// otherwise crash the daemon with "no such column: first". This helper
/// wraps each whitespace-separated token in double quotes (after
/// doubling any embedded double quote, FTS5's escape rule), which kills
/// every operator interpretation and turns the query into a clean
/// term-AND-term match. Empty tokens are skipped.
pub fn sanitize_fts5_query(input: &str) -> String {
    input
        .split_whitespace()
        .filter_map(|tok| {
            // Drop tokens that became empty after normalization (e.g. a
            // bare `-` or `:`).
            let normalized: String = tok
                .chars()
                .filter(|c| !matches!(c, '"'))
                .collect();
            if normalized.is_empty() {
                None
            } else {
                Some(format!("\"{}\"", normalized))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Run the existing FTS5 search and reshape the rows into
/// [`SearchHit`]s. Scores are `1 / rank` (rusqlite's `rank` is a
/// monotonically-increasing column where lower is better, so the
/// reciprocal produces a 0..1 goodness measure).
pub fn lexical_candidates(
    conn: &Connection,
    text: &str,
    scope: &str,
    topic: Option<&str>,
    limit: usize,
) -> Result<Vec<SearchHit>, BtError> {
    let effective_scope = match scope {
        "user" | "agent" | "all" => scope,
        _ => "all",
    };

    let sanitized = sanitize_fts5_query(text);
    if sanitized.is_empty() {
        return Ok(Vec::new());
    }

    let sql = r#"
        SELECT f.doc_id, f.scope, d.topic, d.title,
               snippet(fts_notes, 2, '[', ']', '…', 20),
               bm25(fts_notes),
               d.updated_at, d.created_at
        FROM fts_notes f
        JOIN docs d ON d.id = f.doc_id
        WHERE fts_notes MATCH ?1
          AND (?2 = 'all' OR f.scope = ?2)
          AND (?3 IS NULL OR d.topic = ?3)
        ORDER BY bm25(fts_notes)
        LIMIT ?4
    "#;

    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(params![sanitized, effective_scope, topic, limit as i64], |row| {
        let bm25: Option<f64> = row.get(5).ok();
        let lex_score = bm25
            .map(|b| (1.0 / (1.0 + b.max(0.0) as f32)).min(1.0))
            .unwrap_or(0.0);
        Ok(SearchHit {
            doc_id: row.get(0)?,
            scope: row.get(1)?,
            chunk_index: None,
            topic: row.get(2)?,
            title: row.get(3)?,
            excerpt: row.get(4)?,
            vector_score: None,
            lexical_score: Some(lex_score),
            combined_score: 0.0,
            updated_at: row.get::<_, Option<String>>(6).unwrap_or(None),
            created_at: row.get::<_, Option<String>>(7).unwrap_or(None),
            last_referenced_at: None,
            confidence: None,
            superseded_by: None,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn attach_doc_metadata(conn: &Connection, hits: &mut [SearchHit]) -> Result<(), BtError> {
    if hits.is_empty() {
        return Ok(());
    }
    let mut docs_stmt = conn.prepare(
        "SELECT topic, title, updated_at, created_at FROM docs WHERE id = ?1",
    )?;
    // Phase 3: pull the most-recent live `graph_nodes` row anchored on
    // this doc id. Confidence/supersede default to None when the doc
    // hasn't been extracted yet — rerank treats None as 1.0× so legacy
    // rows aren't penalised.
    let mut entity_stmt = conn.prepare(
        r#"SELECT confidence, superseded_by, last_referenced_at
            FROM graph_nodes
            WHERE ref_id = ?1
              AND archived_at IS NULL
              AND (secondary_label IS NULL OR secondary_label != 'stub')
            ORDER BY sort_time DESC
            LIMIT 1"#,
    )?;
    for hit in hits.iter_mut() {
        if hit.topic.is_empty() || hit.title.is_empty() || hit.updated_at.is_none() || hit.created_at.is_none() {
            let row: Option<(String, String, Option<String>, Option<String>)> = docs_stmt
                .query_row(params![hit.doc_id], |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get::<_, Option<String>>(2)?,
                        r.get::<_, Option<String>>(3)?,
                    ))
                })
                .ok();
            if let Some((topic, title, updated_at, created_at)) = row {
                if hit.topic.is_empty() {
                    hit.topic = topic;
                }
                if hit.title.is_empty() {
                    hit.title = title;
                }
                if hit.updated_at.is_none() {
                    hit.updated_at = updated_at;
                }
                if hit.created_at.is_none() {
                    hit.created_at = created_at;
                }
            }
        }

        if hit.confidence.is_none() && hit.superseded_by.is_none() && hit.last_referenced_at.is_none() {
            let row: Option<(Option<f64>, Option<String>, Option<String>)> = entity_stmt
                .query_row(params![hit.doc_id], |r| {
                    Ok((
                        r.get::<_, Option<f64>>(0)?,
                        r.get::<_, Option<String>>(1)?,
                        r.get::<_, Option<String>>(2)?,
                    ))
                })
                .ok();
            if let Some((conf, superseded, last_ref)) = row {
                hit.confidence = conf.map(|c| c as f32);
                hit.superseded_by = superseded;
                hit.last_referenced_at = last_ref;
            }
        }
    }
    Ok(())
}

fn short_excerpt(text: &str, cap: usize) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= cap {
        return trimmed.to_string();
    }
    let mut out: String = trimmed.chars().take(cap).collect();
    out.push('…');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notes::embeddings::NoopEmbedder;

    fn mem_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE docs (
                id TEXT PRIMARY KEY,
                topic TEXT NOT NULL,
                slug TEXT NOT NULL,
                title TEXT NOT NULL,
                updated_at TEXT,
                created_at TEXT
            );
            CREATE TABLE note_chunks (
                doc_id TEXT NOT NULL,
                scope TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                text TEXT NOT NULL,
                heading_path TEXT NOT NULL,
                byte_start INTEGER NOT NULL,
                byte_end INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                embedding_model_id TEXT NOT NULL DEFAULT 'noop',
                embedding_model_version TEXT NOT NULL DEFAULT 'noop@1',
                embedding_dimension INTEGER NOT NULL DEFAULT 384,
                embedding_pooling TEXT NOT NULL DEFAULT 'hash-bucket',
                embedding_instruction TEXT NOT NULL DEFAULT '',
                embedding_source_hash TEXT NOT NULL DEFAULT 'legacy-noop',
                PRIMARY KEY (doc_id, scope, chunk_index)
            );
            CREATE VIRTUAL TABLE fts_notes USING fts5(
                doc_id UNINDEXED, scope UNINDEXED, content, tokenize = 'porter'
            );
            -- Mirror retrieval_log shape from migration_23 for ctx-enabled tests.
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
    fn empty_query_returns_nothing() {
        let conn = mem_db();
        let embedder = NoopEmbedder;
        let q = HybridQuery::new("   ", "all");
        let hits = hybrid_search(&conn, &q, &embedder).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn vector_only_path_returns_zero_when_index_empty() {
        let conn = mem_db();
        let embedder = NoopEmbedder;
        let q = HybridQuery::new("onboarding", "all");
        let hits = hybrid_search(&conn, &q, &embedder).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn sanitize_fts5_query_quotes_each_token() {
        assert_eq!(sanitize_fts5_query("auth-cookies decision"), "\"auth-cookies\" \"decision\"");
        assert_eq!(sanitize_fts5_query("Rust-first"), "\"Rust-first\"");
        assert_eq!(sanitize_fts5_query("  spaced   words  "), "\"spaced\" \"words\"");
    }

    #[test]
    fn sanitize_fts5_query_strips_embedded_quotes() {
        assert_eq!(sanitize_fts5_query("she said \"hi\""), "\"she\" \"said\" \"hi\"");
    }

    #[test]
    fn sanitize_fts5_query_handles_empty_input() {
        assert_eq!(sanitize_fts5_query(""), "");
        assert_eq!(sanitize_fts5_query("   \t  "), "");
    }

    #[test]
    fn lexical_search_handles_hyphenated_query() {
        let conn = mem_db();
        conn.execute_batch(
            r#"
            INSERT INTO docs(id, topic, slug, title, updated_at, created_at)
                VALUES('d1', 'inbox', 'rust', 'Rust-first decision',
                       '2026-04-20T10:00:00Z', '2026-04-20T10:00:00Z');
            INSERT INTO fts_notes(doc_id, scope, content)
                VALUES('d1', 'user', 'we adopted Rust-first for new non-UI logic');
            "#,
        ).unwrap();
        // Without the sanitizer, this would crash with "no such column: first".
        let hits = lexical_candidates(&conn, "Rust-first", "all", None, 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].doc_id, "d1");
    }

    #[test]
    fn lexical_path_returns_fts_matches() {
        let conn = mem_db();
        conn.execute_batch(
            r#"
            INSERT INTO docs(id, topic, slug, title, updated_at, created_at)
                VALUES('d1', 'inbox', 'setup', 'First-time Setup',
                       '2026-04-20T10:00:00Z', '2026-04-20T10:00:00Z');
            INSERT INTO fts_notes(doc_id, scope, content) VALUES('d1', 'user', 'first-time onboarding walkthrough for new teammates');
            "#,
        ).unwrap();
        let embedder = NoopEmbedder;
        let q = HybridQuery::new("onboarding", "all");
        let hits = hybrid_search(&conn, &q, &embedder).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].doc_id, "d1");
        assert_eq!(hits[0].title, "First-time Setup");
    }

    #[test]
    fn freshness_scores_are_monotonic_in_age() {
        let now = DateTime::parse_from_rfc3339("2026-04-27T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);

        let today = freshness_score(Some("2026-04-27T11:00:00Z"), None, None, now);
        let week_ago = freshness_score(Some("2026-04-20T12:00:00Z"), None, None, now);
        let month_ago = freshness_score(Some("2026-03-28T12:00:00Z"), None, None, now);
        let year_ago = freshness_score(Some("2025-04-27T12:00:00Z"), None, None, now);

        assert!(today > week_ago);
        assert!(week_ago > month_ago);
        assert!(month_ago > year_ago);

        // 30-day half-life: a 30-day-old doc should be ~0.5
        let half_life = freshness_score(Some("2026-03-28T12:00:00Z"), None, None, now);
        assert!((half_life - 0.5).abs() < 0.05, "expected ~0.5 at 30d, got {half_life}");
    }

    #[test]
    fn freshness_returns_neutral_when_no_timestamps() {
        let now = Utc::now();
        let score = freshness_score(None, None, None, now);
        assert!((score - 0.5).abs() < f32::EPSILON);
    }

    #[test]
    fn freshness_handles_sqlite_native_timestamp_format() {
        let now = DateTime::parse_from_rfc3339("2026-04-27T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        // SQLite's `datetime('now')` produces "YYYY-MM-DD HH:MM:SS" without timezone.
        let s = freshness_score(Some("2026-04-27 11:30:00"), None, None, now);
        assert!(s > 0.95, "very fresh sqlite-native timestamp should score high, got {s}");
    }

    #[test]
    fn rerank_demotes_off_scope_hits() {
        let now = DateTime::parse_from_rfc3339("2026-04-27T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let mut hit = SearchHit {
            doc_id: "d1".into(),
            scope: "global".into(),
            chunk_index: None,
            topic: String::new(),
            title: String::new(),
            excerpt: String::new(),
            vector_score: None,
            lexical_score: Some(1.0),
            combined_score: 1.0,
            updated_at: Some("2026-04-27T11:00:00Z".into()),
            created_at: None,
            last_referenced_at: None,
            confidence: None,
            superseded_by: None,
        };
        let ctx = RetrievalCtx {
            preferred_scope: Some("project".into()),
            ..Default::default()
        };
        rerank(&mut hit, &ctx, now);
        // (0.5 + 0.5 * fresh~1.0) * 0.6 (off-scope) = ~0.6
        assert!(hit.combined_score < 0.7);
        assert!(hit.combined_score > 0.55);
    }

    #[test]
    fn rerank_keeps_in_scope_fresh_hit_near_unchanged() {
        let now = DateTime::parse_from_rfc3339("2026-04-27T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let mut hit = SearchHit {
            doc_id: "d1".into(),
            scope: "project".into(),
            chunk_index: None,
            topic: String::new(),
            title: String::new(),
            excerpt: String::new(),
            vector_score: None,
            lexical_score: Some(1.0),
            combined_score: 1.0,
            updated_at: Some("2026-04-27T11:00:00Z".into()),
            created_at: None,
            last_referenced_at: None,
            confidence: None,
            superseded_by: None,
        };
        let ctx = RetrievalCtx {
            preferred_scope: Some("project".into()),
            ..Default::default()
        };
        rerank(&mut hit, &ctx, now);
        // (0.5 + 0.5 * ~1.0) * 1.0 * 1.0 * 1.0 = ~1.0
        assert!(hit.combined_score > 0.95);
    }

    #[test]
    fn rerank_demotes_low_confidence_hits() {
        let now = DateTime::parse_from_rfc3339("2026-04-27T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let mut high = SearchHit {
            doc_id: "d1".into(),
            scope: "user".into(),
            chunk_index: None,
            topic: String::new(),
            title: String::new(),
            excerpt: String::new(),
            vector_score: None,
            lexical_score: Some(1.0),
            combined_score: 1.0,
            updated_at: Some("2026-04-27T11:00:00Z".into()),
            created_at: None,
            last_referenced_at: None,
            confidence: Some(0.95),
            superseded_by: None,
        };
        let mut low = high.clone();
        low.doc_id = "d2".into();
        low.confidence = Some(0.4);
        let ctx = RetrievalCtx::default();
        rerank(&mut high, &ctx, now);
        rerank(&mut low, &ctx, now);
        assert!(high.combined_score > low.combined_score);
    }

    #[test]
    fn rerank_applies_supersede_penalty() {
        let now = DateTime::parse_from_rfc3339("2026-04-27T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let mut live = SearchHit {
            doc_id: "d1".into(),
            scope: "user".into(),
            chunk_index: None,
            topic: String::new(),
            title: String::new(),
            excerpt: String::new(),
            vector_score: None,
            lexical_score: Some(1.0),
            combined_score: 1.0,
            updated_at: Some("2026-04-27T11:00:00Z".into()),
            created_at: None,
            last_referenced_at: None,
            confidence: None,
            superseded_by: None,
        };
        let mut superseded = live.clone();
        superseded.doc_id = "d2".into();
        superseded.superseded_by = Some("d1".into());
        let ctx = RetrievalCtx::default();
        rerank(&mut live, &ctx, now);
        rerank(&mut superseded, &ctx, now);
        // Superseded hit gets a 0.3× multiplier vs live's 1.0× — gap
        // should be huge.
        assert!(live.combined_score > superseded.combined_score * 2.5);
    }

    #[test]
    fn hybrid_search_with_ctx_writes_retrieval_log_row() {
        let conn = mem_db();
        conn.execute_batch(
            r#"
            INSERT INTO docs(id, topic, slug, title, updated_at, created_at)
                VALUES('d1', 'inbox', 'setup', 'First-time Setup',
                       '2026-04-20T10:00:00Z', '2026-04-20T10:00:00Z');
            INSERT INTO fts_notes(doc_id, scope, content)
                VALUES('d1', 'user', 'first-time onboarding walkthrough');
            "#,
        )
        .unwrap();

        let embedder = NoopEmbedder;
        let ctx = RetrievalCtx {
            actor_kind: "agent".into(),
            actor_id: Some("agent-007".into()),
            knowledge_scope: "merged".into(),
            tool: "dome_search".into(),
            preferred_scope: Some("user".into()),
            ..Default::default()
        };
        let q = HybridQuery::new("onboarding", "all").with_ctx(ctx);
        let hits = hybrid_search(&conn, &q, &embedder).unwrap();
        assert_eq!(hits.len(), 1);

        // Exactly one row in retrieval_log.
        let row_count: i64 = conn
            .query_row("SELECT count(*) FROM retrieval_log", [], |r| r.get(0))
            .unwrap();
        assert_eq!(row_count, 1);

        let (actor_kind, tool, query, result_ids, result_scopes): (
            String,
            String,
            String,
            String,
            String,
        ) = conn
            .query_row(
                "SELECT actor_kind, tool, query, result_ids_json, result_scopes_json FROM retrieval_log",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .unwrap();
        assert_eq!(actor_kind, "agent");
        assert_eq!(tool, "dome_search");
        assert_eq!(query, "onboarding");
        assert!(result_ids.contains("d1"));
        assert!(result_scopes.contains("user"));
    }

    #[test]
    fn hybrid_search_without_ctx_writes_no_log_row_v0_9_compat() {
        let conn = mem_db();
        conn.execute_batch(
            r#"
            INSERT INTO docs(id, topic, slug, title, updated_at, created_at)
                VALUES('d1', 'inbox', 'setup', 'Setup',
                       '2026-04-20T10:00:00Z', '2026-04-20T10:00:00Z');
            INSERT INTO fts_notes(doc_id, scope, content)
                VALUES('d1', 'user', 'walkthrough');
            "#,
        )
        .unwrap();

        let embedder = NoopEmbedder;
        let q = HybridQuery::new("walkthrough", "all"); // no ctx
        let _ = hybrid_search(&conn, &q, &embedder).unwrap();

        let row_count: i64 = conn
            .query_row("SELECT count(*) FROM retrieval_log", [], |r| r.get(0))
            .unwrap();
        assert_eq!(row_count, 0, "ctx-less call must not write a retrieval_log row");
    }
}
