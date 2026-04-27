//! File-watch driven incremental indexer.
//!
//! Watches each registered project's root via the `notify` crate
//! (FSEvents on macOS). Debounces 500ms — saves typically generate
//! Modify+Modify+CreateOnRename storms that we collapse into one
//! reindex per path.
//!
//! ## Per-watcher lifecycle
//!
//! `WatchManager::start(project_id, root)` spawns a debouncer + a
//! background thread. The thread receives `Event` batches and:
//!
//! 1. Filters paths under the project root.
//! 2. Maps each path to the project's repo-relative form.
//! 3. Reads + chunks + embeds + persists via the existing
//!    `replace_chunks_for_file` (same code path Phase 2's full index
//!    uses; consistency by construction).
//! 4. Updates the per-project `IndexProgress` so the UI badge
//!    reflects activity even during incremental updates.
//!
//! ## Why not Tokio
//!
//! `notify` runs its own OS-level thread; consuming events from
//! a dedicated `std::thread` keeps the path simple and matches the
//! existing trusted-mutator discipline (a single SQLite writer
//! serialized through the connection factory).

use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::{channel, Receiver, Sender},
    Arc, Mutex,
};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode};
use notify_debouncer_mini::{new_debouncer, DebouncedEvent, DebouncedEventKind, Debouncer};
use rusqlite::Connection;

use crate::code::chunker::{default_chunker, Chunker};
use crate::code::indexer::IndexProgress;
use crate::code::language::Language;
use crate::code::store;
use crate::code::walker::{HARD_SKIP_DIRS, MAX_FILE_BYTES};
use crate::error::BtError;
use crate::notes::embeddings::{Embedder, EmbeddingModelMetadata};

/// Debounce window. 500ms is comfortable for "save in editor" bursts
/// without making the user feel like the index is laggy.
const DEBOUNCE_WINDOW: Duration = Duration::from_millis(500);

/// One running watcher. Drop the handle to stop; the spawned thread
/// observes `stop_flag` and exits cleanly.
pub struct ProjectWatcher {
    project_id: String,
    stop_flag: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
    /// We hold the debouncer so its `RecommendedWatcher` keeps the
    /// FSEvents stream alive. Dropping it releases the kernel
    /// resource.
    _debouncer: Debouncer<RecommendedWatcher>,
}

impl ProjectWatcher {
    pub fn project_id(&self) -> &str {
        &self.project_id
    }

    pub fn stop(mut self) {
        self.stop_flag.store(true, Ordering::Relaxed);
        // Take the join handle out so we can wait for the worker.
        // The debouncer is dropped automatically when `self` goes
        // out of scope at the end of this method, which closes the
        // event channel and lets the worker observe the disconnect.
        let handle = self.join.take();
        if let Some(handle) = handle {
            let _ = handle.join();
        }
    }
}

impl Drop for ProjectWatcher {
    fn drop(&mut self) {
        self.stop_flag.store(true, Ordering::Relaxed);
    }
}

/// Spawn a watcher rooted at `root_path`. Returns a handle the caller
/// stores in their watcher map; dropping (or `stop()`-ing) the
/// handle tears the watcher down. The provided `embedder_factory`
/// produces a fresh `Box<dyn Embedder>` for each event batch — the
/// runtime is global (`embeddings::install_runtime`) so the box just
/// wraps the shared handle.
pub fn start_watcher<F, EF>(
    project_id: String,
    root_path: PathBuf,
    progress: Arc<IndexProgress>,
    conn_factory: F,
    embedder_factory: EF,
) -> Result<ProjectWatcher, BtError>
where
    F: Fn() -> Result<Connection, BtError> + Send + Sync + 'static,
    EF: Fn() -> Box<dyn Embedder + Send + Sync> + Send + Sync + 'static,
{
    if !root_path.is_dir() {
        return Err(BtError::Validation(format!(
            "watch root is not a directory: {}",
            root_path.display()
        )));
    }

    // FSEvents on macOS reports paths under their canonical mount
    // (e.g. /private/tmp/foo even if you watched /tmp/foo). If we
    // store the original root, every `strip_prefix` lookup fails.
    // Canonicalize once on entry so all path math happens in the
    // same coordinate system.
    let root_path = std::fs::canonicalize(&root_path).unwrap_or(root_path);

    let (tx, rx): (Sender<Vec<DebouncedEvent>>, Receiver<Vec<DebouncedEvent>>) = channel();

    let mut debouncer = new_debouncer(DEBOUNCE_WINDOW, move |result| {
        if let Ok(events) = result {
            let _ = tx.send(events);
        }
    })
    .map_err(|e| BtError::Internal(format!("debouncer init: {e}")))?;

    debouncer
        .watcher()
        .watch(&root_path, RecursiveMode::Recursive)
        .map_err(|e| BtError::Internal(format!("watcher start: {e}")))?;

    let stop_flag = Arc::new(AtomicBool::new(false));
    let stop_flag_thread = stop_flag.clone();
    let project_id_thread = project_id.clone();
    let root_thread = root_path.clone();
    let progress_thread = progress;
    let conn_factory = Arc::new(conn_factory);
    let embedder_factory = Arc::new(embedder_factory);

    let join = thread::Builder::new()
        .name(format!("dome-watcher-{project_id}"))
        .spawn(move || {
            run_watcher_loop(
                project_id_thread,
                root_thread,
                progress_thread,
                stop_flag_thread,
                conn_factory,
                embedder_factory,
                rx,
            );
        })
        .map_err(|e| BtError::Internal(format!("watcher thread spawn: {e}")))?;

    Ok(ProjectWatcher {
        project_id,
        stop_flag,
        join: Some(join),
        _debouncer: debouncer,
    })
}

