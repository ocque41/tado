//! Dome's notes module: chunking, local embeddings, and hybrid (vector +
//! FTS5) search over the same `.bt/index.sqlite` that the rest of
//! bt-core uses.
//!
//! ## Status
//!
//! This is the **v2 scaffolding** phase. What lands here:
//!
//! - [`chunker`] — deterministic, heading-aware markdown chunker.
//! - [`store`] — persist chunks into the `note_chunks` table added by
//!   migration_18. No vector column yet — that lands when the embedder
//!   ships.
//! - [`embeddings`] — public trait + metadata-aware providers. Qwen3 is
//!   the default provider shape; it currently keeps a deterministic
//!   local fallback until the bundled model runtime lands.
//! - [`search`] — hybrid search API. For now the vector path is a
//!   no-op and hits fall back to the existing FTS5 search at doc
//!   granularity. The API shape (`SearchHit`, `hybrid_search`) is
//!   final; swapping in real embeddings only changes the body of
//!   [`search::vector_candidates`].
//!
//! ## Why the split
//!
//! Everything in this module is additive. The existing
//! [`crate::db::search`] keeps working unchanged; the new hybrid path
//! is a separate entry point so callers can migrate deliberately.
//!
//! ## Next phase (not this commit)
//!
//! 1. Pull in the local Qwen3 runtime and model bundle.
//! 2. Replace the deterministic Qwen3 fallback behind the existing
//!    provider trait.
//! 3. Drop a `note_chunks_vec` virtual table via `sqlite-vec` if
//!    brute-force cosine stops being fast enough.

pub mod chunker;
pub mod embeddings;
pub mod model_fetch;
pub mod qwen3_model;
pub mod qwen3_runtime;
pub mod search;
pub mod store;
pub mod tokenizer;

pub use chunker::{chunk_markdown, Chunk};
pub use embeddings::{
    Embedder, EmbeddingModelMetadata, NoopEmbedder, Qwen3EmbeddingProvider,
    DEFAULT_EMBEDDING_DIMENSIONS, EMBEDDING_DIMENSIONS, LEGACY_EMBEDDING_DIMENSIONS,
};
pub use search::{
    freshness_score, hybrid_search, record_retrieval_log, rerank, HybridQuery, RetrievalCtx,
    SearchHit,
};
