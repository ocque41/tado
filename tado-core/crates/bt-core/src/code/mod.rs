//! Codebase indexing: walk → chunk → embed → store.
//!
//! Phase 2 of Dome's "embed the entire codebase" rollout. Companion
//! tables `code_projects`, `code_files`, `code_chunks`, and
//! `code_index_jobs` were created by migration 22.
//!
//! ## Module layout
//!
//! - [`language`] — extension → `Language` enum, tree-sitter grammar
//!   lookup for the four AST-chunked languages.
//! - [`walker`] — `ignore`-crate-based parallel directory walk with
//!   skip rules (`.gitignore`, hardcoded denylist, binary detection,
//!   size cap).
//! - [`chunker`] — `Chunker` trait. `TreeSitterChunker` handles
//!   Swift/Rust/TS/Python via AST nodes; `LineWindowChunker` handles
//!   every other allowed extension with overlapping line windows.
//! - [`store`] — upsert/replace/purge for `code_files` + `code_chunks`,
//!   in single transactions through the trusted-mutator path.
//! - [`indexer`] — orchestrates the pipeline. `run_job(project_id)`
//!   walks the project root, chunks, embeds, writes; emits
//!   `code.index.{started,progress,completed,failed}` events.

pub mod chunker;
pub mod indexer;
pub mod language;
pub mod search;
pub mod store;
pub mod walker;
pub mod watcher;

pub use chunker::{CodeChunk, Chunker, LineWindowChunker, TreeSitterChunker};
pub use indexer::{run_full_index, IndexProgress, IndexResult};
pub use language::Language;
pub use search::{code_hybrid_search, CodeQuery, CodeSearchHit};
pub use store::{
    purge_project, register_project, replace_chunks_for_file, unregister_project, CodeFileMeta,
    StoredCodeChunk,
};
pub use walker::{walk_project, WalkResult};
pub use watcher::{start_watcher, ProjectWatcher, WatchRegistry};
