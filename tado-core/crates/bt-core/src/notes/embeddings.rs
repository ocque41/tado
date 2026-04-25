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
use std::sync::Arc;

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

    /// Embed a single text. Returns a vector whose length must equal
    /// `metadata().dimension`.
    fn embed(&self, text: &str) -> Vec<f32>;

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

/// Metadata-first Qwen3 provider. This is the production provider shape
/// Dome will keep when the bundled model runtime is added; today it
/// falls back to the deterministic local vectorizer so the rest of the
/// graph/search pipeline can ship and be evaluated without model files.
#[derive(Debug, Clone)]
pub struct Qwen3EmbeddingProvider {
    metadata: EmbeddingModelMetadata,
    model_path: Option<String>,
}

impl Qwen3EmbeddingProvider {
    pub fn new(model_path: Option<String>, dimension: Option<usize>) -> Self {
        let dimension = dimension
            .unwrap_or(DEFAULT_EMBEDDING_DIMENSIONS)
            .clamp(32, 1024);
        let source_hash = model_path
            .as_deref()
            .map(hash_str)
            .unwrap_or_else(|| "bundled-qwen3-embedding-0.6b".to_string());
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
        }
    }

    /// Resolve the configured provider from process environment. The app
    /// can set these before starting Dome; absent values use the bundled
    /// Qwen3 default.
    pub fn from_env() -> Self {
        let model_path = std::env::var("TADO_DOME_EMBEDDING_MODEL_PATH")
            .ok()
            .filter(|value| !value.trim().is_empty());
        let dimension = std::env::var("TADO_DOME_EMBEDDING_DIMENSION")
            .ok()
            .and_then(|value| value.parse::<usize>().ok());
        Self::new(model_path, dimension)
    }

    pub fn model_path(&self) -> Option<&str> {
        self.model_path.as_deref()
    }
}

impl Default for Qwen3EmbeddingProvider {
    fn default() -> Self {
        Self::from_env()
    }
}

impl Embedder for Qwen3EmbeddingProvider {
    fn metadata(&self) -> EmbeddingModelMetadata {
        self.metadata.clone()
    }

    fn embed(&self, text: &str) -> Vec<f32> {
        let mut input = String::with_capacity(self.metadata.instruction.len() + text.len() + 2);
        if !self.metadata.instruction.is_empty() {
            input.push_str(&self.metadata.instruction);
            input.push('\n');
        }
        input.push_str(text);
        deterministic_hash_embedding(&input, self.metadata.dimension)
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
    fn qwen3_provider_uses_configurable_dimensions() {
        let e = Qwen3EmbeddingProvider::new(Some("/models/qwen3".to_string()), Some(768));
        let v = e.embed("hello world");
        assert_eq!(v.len(), 768);
        assert_eq!(e.metadata().model_id, DEFAULT_QWEN3_MODEL_ID);
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