fn run_watcher_loop<F, EF>(
    project_id: String,
    root_path: PathBuf,
    progress: Arc<IndexProgress>,
    stop_flag: Arc<AtomicBool>,
    conn_factory: Arc<F>,
    embedder_factory: Arc<EF>,
    rx: Receiver<Vec<DebouncedEvent>>,
) where
    F: Fn() -> Result<Connection, BtError> + Send + Sync + 'static,
    EF: Fn() -> Box<dyn Embedder + Send + Sync> + Send + Sync + 'static,
{
    let chunker: Box<dyn Chunker + Send + Sync> = default_chunker();
    while !stop_flag.load(Ordering::Relaxed) {
        let batch = match rx.recv_timeout(Duration::from_millis(250)) {
            Ok(b) => b,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
        };
        for event in batch {
            if !matches!(event.kind, DebouncedEventKind::Any | DebouncedEventKind::AnyContinuous) {
                continue;
            }
            let path = event.path;
            // catch_unwind so a single malformed file (panicking
            // chunker / pathological tree-sitter parse) doesn't kill
            // the entire watcher thread. We log + move on to the
            // next path; the next save attempt re-tries.
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                handle_path_event(
                    &project_id,
                    &root_path,
                    &path,
                    &progress,
                    chunker.as_ref(),
                    conn_factory.as_ref(),
                    embedder_factory.as_ref(),
                )
            }));
            match result {
                Ok(Ok(())) => {}
                Ok(Err(err)) => {
                    eprintln!(
                        "[dome-watcher] {} {}: {err}",
                        project_id,
                        path.display()
                    );
                }
                Err(panic_payload) => {
                    let msg = panic_payload
                        .downcast_ref::<&'static str>()
                        .map(|s| (*s).to_string())
                        .or_else(|| panic_payload.downcast_ref::<String>().cloned())
                        .unwrap_or_else(|| "<non-string panic>".to_string());
                    eprintln!(
                        "[dome-watcher] {} {} PANIC: {msg}",
                        project_id,
                        path.display()
                    );
                }
            }
        }
    }
}

fn handle_path_event<F, EF>(
    project_id: &str,
    root: &Path,
    path: &Path,
    progress: &Arc<IndexProgress>,
    chunker: &(dyn Chunker + Send + Sync),
    conn_factory: &F,
    embedder_factory: &EF,
) -> Result<(), BtError>
where
    F: Fn() -> Result<Connection, BtError>,
    EF: Fn() -> Box<dyn Embedder + Send + Sync>,
{
    if !path_under_root(root, path) {
        return Ok(());
    }
    if path_in_skip_dir(root, path) {
        return Ok(());
    }
    let repo_path = match path.strip_prefix(root) {
        Ok(p) => p.to_string_lossy().replace('\\', "/"),
        Err(_) => return Ok(()),
    };

    // Deletion: file is gone. Drop chunk rows for the path.
    if !path.exists() {
        let conn = conn_factory()?;
        conn.execute(
            "DELETE FROM code_chunks WHERE project_id = ?1 AND repo_path = ?2",
            rusqlite::params![project_id, repo_path],
        )?;
        conn.execute(
            "DELETE FROM code_files WHERE project_id = ?1 AND repo_path = ?2",
            rusqlite::params![project_id, repo_path],
        )?;
        conn.execute(
            "DELETE FROM fts_code WHERE project_id = ?1 AND repo_path = ?2",
            rusqlite::params![project_id, repo_path],
        )
        .ok();
        return Ok(());
    }

    if !path.is_file() {
        return Ok(());
    }

    let metadata = std::fs::metadata(path)?;
    if metadata.len() > MAX_FILE_BYTES {
        return Ok(());
    }
    let Some(language) = Language::from_path(path) else {
        return Ok(());
    };

    let bytes = std::fs::read(path)?;
    let source = String::from_utf8_lossy(&bytes).into_owned();
    let sha = store::content_sha256(&source);

    let mut conn = conn_factory()?;
    if let Some(prev) = store::read_file_meta(&conn, project_id, &repo_path)? {
        if prev.content_sha256 == sha {
            return Ok(()); // no-op: identical content
        }
    }

    let chunks = chunker.chunk(&source, language);
    let embedder = embedder_factory();
    let model_meta: EmbeddingModelMetadata = embedder.metadata();

    let embeddings: Vec<Vec<f32>> = chunks.iter().map(|c| embedder.embed(&c.text)).collect();
    let line_count = source.lines().count() as i64;
    let mtime_ns = metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as i64)
        .unwrap_or(0);
    store::replace_chunks_for_file(
        &mut conn,
        project_id,
        &repo_path,
        language,
        &sha,
        mtime_ns,
        metadata.len() as i64,
        line_count,
        &chunks,
        &embeddings,
        &model_meta,
    )?;

    progress.files_done.fetch_add(1, Ordering::Relaxed);
    progress
        .chunks_done
        .fetch_add(chunks.len(), Ordering::Relaxed);
    progress
        .bytes_done
        .fetch_add(metadata.len() as usize, Ordering::Relaxed);
    Ok(())
}

