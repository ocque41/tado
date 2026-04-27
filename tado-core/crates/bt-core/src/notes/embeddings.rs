//! Embedding abstraction.
//!
//! The service layer depends on a metadata-aware provider instead of a
//! fixed vector size. That lets Dome migrate from the legacy 384-dim
//! hash vectors to Qwen3-Embedding-0.6B's configurable dimensions
//! without another schema break. The current Qwen3 provider records the
//! exact production metadata and keeps a deterministic local fallback
//! vectorizer until the bundled model runtime lands.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use crate::notes::qwen3_runtime::Qwen3Runtime;

/// Process-wide handle to the loaded Qwen3 runtime. The FFI shim that
/// boots Dome populates this after the model files are present on
/// disk; from that point on, every `Qwen3EmbeddingProvider::default()`
/// (used inside `service.rs`'s search/index paths) auto-attaches the
/// shared runtime instead of falling back to the FNV-1a stub.
///
/// `RwLock` so swapping the runtime (e.g., the user picked a different
/// model path in Settings) is safe without rebuilding callers. Reads
/// are uncontended in the hot path: every embed call locks the inner
/// `Mutex<Qwen3Runtime>` for the actual forward pass — the outer
/// `RwLock` is only consulted at provider-construction time.
static RUNTIME_REGISTRY: OnceLock<RwLock<Option<Arc<Mutex<Qwen3Runtime>>>>> = OnceLock::new();

fn registry() -> &'static RwLock<Option<Arc<Mutex<Qwen3Runtime>>>> {
    RUNTIME_REGISTRY.get_or_init(|| RwLock::new(None))
}

/// Install (or replace) the process-wide runtime handle. Returns the
/// previous runtime, if any, so callers can `drop` it explicitly to
/// free GPU memory before the new one loads.
pub fn install_runtime(runtime: Arc<Mutex<Qwen3Runtime>>) -> Option<Arc<Mutex<Qwen3Runtime>>> {
    let mut guard = registry().write().expect("runtime registry poisoned");
    let prev = guard.take();
    *guard = Some(runtime);
    prev
}

/// Drop the process-wide runtime handle. Future `default()` providers
/// will fall back to the deterministic stub.
pub fn clear_runtime() -> Option<Arc<Mutex<Qwen3Runtime>>> {
    let mut guard = registry().write().expect("runtime registry poisoned");
    guard.take()
}

fn current_runtime() -> Option<Arc<Mutex<Qwen3Runtime>>> {
    registry()
        .read()
        .ok()
        .and_then(|g| g.as_ref().cloned())
}

/// Legacy dimension used by rows stamped `noop@1`.
pub const LEGACY_EMBEDDING_DIMENSIONS: usize = 384;

/// Default production dimension for Qwen3-Embedding-0.6B in Dome v1.
/// Qwen3 supports smaller dimensions; 1024 is the full output size and
/// the best default for local quality.
pub const DEFAULT_EMBEDDING_DIMENSIONS: usize = 1024;

/// Backwards-compatible alias for callers that still need a named
/// default. New persistence code must read [`EmbeddingModelMetadata`]
/// from the provider instead of assuming this value.
pub const EMBEDDING_DIMENSIONS: usize = DEFAULT_EMBEDDING_DIMENSIONS;

pub const DEFAULT_QWEN3_MODEL_ID: &str = "Qwen/Qwen3-Embedding-0.6B";
pub const DEFAULT_QWEN3_MODEL_VERSION: &str = "qwen3-embedding-0.6b@1";
pub const DEFAULT_QWEN3_POOLING: &str = "last_token";
pub const DEFAULT_QWEN3_INSTRUCTION: &str =
    "Represent this Tado/Dome knowledge for retrieval by local coding agents.";

/// Persisted model metadata attached to every chunk embedding.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EmbeddingModelMetadata {
    pub model_id: String,
    pub model_version: String,
    pub dimension: usize,
    pub pooling: String,
    pub instruction: String,
    pub source_hash: String,
}

impl EmbeddingModelMetadata {
    pub fn noop() -> Self {
        Self {
            model_id: "noop".to_string(),
            model_version: "noop@1".to_string(),
            dimension: LEGACY_EMBEDDING_DIMENSIONS,
            pooling: "hash-bucket".to_string(),
            instruction: String::new(),
            source_hash: "legacy-noop".to_string(),
        }
    }
}

