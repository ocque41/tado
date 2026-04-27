//! Hybrid retrieval over `code_chunks` + `fts_code`.
//!
//! Mirrors [`crate::notes::search::hybrid_search`] in shape (vector
//! lane + FTS5 lane + α-blend) but operates on the project-scoped
//! `code_chunks` table and supports `project_id` / `language`
//! filters that the notes search doesn't need.
//!
//! ## Why brute-force cosine for v1
//!
//! At our current scale (a few thousand chunks per project, decoded
//! from i8 to f32 on the fly), a full-table scan + cosine takes a
//! few milliseconds. `sqlite-vec` becomes worth it past ~50k chunks
//! per query — the plan calls for it as a Phase 3.5 enhancement that
//! drops in behind this same `code_search` API.

use std::collections::HashMap;

use rusqlite::Connection;

use crate::code::store::decode_embedding;
use crate::error::BtError;
use crate::notes::embeddings::{cosine, Embedder};

/// One ranked code chunk. Ordered by `combined_score` desc when
/// returned from [`code_hybrid_search`].
#[derive(Debug, Clone, serde::Serialize)]
pub struct CodeSearchHit {
    pub project_id: String,
    pub repo_path: String,
    pub chunk_index: i64,
    pub language: String,
    pub node_kind: Option<String>,
    pub qualified_name: Option<String>,
    pub start_line: i64,
    pub end_line: i64,
    /// Trimmed excerpt — never the full chunk to keep payloads small.
    pub excerpt: String,
    pub vector_score: Option<f32>,
    pub lexical_score: Option<f32>,
    pub combined_score: f32,
}

/// Input bundle for [`code_hybrid_search`].
#[derive(Debug, Clone)]
pub struct CodeQuery<'a> {
    pub text: &'a str,
    pub project_ids: Option<&'a [String]>,
    pub languages: Option<&'a [String]>,
    pub limit: usize,
    /// Weight on vector similarity in `[0.0, 1.0]`. Lexical weight is
    /// `1.0 - alpha`. Code identifiers match exactly more often than
    /// notes prose, so we give the lexical lane more pull (α=0.6 vs
    /// 0.7 for notes).
    pub alpha: f32,
}

impl<'a> CodeQuery<'a> {
    pub fn new(text: &'a str) -> Self {
        Self {
            text,
            project_ids: None,
            languages: None,
            limit: 25,
            alpha: 0.6,
        }
    }
}

pub fn code_hybrid_search<E: Embedder + ?Sized>(
    conn: &Connection,
    query: &CodeQuery<'_>,
    embedder: &E,
) -> Result<Vec<CodeSearchHit>, BtError> {
    let trimmed = query.text.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    let limit = query.limit.clamp(1, 500);
    let alpha = query.alpha.clamp(0.0, 1.0);

    let vector_hits = vector_lane(conn, trimmed, query, embedder, limit * 4)?;
    let lexical_hits = lexical_lane(conn, trimmed, query, limit * 4)?;

    Ok(merge(vector_hits, lexical_hits, alpha, limit))
}

