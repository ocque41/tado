//! Persistence layer for note chunks.
//!
//! Writes and reads the `note_chunks` table added by migration_18.
//! The table holds per-chunk text, the parent document + scope, the
//! heading path as a joined string (for display), the byte range in
//! the source markdown, and the serialized embedding.
//!
//! Embeddings are stored as raw little-endian `f32` bytes in a BLOB
//! column. This avoids the extra compile-time cost of pulling in
//! `sqlite-vec` until the real embedder lands; brute-force cosine
//! over a few thousand rows is plenty fast at note-taking scale and
//! keeps the build simple.

use crate::error::BtError;
use crate::notes::embeddings::{Embedder, EmbeddingModelMetadata};
use rusqlite::{params, Connection};

/// A chunk row as stored on disk.
#[derive(Debug, Clone)]
pub struct StoredChunk {
    pub doc_id: String,
    pub scope: String,
    pub chunk_index: i64,
    pub text: String,
    pub heading_path: String,
    pub byte_start: i64,
    pub byte_end: i64,
    pub embedding: Vec<f32>,
    pub embedding_model: EmbeddingModelMetadata,
}

/// Replace all chunks for `(doc_id, scope)` with a fresh set derived
/// from `markdown`, using `embedder` to produce one embedding per
/// chunk. Runs inside a single transaction so there is never a
/// partially-reindexed window.
pub fn reindex_note<E: Embedder + ?Sized>(
    conn: &Connection,
    doc_id: &str,
    scope: &str,
    markdown: &str,
    embedder: &E,
) -> Result<usize, BtError> {
    let chunks = crate::notes::chunker::chunk_markdown(markdown);
    let metadata = embedder.metadata();
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "DELETE FROM note_chunks WHERE doc_id = ?1 AND scope = ?2",
        params![doc_id, scope],
    )?;

    // Batch-embed for efficiency once the real embedder lands; the
    // NoopEmbedder default impl just forwards.
    let texts: Vec<String> = chunks.iter().map(|c| c.text.clone()).collect();
    let vectors = embedder.embed_batch(&texts);

    for (chunk, vector) in chunks.iter().zip(vectors.iter()) {
        if vector.len() != metadata.dimension {
            return Err(BtError::Validation(format!(
                "embedder returned {} dims, expected {}",
                vector.len(),
                metadata.dimension
            )));
        }
        tx.execute(
            r#"
            INSERT INTO note_chunks(
                doc_id, scope, chunk_index, text,
                heading_path, byte_start, byte_end, embedding,
                embedding_model_id, embedding_model_version,
                embedding_dimension, embedding_pooling,
                embedding_instruction, embedding_source_hash
            ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            "#,
            params![
                doc_id,
                scope,
                chunk.index as i64,
                chunk.text,
                chunk.heading_path.join(" / "),
                chunk.byte_range.start as i64,
                chunk.byte_range.end as i64,
                f32_vec_to_bytes(vector),
                metadata.model_id,
                metadata.model_version,
                metadata.dimension as i64,
                metadata.pooling,
                metadata.instruction,
                metadata.source_hash,
            ],
        )?;
    }
    let count = chunks.len();
    tx.commit()?;
    Ok(count)
}

/// Remove all chunks for a document (both scopes).
pub fn purge_note(conn: &Connection, doc_id: &str) -> Result<(), BtError> {
    conn.execute("DELETE FROM note_chunks WHERE doc_id = ?1", params![doc_id])?;
    Ok(())
}

/// Fetch every chunk in the given scope (or all scopes if `scope` is
/// `"all"`). Used by the brute-force cosine search path; once
/// `sqlite-vec` is wired we replace this with an ANN query.
pub fn iter_all_chunks(conn: &Connection, scope: &str) -> Result<Vec<StoredChunk>, BtError> {
    let (sql, rows) = if scope == "all" {
        let sql = r#"
            SELECT doc_id, scope, chunk_index, text, heading_path,
                   byte_start, byte_end, embedding,
                   embedding_model_id, embedding_model_version,
                   embedding_dimension, embedding_pooling,
                   embedding_instruction, embedding_source_hash
            FROM note_chunks
            ORDER BY doc_id, scope, chunk_index
        "#;
        (sql, Vec::<rusqlite::types::Value>::new())
    } else {
        let sql = r#"
            SELECT doc_id, scope, chunk_index, text, heading_path,
                   byte_start, byte_end, embedding,
                   embedding_model_id, embedding_model_version,
                   embedding_dimension, embedding_pooling,
                   embedding_instruction, embedding_source_hash
            FROM note_chunks
            WHERE scope = ?1
            ORDER BY doc_id, chunk_index
        "#;
        (sql, vec![rusqlite::types::Value::Text(scope.to_string())])
    };

    let mut stmt = conn.prepare(sql)?;
    let mut rows_iter = if rows.is_empty() {
        stmt.query([])?
    } else {
        stmt.query(rusqlite::params_from_iter(rows.iter()))?
    };

    let mut out = Vec::new();
    while let Some(row) = rows_iter.next()? {
        let blob: Vec<u8> = row.get(7)?;
        let dimension: i64 = row.get(10)?;
        out.push(StoredChunk {
            doc_id: row.get(0)?,
            scope: row.get(1)?,
            chunk_index: row.get(2)?,
            text: row.get(3)?,
            heading_path: row.get(4)?,
            byte_start: row.get(5)?,
            byte_end: row.get(6)?,
            embedding: bytes_to_f32_vec(&blob),
            embedding_model: EmbeddingModelMetadata {
                model_id: row.get(8)?,
                model_version: row.get(9)?,
                dimension: dimension.max(0) as usize,
                pooling: row.get(11)?,
                instruction: row.get(12)?,
                source_hash: row.get(13)?,
            },
        });
    }
    Ok(out)
}

