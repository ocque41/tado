//! Codebase index orchestration: walk → chunk → embed → store.
//!
//! Single entry point `run_full_index(project_id, root_path, ...)`
//! processes a project in series (one file at a time). Concurrency
//! is intentionally minimal for v1: the embedding runtime is
//! `Mutex<Qwen3Runtime>` and serializes all calls anyway, and SQLite
//! has a single writer. Adding parallelism inside the walker (rayon
//! for chunking, mpsc-bounded embed dispatch) is a Phase 4 follow-up.

use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use rusqlite::Connection;
use serde::Serialize;

use crate::code::chunker::{default_chunker, CodeChunk, Chunker};
use crate::code::store;
use crate::code::walker::{walk_project, WalkedFile};
use crate::error::BtError;
use crate::notes::embeddings::{Embedder, EmbeddingModelMetadata};

/// Live counters the FFI surfaces to Swift via `code.index_status`.
/// Updated atomically as files complete; readable from any thread.
#[derive(Debug, Default)]
pub struct IndexProgress {
    pub project_id: String,
    pub files_total: AtomicUsize,
    pub files_done: AtomicUsize,
    pub chunks_done: AtomicUsize,
    pub bytes_done: AtomicUsize,
    pub running: AtomicBool,
    pub error: parking_lot_index::Mutex<Option<String>>,
    pub started_at: parking_lot_index::Mutex<Option<String>>,
    pub finished_at: parking_lot_index::Mutex<Option<String>>,
}

mod parking_lot_index {
    pub use std::sync::Mutex;
}

impl IndexProgress {
    pub fn new(project_id: String) -> Arc<Self> {
        Arc::new(Self {
            project_id,
            ..Default::default()
        })
    }

    pub fn snapshot(&self) -> ProgressSnapshot {
        ProgressSnapshot {
            project_id: self.project_id.clone(),
            files_total: self.files_total.load(Ordering::Relaxed),
            files_done: self.files_done.load(Ordering::Relaxed),
            chunks_done: self.chunks_done.load(Ordering::Relaxed),
            bytes_done: self.bytes_done.load(Ordering::Relaxed),
            running: self.running.load(Ordering::Relaxed),
            error: self.error.lock().ok().and_then(|g| g.clone()),
            started_at: self.started_at.lock().ok().and_then(|g| g.clone()),
            finished_at: self.finished_at.lock().ok().and_then(|g| g.clone()),
        }
    }

    fn mark_started(&self) {
        self.running.store(true, Ordering::Relaxed);
        if let Ok(mut g) = self.started_at.lock() {
            *g = Some(now_iso());
        }
        if let Ok(mut g) = self.finished_at.lock() {
            *g = None;
        }
        if let Ok(mut g) = self.error.lock() {
            *g = None;
        }
    }

