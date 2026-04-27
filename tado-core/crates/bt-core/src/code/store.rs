//! Persistence layer for codebase chunks. Mirrors
//! [`crate::notes::store`]'s discipline: every write is a single
//! transaction, embedding BLOB carries length-prefixed `f32` or
//! quantized `i8` data, and the metadata stamp is recorded per row
//! so future re-embedding sweeps can target outdated rows.

use rusqlite::{params, Connection};
use sha2::{Digest, Sha256};

use crate::code::chunker::CodeChunk;
use crate::code::language::Language;
use crate::error::BtError;
use crate::notes::embeddings::EmbeddingModelMetadata;

/// Row from `code_files`. Used to skip files that haven't changed
/// since last index — avoids re-embedding 99% of a project on
/// incremental update.
#[derive(Debug, Clone)]
pub struct CodeFileMeta {
    pub project_id: String,
    pub repo_path: String,
    pub content_sha256: String,
    pub language: Language,
}

/// Persisted chunk read back from the DB. `embedding` is decoded into
/// `f32` regardless of `embedding_quant` so callers can compute cosine
/// directly.
#[derive(Debug, Clone)]
pub struct StoredCodeChunk {
    pub project_id: String,
    pub repo_path: String,
    pub chunk_index: i64,
    pub text: String,
    pub language: String,
    pub node_kind: Option<String>,
    pub qualified_name: Option<String>,
    pub start_line: i64,
    pub end_line: i64,
    pub byte_start: i64,
    pub byte_end: i64,
    pub content_sha256: String,
    pub embedding: Vec<f32>,
    pub embedding_model_id: String,
    pub embedding_model_version: String,
    pub embedding_dimension: i64,
}

pub fn register_project(
    conn: &Connection,
    project_id: &str,
    name: &str,
    root_path: &str,
    enabled: bool,
) -> Result<(), BtError> {
    conn.execute(
        r#"
        INSERT INTO code_projects (project_id, name, root_path, enabled, updated_at)
        VALUES (?1, ?2, ?3, ?4, datetime('now'))
        ON CONFLICT(project_id) DO UPDATE SET
            name = excluded.name,
            root_path = excluded.root_path,
            enabled = excluded.enabled,
            updated_at = datetime('now')
        "#,
        params![project_id, name, root_path, if enabled { 1 } else { 0 }],
    )?;
    Ok(())
}

pub fn unregister_project(
    conn: &Connection,
    project_id: &str,
    purge: bool,
) -> Result<(), BtError> {
    if purge {
        purge_project(conn, project_id)?;
    }
    conn.execute(
        "DELETE FROM code_projects WHERE project_id = ?1",
        params![project_id],
    )?;
    Ok(())
}

pub fn purge_project(conn: &Connection, project_id: &str) -> Result<(), BtError> {
    // ON DELETE CASCADE on code_files / code_chunks via FKs handles
    // this, but the sqlite default is foreign_keys=OFF unless we set
    // it. Be explicit with manual deletes to keep the behavior
    // robust.
    conn.execute(
        "DELETE FROM fts_code WHERE project_id = ?1",
        params![project_id],
    )
    .ok();
    conn.execute(
        "DELETE FROM code_chunks WHERE project_id = ?1",
        params![project_id],
    )?;
    conn.execute(
        "DELETE FROM code_files WHERE project_id = ?1",
        params![project_id],
    )?;
    Ok(())
}

/// Compute a stable SHA-256 of the file content. Used to skip
/// re-embedding when content hasn't changed.
pub fn content_sha256(content: &str) -> String {
    let mut h = Sha256::new();
    h.update(content.as_bytes());
    format!("{:x}", h.finalize())
}

pub fn read_file_meta(
    conn: &Connection,
    project_id: &str,
    repo_path: &str,
) -> Result<Option<CodeFileMeta>, BtError> {
    let mut stmt = conn.prepare(
        "SELECT content_sha256, language FROM code_files WHERE project_id = ?1 AND repo_path = ?2",
    )?;
    let mut rows = stmt.query(params![project_id, repo_path])?;
    if let Some(row) = rows.next()? {
        let sha: String = row.get(0)?;
        let lang_str: String = row.get(1)?;
        let language = parse_language(&lang_str);
        return Ok(Some(CodeFileMeta {
            project_id: project_id.to_string(),
            repo_path: repo_path.to_string(),
            content_sha256: sha,
            language,
        }));
    }
    Ok(None)
}