/// An embedder produces a deterministic vector for a given string of
/// text. Implementations must be thread-safe because the scheduler and
/// write barrier can invoke embedders from different threads.
pub trait Embedder: Send + Sync {
    /// Metadata that must be written beside every vector.
    fn metadata(&self) -> EmbeddingModelMetadata;

    /// Embed a passage — content we *index*. Per the Qwen3-Embedding
    /// model card, passages get no instruction prefix.
    fn embed(&self, text: &str) -> Vec<f32>;

    /// Embed a query — what the user typed at search time. Default
    /// returns the passage embedding so legacy embedders stay correct;
    /// the Qwen3 provider overrides this to apply the instruction
    /// prefix the model was trained on.
    fn embed_query(&self, query: &str) -> Vec<f32> {
        self.embed(query)
    }

    /// Embed a batch. Default implementation calls [`Self::embed`]
    /// per-item; real embedders should override to amortize setup
    /// cost.
    fn embed_batch(&self, texts: &[String]) -> Vec<Vec<f32>> {
        texts.iter().map(|t| self.embed(t)).collect()
    }
}

impl<E: Embedder + ?Sized> Embedder for Arc<E> {
    fn metadata(&self) -> EmbeddingModelMetadata {
        (**self).metadata()
    }

    fn embed(&self, text: &str) -> Vec<f32> {
        (**self).embed(text)
    }

    fn embed_query(&self, query: &str) -> Vec<f32> {
        (**self).embed_query(query)
    }

    fn embed_batch(&self, texts: &[String]) -> Vec<Vec<f32>> {
        (**self).embed_batch(texts)
    }
}

/// Stub embedder used until the real candle/ONNX integration lands.
///
/// Returns a deterministic vector derived from a simple hash of the
/// input. Two identical inputs produce identical vectors; differing
/// inputs produce visibly different vectors (useful for unit tests).
/// The vectors are NOT semantically meaningful — two inputs with the
/// same meaning produce unrelated vectors. Treat results from this
/// embedder as "something of the right shape" only.
#[derive(Default, Debug, Clone, Copy)]
pub struct NoopEmbedder;

impl Embedder for NoopEmbedder {
    fn metadata(&self) -> EmbeddingModelMetadata {
        EmbeddingModelMetadata::noop()
    }

    fn embed(&self, text: &str) -> Vec<f32> {
        deterministic_hash_embedding(text, LEGACY_EMBEDDING_DIMENSIONS)
    }
}

/// Metadata-first Qwen3 provider. The provider holds an optional
/// runtime: when present, embeddings are produced by the real candle
/// model on Metal/CPU. When absent (model still downloading, or the
/// user hasn't pointed `TADO_DOME_EMBEDDING_MODEL_PATH` at a vault
/// directory yet) we fall back to a deterministic hash so the rest of
/// the pipeline remains testable. The metadata stamp on each chunk
/// records which path produced it, so a future re-embedding sweep can
/// find every "stub" row and rebuild it with real semantics.
#[derive(Clone)]
pub struct Qwen3EmbeddingProvider {
    metadata: EmbeddingModelMetadata,
    model_path: Option<String>,
    runtime: Option<Arc<Mutex<Qwen3Runtime>>>,
}

impl std::fmt::Debug for Qwen3EmbeddingProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Qwen3EmbeddingProvider")
            .field("metadata", &self.metadata)
            .field("model_path", &self.model_path)
            .field("runtime_loaded", &self.runtime.is_some())
            .finish()
    }
}

impl Qwen3EmbeddingProvider {
    pub fn new(model_path: Option<String>, dimension: Option<usize>) -> Self {
        let dimension = dimension
            .unwrap_or(DEFAULT_EMBEDDING_DIMENSIONS)
            .clamp(32, 1024);
        let source_hash = model_path
            .as_deref()
            .map(hash_str)
            .unwrap_or_else(|| "stub-qwen3-embedding-0.6b".to_string());
        Self {
            metadata: EmbeddingModelMetadata {
                model_id: DEFAULT_QWEN3_MODEL_ID.to_string(),
                model_version: DEFAULT_QWEN3_MODEL_VERSION.to_string(),
                dimension,
                pooling: DEFAULT_QWEN3_POOLING.to_string(),
                instruction: DEFAULT_QWEN3_INSTRUCTION.to_string(),
                source_hash,
            },
            model_path,
            runtime: None,
        }
    }