/// Brute-force cosine against every chunk that matches the project /
/// language filters and the embedder's stamped model. Skipping rows
/// from a different model avoids comparing 1024-dim qwen3 vectors
/// against legacy 384-dim noop@1 rows in the same query.
fn vector_lane<E: Embedder + ?Sized>(
    conn: &Connection,
    text: &str,
    query: &CodeQuery<'_>,
    embedder: &E,
    cap: usize,
) -> Result<Vec<RawHit>, BtError> {
    let q_vec = embedder.embed_query(text);
    if q_vec.is_empty() {
        return Ok(Vec::new());
    }
    let metadata = embedder.metadata();

    // Build the SQL with project + language filters inline. The
    // `embedding_model_id` filter ensures we never compare a qwen3
    // query embedding against a noop hash row.
    let mut sql = String::from(
        "SELECT project_id, repo_path, chunk_index, language, node_kind, qualified_name, \
         start_line, end_line, text, embedding, embedding_quant \
         FROM code_chunks WHERE embedding_model_id = ?1 AND embedding_dimension = ?2",
    );
    let mut vparams: Vec<rusqlite::types::Value> = vec![
        rusqlite::types::Value::from(metadata.model_id.clone()),
        rusqlite::types::Value::from(metadata.dimension as i64),
    ];
    if let Some(pids) = query.project_ids {
        if !pids.is_empty() {
            sql.push_str(" AND project_id IN (");
            for (i, pid) in pids.iter().enumerate() {
                if i > 0 {
                    sql.push(',');
                }
                vparams.push(rusqlite::types::Value::from(pid.clone()));
                sql.push_str(&format!("?{}", vparams.len()));
            }
            sql.push(')');
        }
    }
    if let Some(langs) = query.languages {
        if !langs.is_empty() {
            sql.push_str(" AND language IN (");
            for (i, lang) in langs.iter().enumerate() {
                if i > 0 {
                    sql.push(',');
                }
                vparams.push(rusqlite::types::Value::from(lang.clone()));
                sql.push_str(&format!("?{}", vparams.len()));
            }
            sql.push(')');
        }
    }

    let mut stmt = conn.prepare(&sql)?;
    let bound: Vec<&dyn rusqlite::ToSql> = vparams.iter().map(|v| v as &dyn rusqlite::ToSql).collect();
    let rows = stmt.query_map(&bound[..], |row| {
        let project_id: String = row.get(0)?;
        let repo_path: String = row.get(1)?;
        let chunk_index: i64 = row.get(2)?;
        let language: String = row.get(3)?;
        let node_kind: Option<String> = row.get(4)?;
        let qualified_name: Option<String> = row.get(5)?;
        let start_line: i64 = row.get(6)?;
        let end_line: i64 = row.get(7)?;
        let text: String = row.get(8)?;
        let blob: Vec<u8> = row.get(9)?;
        let quant: String = row.get(10)?;
        Ok((
            project_id,
            repo_path,
            chunk_index,
            language,
            node_kind,
            qualified_name,
            start_line,
            end_line,
            text,
            blob,
            quant,
        ))
    })?;

    let mut scored: Vec<(f32, RawHit)> = Vec::new();
    for row in rows {
        let (project_id, repo_path, chunk_index, language, node_kind, qualified_name, start_line, end_line, text, blob, quant) = match row {
            Ok(t) => t,
            Err(_) => continue,
        };
        let vec = decode_embedding(&blob, &quant);
        let score = cosine(&q_vec, &vec);
        if score.abs() < 1e-6 {
            continue;
        }
        scored.push((
            score,
            RawHit {
                project_id,
                repo_path,
                chunk_index,
                language,
                node_kind,
                qualified_name,
                start_line,
                end_line,
                text,
                vector_score: Some(score),
                lexical_score: None,
            },
        ));
    }
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(cap);
    Ok(scored.into_iter().map(|(_, h)| h).collect())
}

/// FTS5 lexical match. `bm25()` returns smaller-is-better; we negate
/// + min-max-normalize before merging so higher == better consistently.
fn lexical_lane(
    conn: &Connection,
    text: &str,
    query: &CodeQuery<'_>,
    cap: usize,
) -> Result<Vec<RawHit>, BtError> {
    let mut sql = String::from(
        "SELECT c.project_id, c.repo_path, c.chunk_index, c.language, c.node_kind, \
         c.qualified_name, c.start_line, c.end_line, c.text, bm25(fts_code) AS score \
         FROM fts_code f \
         JOIN code_chunks c ON c.project_id = f.project_id AND c.repo_path = f.repo_path \
         WHERE fts_code MATCH ?1",
    );
    let mut vparams: Vec<rusqlite::types::Value> = vec![rusqlite::types::Value::from(escape_fts(text))];
    if let Some(pids) = query.project_ids {
        if !pids.is_empty() {
            sql.push_str(" AND c.project_id IN (");
            for (i, pid) in pids.iter().enumerate() {
                if i > 0 {
                    sql.push(',');
                }
                vparams.push(rusqlite::types::Value::from(pid.clone()));
                sql.push_str(&format!("?{}", vparams.len()));
            }
            sql.push(')');
        }
    }
    if let Some(langs) = query.languages {
        if !langs.is_empty() {
            sql.push_str(" AND c.language IN (");
            for (i, lang) in langs.iter().enumerate() {
                if i > 0 {
                    sql.push(',');
                }
                vparams.push(rusqlite::types::Value::from(lang.clone()));
                sql.push_str(&format!("?{}", vparams.len()));
            }
            sql.push(')');
        }
    }
    sql.push_str(&format!(" ORDER BY score ASC LIMIT {cap}"));

    let mut stmt = conn.prepare(&sql)?;
    let bound: Vec<&dyn rusqlite::ToSql> = vparams.iter().map(|v| v as &dyn rusqlite::ToSql).collect();
    let rows = stmt.query_map(&bound[..], |row| {
        let project_id: String = row.get(0)?;
        let repo_path: String = row.get(1)?;
        let chunk_index: i64 = row.get(2)?;
        let language: String = row.get(3)?;
        let node_kind: Option<String> = row.get(4)?;
        let qualified_name: Option<String> = row.get(5)?;
        let start_line: i64 = row.get(6)?;
        let end_line: i64 = row.get(7)?;
        let text: String = row.get(8)?;
        let raw: f64 = row.get(9)?;
        Ok((
            project_id,
            repo_path,
            chunk_index,
            language,
            node_kind,
            qualified_name,
            start_line,
            end_line,
            text,
            raw,
        ))
    })?;

    let collected: Vec<_> = rows.filter_map(|r| r.ok()).collect();
    if collected.is_empty() {
        return Ok(Vec::new());
    }
    // BM25 in SQLite returns larger negative numbers = better. Map
    // to [0, 1] so the merge stage can blend with cosine.
    let scores: Vec<f64> = collected.iter().map(|t| t.9).collect();
    let min_s = scores.iter().cloned().fold(f64::INFINITY, f64::min);
    let max_s = scores.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let span = (max_s - min_s).abs().max(1e-9);

    let mut hits = Vec::with_capacity(collected.len());
    for (project_id, repo_path, chunk_index, language, node_kind, qualified_name, start_line, end_line, text, raw) in collected {
        let normalized = ((max_s - raw) / span) as f32; // best score -> 1.0
        hits.push(RawHit {
            project_id,
            repo_path,
            chunk_index,
            language,
            node_kind,
            qualified_name,
            start_line,
            end_line,
            text,
            vector_score: None,
            lexical_score: Some(normalized),
        });
    }
    Ok(hits)
}