/// Replace every chunk for a single file in one transaction.
/// Delete-then-insert keeps the row count bounded; updates that
/// shrink a file leave no orphan chunks. Embeddings are encoded as
/// length-prefixed BLOBs (4-byte LE count of f32s, then the
/// `i8`-quantized payload).
pub fn replace_chunks_for_file(
    conn: &mut Connection,
    project_id: &str,
    repo_path: &str,
    language: Language,
    content_sha: &str,
    file_mtime_ns: i64,
    byte_size: i64,
    line_count: i64,
    chunks: &[CodeChunk],
    embeddings: &[Vec<f32>],
    metadata: &EmbeddingModelMetadata,
) -> Result<(), BtError> {
    if chunks.len() != embeddings.len() {
        return Err(BtError::Internal(format!(
            "chunk/embedding length mismatch: {} chunks, {} embeddings",
            chunks.len(),
            embeddings.len()
        )));
    }

    let tx = conn.transaction()?;

    tx.execute(
        r#"
        INSERT INTO code_files (
            project_id, repo_path, language, content_sha256,
            file_mtime_ns, byte_size, line_count, last_indexed_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, datetime('now'))
        ON CONFLICT(project_id, repo_path) DO UPDATE SET
            language = excluded.language,
            content_sha256 = excluded.content_sha256,
            file_mtime_ns = excluded.file_mtime_ns,
            byte_size = excluded.byte_size,
            line_count = excluded.line_count,
            last_indexed_at = datetime('now')
        "#,
        params![
            project_id,
            repo_path,
            language.as_str(),
            content_sha,
            file_mtime_ns,
            byte_size,
            line_count,
        ],
    )?;

    tx.execute(
        "DELETE FROM code_chunks WHERE project_id = ?1 AND repo_path = ?2",
        params![project_id, repo_path],
    )?;
    tx.execute(
        "DELETE FROM fts_code WHERE project_id = ?1 AND repo_path = ?2",
        params![project_id, repo_path],
    )?;

    {
        let mut insert_chunk = tx.prepare(
            r#"
            INSERT INTO code_chunks (
                project_id, repo_path, chunk_index, text, language,
                node_kind, qualified_name,
                start_line, end_line, byte_start, byte_end,
                content_sha256, embedding, embedding_quant,
                embedding_model_id, embedding_model_version,
                embedding_dimension, embedding_pooling,
                embedding_instruction, embedding_source_hash
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                      ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)
            "#,
        )?;
        let mut insert_fts = tx.prepare(
            "INSERT INTO fts_code (project_id, repo_path, language, text) VALUES (?1, ?2, ?3, ?4)",
        )?;

        for (idx, (chunk, vector)) in chunks.iter().zip(embeddings.iter()).enumerate() {
            let (blob, quant_label) = encode_embedding(vector, metadata);
            insert_chunk.execute(params![
                project_id,
                repo_path,
                idx as i64,
                chunk.text,
                chunk.language.as_str(),
                chunk.node_kind,
                chunk.qualified_name,
                chunk.start_line as i64,
                chunk.end_line as i64,
                chunk.byte_start as i64,
                chunk.byte_end as i64,
                content_sha,
                blob,
                quant_label,
                metadata.model_id,
                metadata.model_version,
                metadata.dimension as i64,
                metadata.pooling,
                metadata.instruction,
                metadata.source_hash,
            ])?;
            insert_fts.execute(params![project_id, repo_path, chunk.language.as_str(), chunk.text])?;
        }
    }

    tx.commit()?;
    Ok(())
}

/// Encode an embedding vector. We quantize qwen3 (1024-dim) to `i8`
/// so 50k-file projects stay under ~256 MB of vault. Legacy noop@1
/// (384-dim) stays `f32` because the volume is tiny.
fn encode_embedding(vector: &[f32], metadata: &EmbeddingModelMetadata) -> (Vec<u8>, &'static str) {
    if metadata.model_id == "noop" {
        let mut blob = Vec::with_capacity(vector.len() * 4);
        for v in vector {
            blob.extend_from_slice(&v.to_le_bytes());
        }
        (blob, "f32")
    } else {
        // i8 quantization. L2-normalized vectors are already in
        // [-1, 1]; scale by 127 and clamp.
        let mut blob = Vec::with_capacity(vector.len());
        for v in vector {
            let scaled = (v * 127.0).round().clamp(-127.0, 127.0) as i8;
            blob.push(scaled as u8);
        }
        (blob, "i8")
    }
}

