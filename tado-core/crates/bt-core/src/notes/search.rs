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
use rusqlite::{params, Connection};
use std::collections::HashMap;

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
}

impl<'a> HybridQuery<'a> {
    pub fn new(text: &'a str, scope: &'a str) -> Self {
        Self {
            text,
            scope,
            topic: None,
            limit: 25,
            alpha: 0.7,
        }
    }
}

/// Run a hybrid query. Returns up to `query.limit` hits, newest /
/// best scores first.
pub fn hybrid_search<E: Embedder + ?Sized>(
    conn: &Connection,
    query: &HybridQuery<'_>,
    embedder: &E,
) -> Result<Vec<SearchHit>, BtError> {
    let trimmed = query.text.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }

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

    ranked.sort_by(|a, b| {
        b.combined_score
            .partial_cmp(&a.combined_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    ranked.truncate(limit);
    Ok(ranked)
}

/// Top-K chunks by cosine against the query embedding.
pub fn vector_candidates<E: Embedder + ?Sized>(
    conn: &Connection,
    text: &str,
    scope: &str,
    limit: usize,
    embedder: &E,
) -> Result<Vec<SearchHit>, BtError> {
    let query_vec = embedder.embed(text);
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
            }
        })
        .collect();

    // Join with docs to attach topic + title.
    attach_doc_metadata(conn, &mut hits)?;
    Ok(hits)
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

    let sql = r#"
        SELECT f.doc_id, f.scope, d.topic, d.title,
               snippet(fts_notes, 2, '[', ']', '…', 20),
               bm25(fts_notes)
        FROM fts_notes f
        JOIN docs d ON d.id = f.doc_id
        WHERE fts_notes MATCH ?1
          AND (?2 = 'all' OR f.scope = ?2)
          AND (?3 IS NULL OR d.topic = ?3)
        ORDER BY bm25(fts_notes)
        LIMIT ?4
    "#;

    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(params![text, effective_scope, topic, limit as i64], |row| {
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
    let mut stmt = conn.prepare("SELECT topic, title FROM docs WHERE id = ?1")?;
    for hit in hits.iter_mut() {
        if !hit.topic.is_empty() && !hit.title.is_empty() {
            continue;
        }
        let row: Option<(String, String)> = stmt
            .query_row(params![hit.doc_id], |r| Ok((r.get(0)?, r.get(1)?)))
            .ok();
        if let Some((topic, title)) = row {
            if hit.topic.is_empty() {
                hit.topic = topic;
            }
            if hit.title.is_empty() {
                hit.title = title;
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
                title TEXT NOT NULL
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
    fn lexical_path_returns_fts_matches() {
        let conn = mem_db();
        conn.execute_batch(
            r#"
            INSERT INTO docs(id, topic, slug, title) VALUES('d1', 'inbox', 'setup', 'First-time Setup');
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
}