/// Combine vector + lexical hits keyed by (project_id, repo_path,
/// chunk_index). When both lanes hit, take the max score per lane and
/// blend via the configured alpha. When only one lane hits, the other
/// score stays None and the combined score uses the present lane only
/// scaled by its weight.
fn merge(
    vector: Vec<RawHit>,
    lexical: Vec<RawHit>,
    alpha: f32,
    limit: usize,
) -> Vec<CodeSearchHit> {
    let mut by_key: HashMap<(String, String, i64), MergedHit> = HashMap::new();
    for h in vector {
        let key = (h.project_id.clone(), h.repo_path.clone(), h.chunk_index);
        let entry = by_key.entry(key).or_insert_with(|| MergedHit::from_raw(&h));
        entry.vector_score = h.vector_score;
    }
    for h in lexical {
        let key = (h.project_id.clone(), h.repo_path.clone(), h.chunk_index);
        let entry = by_key.entry(key).or_insert_with(|| MergedHit::from_raw(&h));
        entry.lexical_score = h.lexical_score;
    }

    let mut merged: Vec<CodeSearchHit> = by_key
        .into_values()
        .map(|m| m.into_hit(alpha))
        .collect();
    merged.sort_by(|a, b| {
        b.combined_score
            .partial_cmp(&a.combined_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    merged.truncate(limit);
    merged
}

#[derive(Debug, Clone)]
struct RawHit {
    project_id: String,
    repo_path: String,
    chunk_index: i64,
    language: String,
    node_kind: Option<String>,
    qualified_name: Option<String>,
    start_line: i64,
    end_line: i64,
    text: String,
    vector_score: Option<f32>,
    lexical_score: Option<f32>,
}

struct MergedHit {
    project_id: String,
    repo_path: String,
    chunk_index: i64,
    language: String,
    node_kind: Option<String>,
    qualified_name: Option<String>,
    start_line: i64,
    end_line: i64,
    text: String,
    vector_score: Option<f32>,
    lexical_score: Option<f32>,
}

impl MergedHit {
    fn from_raw(h: &RawHit) -> Self {
        Self {
            project_id: h.project_id.clone(),
            repo_path: h.repo_path.clone(),
            chunk_index: h.chunk_index,
            language: h.language.clone(),
            node_kind: h.node_kind.clone(),
            qualified_name: h.qualified_name.clone(),
            start_line: h.start_line,
            end_line: h.end_line,
            text: h.text.clone(),
            vector_score: h.vector_score,
            lexical_score: h.lexical_score,
        }
    }

    fn into_hit(self, alpha: f32) -> CodeSearchHit {
        let v = self.vector_score.unwrap_or(0.0);
        let l = self.lexical_score.unwrap_or(0.0);
        let combined = alpha * v + (1.0 - alpha) * l;
        let excerpt = excerpt_for(&self.text);
        CodeSearchHit {
            project_id: self.project_id,
            repo_path: self.repo_path,
            chunk_index: self.chunk_index,
            language: self.language,
            node_kind: self.node_kind,
            qualified_name: self.qualified_name,
            start_line: self.start_line,
            end_line: self.end_line,
            excerpt,
            vector_score: self.vector_score,
            lexical_score: self.lexical_score,
            combined_score: combined,
        }
    }
}

/// Trim an excerpt to ~280 chars on a line boundary so MCP / CLI
/// output stays tight without slicing UTF-8 mid-codepoint.
fn excerpt_for(text: &str) -> String {
    const TARGET: usize = 280;
    let trimmed = text.trim_start_matches(|c: char| c.is_whitespace());
    if trimmed.len() <= TARGET {
        return trimmed.to_string();
    }
    // Prefer a cut at the last newline before TARGET so we don't
    // chop a token in half.
    let head = &trimmed[..TARGET.min(trimmed.len())];
    if let Some(idx) = head.rfind('\n') {
        return format!("{}…", &trimmed[..idx]);
    }
    // Char-boundary safe truncation.
    let mut end = TARGET.min(trimmed.len());
    while !trimmed.is_char_boundary(end) && end > 0 {
        end -= 1;
    }
    format!("{}…", &trimmed[..end])
}

/// FTS5 reserves `"`, `'`, `-`, `:`, `^` and parens. For free-form
/// user queries we drop those and quote the rest as a phrase to keep
/// MATCH happy. Identifier-y queries (`spawn_session` etc.) round-
/// trip cleanly because alphanumerics + `_` are safe.
fn escape_fts(text: &str) -> String {
    let cleaned: String = text
        .chars()
        .map(|c| match c {
            '"' | '\'' | '(' | ')' | ':' | '^' | '*' | '-' => ' ',
            other => other,
        })
        .collect();
    let trimmed = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    if trimmed.is_empty() {
        return String::new();
    }
    // Wrap as a phrase so multi-token queries don't OR-explode.
    format!("\"{trimmed}\"")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::code::store::{content_sha256, register_project, replace_chunks_for_file};
    use crate::code::{chunker::CodeChunk, language::Language};
    use crate::migrations::migrate;
    use crate::notes::embeddings::{EmbeddingModelMetadata, NoopEmbedder};

    fn open_test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        migrate(&conn).unwrap();
        conn
    }

    fn seed_chunks(conn: &mut Connection) {
        register_project(conn, "p1", "Demo", "/tmp/demo", true).unwrap();
        let chunks = vec![
            CodeChunk {
                text: "fn spawn_session() -> Session { todo!() }".into(),
                language: Language::Rust,
                node_kind: Some("function_item".into()),
                qualified_name: Some("spawn_session".into()),
                start_line: 0,
                end_line: 0,
                byte_start: 0,
                byte_end: 41,
            },
            CodeChunk {
                text: "fn render_glyph_atlas() {}".into(),
                language: Language::Rust,
                node_kind: Some("function_item".into()),
                qualified_name: Some("render_glyph_atlas".into()),
                start_line: 5,
                end_line: 5,
                byte_start: 50,
                byte_end: 75,
            },
        ];
        let meta = EmbeddingModelMetadata::noop();
        let embedder = NoopEmbedder;
        let vecs: Vec<Vec<f32>> = chunks.iter().map(|c| embedder.embed(&c.text)).collect();
        replace_chunks_for_file(
            conn,
            "p1",
            "src/lib.rs",
            Language::Rust,
            &content_sha256("dummy"),
            0,
            100,
            10,
            &chunks,
            &vecs,
            &meta,
        )
        .unwrap();
    }

    #[test]
    fn lexical_lane_hits_identifier() {
        let mut conn = open_test_db();
        seed_chunks(&mut conn);
        let q = CodeQuery::new("spawn_session");
        let hits = code_hybrid_search(&conn, &q, &NoopEmbedder).unwrap();
        assert!(!hits.is_empty());
        assert_eq!(hits[0].repo_path, "src/lib.rs");
        assert!(hits[0].lexical_score.is_some());
    }

    #[test]
    fn project_filter_excludes_other_projects() {
        let mut conn = open_test_db();
        seed_chunks(&mut conn);
        register_project(&conn, "p2", "Other", "/tmp/other", true).unwrap();
        let pids = vec!["p2".to_string()];
        let mut q = CodeQuery::new("spawn_session");
        q.project_ids = Some(&pids);
        let hits = code_hybrid_search(&conn, &q, &NoopEmbedder).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn empty_query_returns_nothing() {
        let conn = open_test_db();
        let q = CodeQuery::new("   ");
        let hits = code_hybrid_search(&conn, &q, &NoopEmbedder).unwrap();
        assert!(hits.is_empty());
    }
}