/// Inverse of `encode_embedding`. Reads the `embedding_quant` column
/// to decide format.
pub fn decode_embedding(bytes: &[u8], quant: &str) -> Vec<f32> {
    match quant {
        "i8" => bytes
            .iter()
            .map(|&b| (b as i8) as f32 / 127.0)
            .collect(),
        _ => {
            // f32 little-endian
            let mut out = Vec::with_capacity(bytes.len() / 4);
            for chunk in bytes.chunks_exact(4) {
                let arr: [u8; 4] = chunk.try_into().unwrap_or([0; 4]);
                out.push(f32::from_le_bytes(arr));
            }
            out
        }
    }
}

fn parse_language(s: &str) -> Language {
    match s {
        "swift" => Language::Swift,
        "rust" => Language::Rust,
        "typescript" => Language::TypeScript,
        "tsx" => Language::Tsx,
        "javascript" => Language::JavaScript,
        "jsx" => Language::Jsx,
        "python" => Language::Python,
        "go" => Language::Go,
        "java" => Language::Java,
        "kotlin" => Language::Kotlin,
        "c" => Language::C,
        "cpp" => Language::Cpp,
        "c-header" => Language::Header,
        "markdown" => Language::Markdown,
        "json" => Language::Json,
        "yaml" => Language::Yaml,
        "toml" => Language::Toml,
        "shell" => Language::Shell,
        _ => Language::Other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migrations::migrate;
    use rusqlite::Connection;

    fn open_test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        migrate(&conn).unwrap();
        conn
    }

    #[test]
    fn register_unregister_project_roundtrip() {
        let conn = open_test_db();
        register_project(&conn, "p1", "Demo", "/tmp/demo", true).unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM code_projects WHERE project_id='p1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
        unregister_project(&conn, "p1", true).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM code_projects", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn replace_chunks_persists_and_replaces() {
        let mut conn = open_test_db();
        register_project(&conn, "p1", "Demo", "/tmp/demo", true).unwrap();

        let chunks = vec![CodeChunk {
            text: "fn alpha() {}".to_string(),
            language: Language::Rust,
            node_kind: Some("function_item".to_string()),
            qualified_name: Some("alpha".to_string()),
            start_line: 0,
            end_line: 0,
            byte_start: 0,
            byte_end: 13,
        }];
        let vec = vec![0.1f32; 1024];
        let meta = EmbeddingModelMetadata {
            model_id: "Qwen/Qwen3-Embedding-0.6B".into(),
            model_version: "qwen3-embedding-0.6b@1".into(),
            dimension: 1024,
            pooling: "last_token".into(),
            instruction: "".into(),
            source_hash: "sha256:demo".into(),
        };
        replace_chunks_for_file(
            &mut conn,
            "p1",
            "src/lib.rs",
            Language::Rust,
            &content_sha256("fn alpha() {}"),
            0,
            13,
            1,
            &chunks,
            std::slice::from_ref(&vec),
            &meta,
        )
        .unwrap();

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM code_chunks WHERE project_id='p1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);

        // Replace with empty — old chunks deleted.
        replace_chunks_for_file(
            &mut conn,
            "p1",
            "src/lib.rs",
            Language::Rust,
            "newsha",
            0,
            0,
            0,
            &[],
            &[],
            &meta,
        )
        .unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM code_chunks WHERE project_id='p1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn i8_quant_roundtrip_keeps_signal() {
        let original: Vec<f32> = vec![0.5, -0.3, 0.0, 1.0, -1.0, 0.2];
        let meta = EmbeddingModelMetadata {
            model_id: "Qwen/Qwen3-Embedding-0.6B".into(),
            model_version: "qwen3-embedding-0.6b@1".into(),
            dimension: 6,
            pooling: "last_token".into(),
            instruction: "".into(),
            source_hash: "sha256:demo".into(),
        };
        let (blob, quant) = encode_embedding(&original, &meta);
        assert_eq!(quant, "i8");
        let decoded = decode_embedding(&blob, quant);
        assert_eq!(decoded.len(), original.len());
        for (a, b) in original.iter().zip(decoded.iter()) {
            assert!((a - b).abs() < 0.01, "roundtrip drift {a} vs {b}");
        }
    }

    #[test]
    fn f32_quant_for_noop() {
        let original: Vec<f32> = vec![0.5, -0.3, 0.0, 1.0];
        let meta = EmbeddingModelMetadata::noop();
        let (blob, quant) = encode_embedding(&original, &meta);
        assert_eq!(quant, "f32");
        let decoded = decode_embedding(&blob, quant);
        assert_eq!(decoded, original);
    }
}