    fn mark_finished(&self, error: Option<String>) {
        self.running.store(false, Ordering::Relaxed);
        if let Ok(mut g) = self.finished_at.lock() {
            *g = Some(now_iso());
        }
        if let Some(msg) = error {
            if let Ok(mut g) = self.error.lock() {
                *g = Some(msg);
            }
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ProgressSnapshot {
    pub project_id: String,
    pub files_total: usize,
    pub files_done: usize,
    pub chunks_done: usize,
    pub bytes_done: usize,
    pub running: bool,
    pub error: Option<String>,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct IndexResult {
    pub project_id: String,
    pub files_indexed: usize,
    pub files_skipped_unchanged: usize,
    pub files_skipped_size: usize,
    pub files_skipped_binary: usize,
    pub files_skipped_extension: usize,
    pub chunks_total: usize,
    pub bytes_total: usize,
    pub truncated: bool,
}

/// Run a full index over a project. Walks `root_path`, chunks each
/// file with `default_chunker`, embeds via `embedder`, persists rows
/// through `replace_chunks_for_file`. Updates `progress` atomically;
/// the caller (FFI thread) reads the snapshot for the UI.
///
/// `event_emitter` is invoked for `code.index.{started,progress,
/// completed,failed}` events. `None` skips emission — useful in
/// tests.
pub fn run_full_index<E, F>(
    conn_factory: F,
    project_id: &str,
    root_path: &Path,
    embedder: &E,
    progress: &Arc<IndexProgress>,
    mut emit: impl FnMut(&str, serde_json::Value),
) -> Result<IndexResult, BtError>
where
    E: Embedder + ?Sized,
    F: Fn() -> Result<Connection, BtError>,
{
    progress.mark_started();
    emit(
        "code.index.started",
        serde_json::json!({ "project_id": project_id, "root_path": root_path.to_string_lossy() }),
    );

    let walk = walk_project(root_path);
    progress.files_total.store(walk.files.len(), Ordering::Relaxed);

    let mut result = IndexResult {
        project_id: project_id.to_string(),
        files_indexed: 0,
        files_skipped_unchanged: 0,
        files_skipped_size: walk.skipped_size,
        files_skipped_binary: walk.skipped_binary,
        files_skipped_extension: walk.skipped_extension,
        chunks_total: 0,
        bytes_total: 0,
        truncated: walk.truncated,
    };

    let chunker = default_chunker();
    let metadata = embedder.metadata();

    let mut last_progress_emit = 0usize;
    let progress_emit_every = 25usize;

    for (i, file) in walk.files.iter().enumerate() {
        match index_one_file(&conn_factory, project_id, file, embedder, &*chunker, &metadata) {
            Ok(FileOutcome::Indexed { chunks, bytes }) => {
                result.files_indexed += 1;
                result.chunks_total += chunks;
                result.bytes_total += bytes;
                progress.files_done.fetch_add(1, Ordering::Relaxed);
                progress.chunks_done.fetch_add(chunks, Ordering::Relaxed);
                progress.bytes_done.fetch_add(bytes, Ordering::Relaxed);
            }
            Ok(FileOutcome::SkippedUnchanged) => {
                result.files_skipped_unchanged += 1;
                progress.files_done.fetch_add(1, Ordering::Relaxed);
            }
            Err(err) => {
                eprintln!(
                    "[code-index] {} at {}: {err}",
                    err.code(),
                    file.repo_path
                );
                progress.files_done.fetch_add(1, Ordering::Relaxed);
            }
        }

        if i >= last_progress_emit + progress_emit_every {
            last_progress_emit = i;
            emit(
                "code.index.progress",
                serde_json::json!({
                    "project_id": project_id,
                    "files_done": progress.files_done.load(Ordering::Relaxed),
                    "files_total": progress.files_total.load(Ordering::Relaxed),
                    "chunks_done": progress.chunks_done.load(Ordering::Relaxed),
                }),
            );
        }
    }

    // Update last_full_index_at + embedding model stamp on the project row.
    if let Ok(conn) = conn_factory() {
        let _ = conn.execute(
            r#"
            UPDATE code_projects SET
                last_full_index_at = datetime('now'),
                embedding_model_id = ?2,
                embedding_model_version = ?3,
                updated_at = datetime('now')
            WHERE project_id = ?1
            "#,
            rusqlite::params![project_id, metadata.model_id, metadata.model_version],
        );
    }

    progress.mark_finished(None);
    emit(
        "code.index.completed",
        serde_json::json!({
            "project_id": project_id,
            "files_indexed": result.files_indexed,
            "chunks_total": result.chunks_total,
            "files_skipped_unchanged": result.files_skipped_unchanged,
            "truncated": result.truncated,
        }),
    );
    Ok(result)
}

enum FileOutcome {
    Indexed { chunks: usize, bytes: usize },
    SkippedUnchanged,
}

fn index_one_file<E: Embedder + ?Sized, F: Fn() -> Result<Connection, BtError>>(
    conn_factory: &F,
    project_id: &str,
    file: &WalkedFile,
    embedder: &E,
    chunker: &dyn Chunker,
    metadata: &EmbeddingModelMetadata,
) -> Result<FileOutcome, BtError> {
    let bytes = fs::read(&file.abs_path)?;
    let source = String::from_utf8_lossy(&bytes).into_owned();
    let sha = store::content_sha256(&source);

    let mut conn = conn_factory()?;
    if let Some(prev) = store::read_file_meta(&conn, project_id, &file.repo_path)? {
        if prev.content_sha256 == sha {
            return Ok(FileOutcome::SkippedUnchanged);
        }
    }

    let chunks: Vec<CodeChunk> = chunker.chunk(&source, file.language);
    if chunks.is_empty() {
        // Still record the file row so we don't re-process unchanged
        // empty files on every run.
        let line_count = source.lines().count() as i64;
        store::replace_chunks_for_file(
            &mut conn,
            project_id,
            &file.repo_path,
            file.language,
            &sha,
            file_mtime_ns(&file.abs_path),
            file.byte_size as i64,
            line_count,
            &[],
            &[],
            metadata,
        )?;
        return Ok(FileOutcome::Indexed { chunks: 0, bytes: file.byte_size as usize });
    }

    let embeddings: Vec<Vec<f32>> = chunks
        .iter()
        .map(|c| embedder.embed(&c.text))
        .collect();
    let line_count = source.lines().count() as i64;
    store::replace_chunks_for_file(
        &mut conn,
        project_id,
        &file.repo_path,
        file.language,
        &sha,
        file_mtime_ns(&file.abs_path),
        file.byte_size as i64,
        line_count,
        &chunks,
        &embeddings,
        metadata,
    )?;
    Ok(FileOutcome::Indexed {
        chunks: chunks.len(),
        bytes: file.byte_size as usize,
    })
}

fn file_mtime_ns(path: &Path) -> i64 {
    fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as i64)
        .unwrap_or(0)
}

fn now_iso() -> String {
    chrono::Utc::now()
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migrations::migrate;
    use crate::notes::embeddings::NoopEmbedder;
    use std::fs as stdfs;

    fn open_test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        migrate(&conn).unwrap();
        conn
    }

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("tado-indexer-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn full_index_writes_chunks_and_skips_unchanged() {
        let project_root = tempdir();
        stdfs::write(project_root.join("main.rs"), "pub fn alpha() {}\n").unwrap();
        stdfs::create_dir_all(project_root.join("src")).unwrap();
        stdfs::write(project_root.join("src/lib.rs"), "pub fn beta() -> i32 { 1 }\n").unwrap();

        // Use a single shared in-memory connection — re-opening a
        // `:memory:` URI gets you a fresh empty DB, which would
        // defeat the test.
        let conn = std::sync::Mutex::new(open_test_db());
        store::register_project(
            &conn.lock().unwrap(),
            "p1",
            "Demo",
            &project_root.to_string_lossy(),
            true,
        )
        .unwrap();

        // Use a real on-disk DB so our factory pattern works.
        let db_path = tempdir().join("idx.sqlite");
        let factory = || -> Result<Connection, BtError> {
            let conn = Connection::open(&db_path)?;
            conn.execute_batch("PRAGMA foreign_keys = ON;")?;
            Ok(conn)
        };
        let setup = factory().unwrap();
        migrate(&setup).unwrap();
        store::register_project(
            &setup,
            "p1",
            "Demo",
            &project_root.to_string_lossy(),
            true,
        )
        .unwrap();
        drop(setup);
        drop(conn);

        let progress = IndexProgress::new("p1".into());
        let embedder = NoopEmbedder;
        let mut events: Vec<(String, serde_json::Value)> = Vec::new();
        let result = run_full_index(
            factory,
            "p1",
            &project_root,
            &embedder,
            &progress,
            |kind, payload| events.push((kind.to_string(), payload)),
        )
        .unwrap();

        assert_eq!(result.files_indexed, 2);
        assert!(result.chunks_total >= 2);
        assert!(events.iter().any(|(k, _)| k == "code.index.started"));
        assert!(events.iter().any(|(k, _)| k == "code.index.completed"));

        // Re-run — every file should be skipped as unchanged.
        let progress2 = IndexProgress::new("p1".into());
        let result2 = run_full_index(
            factory,
            "p1",
            &project_root,
            &embedder,
            &progress2,
            |_, _| {},
        )
        .unwrap();
        assert_eq!(result2.files_skipped_unchanged, 2);
        assert_eq!(result2.files_indexed, 0);
    }
}