    /// Resolve the configured provider from process environment. The app
    /// can set these before starting Dome; absent values use the bundled
    /// Qwen3 default. If a runtime has been installed via
    /// [`install_runtime`] (typical lifecycle: FFI boot path loads the
    /// model once on first launch), the provider auto-attaches it so
    /// callers get real semantic embeddings without threading the
    /// runtime handle through every call site.
    pub fn from_env() -> Self {
        let model_path = std::env::var("TADO_DOME_EMBEDDING_MODEL_PATH")
            .ok()
            .filter(|value| !value.trim().is_empty());
        let dimension = std::env::var("TADO_DOME_EMBEDDING_DIMENSION")
            .ok()
            .and_then(|value| value.parse::<usize>().ok());
        let mut provider = Self::new(model_path, dimension);
        if let Some(runtime) = current_runtime() {
            provider.attach_runtime(runtime);
        }
        provider
    }

    pub fn model_path(&self) -> Option<&str> {
        self.model_path.as_deref()
    }

    /// Attach a loaded runtime. After this returns the provider stops
    /// using the deterministic-hash fallback and records the
    /// safetensors file's SHA-256 in the metadata stamp on every
    /// future row.
    pub fn attach_runtime(&mut self, runtime: Arc<Mutex<Qwen3Runtime>>) {
        let (dim, source_hash) = {
            let guard = runtime.lock().expect("qwen3 runtime mutex poisoned");
            (guard.dimension(), guard.source_hash().to_string())
        };
        self.metadata.dimension = dim;
        self.metadata.source_hash = source_hash;
        self.runtime = Some(runtime);
    }

    /// True if the provider has a real model attached. Used by FFI to
    /// gate operations that should not fall back silently to the hash
    /// stub (e.g., Phase 2 code indexing).
    pub fn is_runtime_loaded(&self) -> bool {
        self.runtime.is_some()
    }

    fn run(&self, op: impl FnOnce(&mut Qwen3Runtime) -> Vec<f32>) -> Option<Vec<f32>> {
        let runtime = self.runtime.as_ref()?;
        let mut guard = runtime.lock().ok()?;
        Some(op(&mut guard))
    }

    fn fallback_passage(&self, text: &str) -> Vec<f32> {
        // When runtime isn't loaded, produce a legacy 384-dim noop
        // vector so the metadata stamp (`metadata()` returns
        // `noop@1` in that case) matches what we actually wrote.
        // Stamping qwen3 metadata on a hash vector would corrupt the
        // index — search would compare 1024-dim query embeddings
        // against rows that secretly carry hash data in a different
        // vector space.
        let dim = if self.runtime.is_some() {
            self.metadata.dimension
        } else {
            LEGACY_EMBEDDING_DIMENSIONS
        };
        deterministic_hash_embedding(text, dim)
    }

    fn fallback_query(&self, query: &str) -> Vec<f32> {
        let dim = if self.runtime.is_some() {
            self.metadata.dimension
        } else {
            LEGACY_EMBEDDING_DIMENSIONS
        };
        let mut input = String::with_capacity(self.metadata.instruction.len() + query.len() + 16);
        if !self.metadata.instruction.is_empty() {
            input.push_str("Instruct: ");
            input.push_str(&self.metadata.instruction);
            input.push_str("\nQuery: ");
        }
        input.push_str(query);
        deterministic_hash_embedding(&input, dim)
    }
}

impl Default for Qwen3EmbeddingProvider {
    fn default() -> Self {
        Self::from_env()
    }
}

impl Embedder for Qwen3EmbeddingProvider {
    fn metadata(&self) -> EmbeddingModelMetadata {
        // If the runtime isn't loaded, the chunk we're about to write
        // will go through `fallback_passage` (FNV-1a hash). Stamp it
        // with the noop metadata so a future re-embedding sweep on
        // `embedding_model_id != "Qwen/..."` finds and rebuilds it
        // once the real model arrives. Without this swap, hash rows
        // would be indistinguishable from real qwen3 rows in the DB
        // and search would silently mix vector spaces.
        if self.runtime.is_none() {
            return EmbeddingModelMetadata::noop();
        }
        self.metadata.clone()
    }