fn path_under_root(root: &Path, path: &Path) -> bool {
    let canonical_root = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    let canonical_path = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    canonical_path.starts_with(canonical_root) || path.starts_with(root)
}

fn path_in_skip_dir(root: &Path, path: &Path) -> bool {
    let Ok(rel) = path.strip_prefix(root) else {
        return false;
    };
    rel.components().any(|c| {
        c.as_os_str()
            .to_str()
            .map(|s| HARD_SKIP_DIRS.contains(&s))
            .unwrap_or(false)
    })
}

/// Process-wide registry of running watchers, keyed by project_id.
/// Lives on `CoreService` so RPC handlers can start/stop without
/// threading the manager through every call site.
#[derive(Default)]
pub struct WatchRegistry {
    inner: Mutex<std::collections::HashMap<String, ProjectWatcher>>,
}

impl std::fmt::Debug for WatchRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WatchRegistry")
            .field("watchers", &self.list())
            .finish()
    }
}

impl WatchRegistry {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn is_watching(&self, project_id: &str) -> bool {
        self.inner
            .lock()
            .map(|g| g.contains_key(project_id))
            .unwrap_or(false)
    }

    pub fn list(&self) -> Vec<String> {
        self.inner
            .lock()
            .map(|g| g.keys().cloned().collect())
            .unwrap_or_default()
    }

    pub fn install(&self, watcher: ProjectWatcher) {
        if let Ok(mut g) = self.inner.lock() {
            // Replace any existing watcher for this project.
            if let Some(old) = g.remove(watcher.project_id()) {
                old.stop();
            }
            g.insert(watcher.project_id().to_string(), watcher);
        }
    }

    pub fn stop(&self, project_id: &str) -> bool {
        if let Ok(mut g) = self.inner.lock() {
            if let Some(w) = g.remove(project_id) {
                w.stop();
                return true;
            }
        }
        false
    }

    pub fn stop_all(&self) {
        if let Ok(mut g) = self.inner.lock() {
            for (_, w) in g.drain() {
                w.stop();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migrations::migrate;
    use crate::notes::embeddings::NoopEmbedder;
    use std::fs;
    use std::time::Instant;

    fn tempdir() -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("tado-watcher-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn watcher_picks_up_new_file_and_indexes() {
        let project_root = tempdir();
        let db_path = tempdir().join("idx.sqlite");

        let factory = {
            let db_path = db_path.clone();
            move || -> Result<Connection, BtError> {
                let conn = Connection::open(&db_path)?;
                conn.execute_batch("PRAGMA foreign_keys = ON;")?;
                Ok(conn)
            }
        };
        {
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
        }
        let progress = IndexProgress::new("p1".into());
        let watcher = start_watcher(
            "p1".into(),
            project_root.clone(),
            progress.clone(),
            factory,
            || Box::new(NoopEmbedder) as Box<dyn Embedder + Send + Sync>,
        )
        .expect("watcher start");

        // Give FSEvents a moment to register the watch before we
        // create files. Without this small pause the initial create
        // can race the watcher boot on macOS.
        std::thread::sleep(Duration::from_millis(200));

        fs::write(project_root.join("alpha.rs"), "pub fn alpha() {}\n").unwrap();
        fs::write(project_root.join("beta.rs"), "pub fn beta() -> i32 { 1 }\n").unwrap();

        // Wait up to 5s for the debouncer to fire and the indexer to
        // persist rows.
        let deadline = Instant::now() + Duration::from_secs(5);
        let conn = Connection::open(&db_path).unwrap();
        loop {
            let count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM code_files WHERE project_id='p1'",
                    [],
                    |r| r.get(0),
                )
                .unwrap();
            if count >= 2 {
                break;
            }
            if Instant::now() > deadline {
                panic!("watcher did not pick up new files in time (count={count})");
            }
            std::thread::sleep(Duration::from_millis(100));
        }

        // Cleanup
        watcher.stop();
        let _ = std::fs::remove_dir_all(&project_root);
        let _ = std::fs::remove_file(&db_path);
    }
}