/// Encode an `f32` vector as raw little-endian bytes. Paired with
/// [`bytes_to_f32_vec`].
pub fn f32_vec_to_bytes(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for x in v {
        out.extend_from_slice(&x.to_le_bytes());
    }
    out
}

/// Inverse of [`f32_vec_to_bytes`]. Returns an empty vec if the byte
/// length isn't a multiple of 4.
pub fn bytes_to_f32_vec(bytes: &[u8]) -> Vec<f32> {
    if bytes.len() % 4 != 0 {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(bytes.len() / 4);
    for chunk in bytes.chunks_exact(4) {
        out.push(f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notes::embeddings::{NoopEmbedder, LEGACY_EMBEDDING_DIMENSIONS};

    fn mem_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        // Apply just the parts of the schema we need for chunk tests.
        conn.execute_batch(
            r#"
            CREATE TABLE note_chunks (
                doc_id        TEXT NOT NULL,
                scope         TEXT NOT NULL,
                chunk_index   INTEGER NOT NULL,
                text          TEXT NOT NULL,
                heading_path  TEXT NOT NULL,
                byte_start    INTEGER NOT NULL,
                byte_end      INTEGER NOT NULL,
                embedding     BLOB NOT NULL,
                embedding_model_id TEXT NOT NULL DEFAULT 'noop',
                embedding_model_version TEXT NOT NULL DEFAULT 'noop@1',
                embedding_dimension INTEGER NOT NULL DEFAULT 384,
                embedding_pooling TEXT NOT NULL DEFAULT 'hash-bucket',
                embedding_instruction TEXT NOT NULL DEFAULT '',
                embedding_source_hash TEXT NOT NULL DEFAULT 'legacy-noop',
                PRIMARY KEY (doc_id, scope, chunk_index)
            );
            CREATE INDEX idx_note_chunks_scope ON note_chunks(scope);
            "#,
        )
        .unwrap();
        conn
    }

    #[test]
    fn roundtrip_bytes_f32() {
        let v = vec![1.0_f32, -2.5, 3.75, 0.0];
        let bytes = f32_vec_to_bytes(&v);
        let back = bytes_to_f32_vec(&bytes);
        assert_eq!(v, back);
    }

    #[test]
    fn bad_byte_length_returns_empty() {
        let bytes = vec![1u8, 2, 3]; // not divisible by 4
        assert!(bytes_to_f32_vec(&bytes).is_empty());
    }

    #[test]
    fn reindex_writes_expected_chunks() {
        let conn = mem_db();
        let embedder = NoopEmbedder;
        let md = "# A\nalpha body\n\n# B\nbeta body\n";
        let count = reindex_note(&conn, "doc1", "user", md, &embedder).unwrap();
        assert_eq!(count, 2);
        let chunks = iter_all_chunks(&conn, "user").unwrap();
        assert_eq!(chunks.len(), 2);
        assert!(chunks[0].text.contains("A"));
        assert!(chunks[1].text.contains("B"));
        assert_eq!(chunks[0].embedding.len(), LEGACY_EMBEDDING_DIMENSIONS);
        assert_eq!(chunks[0].embedding_model.model_version, "noop@1");
    }

    #[test]
    fn reindex_replaces_previous_chunks() {
        let conn = mem_db();
        let embedder = NoopEmbedder;
        reindex_note(&conn, "doc1", "user", "# A\nbody\n", &embedder).unwrap();
        reindex_note(&conn, "doc1", "user", "# X\nnew\n# Y\ntwo\n", &embedder).unwrap();
        let chunks = iter_all_chunks(&conn, "user").unwrap();
        assert_eq!(chunks.len(), 2);
        assert!(chunks[0].text.contains("X"));
        assert!(chunks[1].text.contains("Y"));
    }

    #[test]
    fn purge_note_clears_all_scopes() {
        let conn = mem_db();
        let embedder = NoopEmbedder;
        reindex_note(&conn, "doc1", "user", "# A\nbody\n", &embedder).unwrap();
        reindex_note(&conn, "doc1", "agent", "# B\nbody\n", &embedder).unwrap();
        purge_note(&conn, "doc1").unwrap();
        assert!(iter_all_chunks(&conn, "all").unwrap().is_empty());
    }
}