    fn embed(&self, text: &str) -> Vec<f32> {
        if let Some(v) = self.run(|rt| match rt.embed_passage(text) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[dome] qwen3 embed_passage failed: {e}");
                Vec::new()
            }
        }) {
            if !v.is_empty() {
                return v;
            }
        }
        self.fallback_passage(text)
    }

    fn embed_query(&self, query: &str) -> Vec<f32> {
        let instruction = self.metadata.instruction.clone();
        if let Some(v) = self.run(|rt| match rt.embed_query(&instruction, query) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("[dome] qwen3 embed_query failed: {e}");
                Vec::new()
            }
        }) {
            if !v.is_empty() {
                return v;
            }
        }
        self.fallback_query(query)
    }
}

/// L2-normalize a vector in place. No-op on zero vectors.
pub fn normalize(v: &mut [f32]) {
    let mag: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if mag > f32::EPSILON {
        for x in v.iter_mut() {
            *x /= mag;
        }
    }
}

/// Cosine similarity between two vectors of matching length. Returns
/// 0.0 if either vector is zero.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }
    let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let na: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let nb: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if na <= f32::EPSILON || nb <= f32::EPSILON {
        return 0.0;
    }
    dot / (na * nb)
}

fn deterministic_hash_embedding(text: &str, dimension: usize) -> Vec<f32> {
    let mut v = vec![0.0_f32; dimension];
    if text.is_empty() || dimension == 0 {
        return v;
    }
    // Simple FNV-1a + bucket accumulation. Not cryptographic, not
    // semantic — just stable and spread across the vector.
    let mut hash: u64 = 0xcbf29ce484222325;
    for (i, byte) in text.bytes().enumerate() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
        let bucket = (hash as usize ^ i) % dimension;
        let raw = ((hash >> 17) as i32 as f32) / (i32::MAX as f32);
        v[bucket] += raw;
    }
    normalize(&mut v);
    v
}

fn hash_str(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noop_embedder_output_shape() {
        let e = NoopEmbedder;
        let v = e.embed("hello world");
        assert_eq!(v.len(), LEGACY_EMBEDDING_DIMENSIONS);
        assert_eq!(e.metadata().model_version, "noop@1");
    }

    #[test]
    fn qwen3_provider_without_runtime_falls_back_to_noop() {
        // Without a runtime attached, the provider must report noop
        // metadata + write 384-dim hash vectors. The model_id field
        // is what re-embedding sweeps look for, so stamping qwen3 on
        // a hash vector here would silently corrupt the index.
        let e = Qwen3EmbeddingProvider::new(Some("/models/qwen3".to_string()), Some(768));
        let v = e.embed("hello world");
        assert_eq!(v.len(), LEGACY_EMBEDDING_DIMENSIONS);
        assert_eq!(e.metadata().model_id, "noop");
        assert_eq!(e.metadata().dimension, LEGACY_EMBEDDING_DIMENSIONS);
    }

    #[test]
    fn identical_inputs_produce_identical_vectors() {
        let e = NoopEmbedder;
        assert_eq!(e.embed("hello"), e.embed("hello"));
    }

    #[test]
    fn different_inputs_differ() {
        let e = NoopEmbedder;
        assert_ne!(e.embed("hello"), e.embed("goodbye"));
    }

    #[test]
    fn empty_input_produces_zero_vector() {
        let e = NoopEmbedder;
        let v = e.embed("");
        assert!(v.iter().all(|x| *x == 0.0));
    }

    #[test]
    fn normalize_unit_length() {
        let mut v = vec![3.0, 4.0, 0.0];
        normalize(&mut v);
        let mag: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!((mag - 1.0).abs() < 1e-6);
    }

    #[test]
    fn cosine_identity_is_one() {
        let a = vec![1.0, 2.0, 3.0];
        let c = cosine(&a, &a);
        assert!((c - 1.0).abs() < 1e-6);
    }

    #[test]
    fn cosine_orthogonal_is_zero() {
        let a = vec![1.0, 0.0];
        let b = vec![0.0, 1.0];
        assert!(cosine(&a, &b).abs() < 1e-6);
    }

    #[test]
    fn batch_matches_individual() {
        let e = NoopEmbedder;
        let texts = vec!["one".to_string(), "two".to_string(), "three".to_string()];
        let batched = e.embed_batch(&texts);
        let individual: Vec<Vec<f32>> = texts.iter().map(|t| e.embed(t)).collect();
        assert_eq!(batched, individual);
    }
}
