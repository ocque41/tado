//! Qwen3-Embedding-0.6B inference in pure Rust via candle.
//!
//! Loads the safetensors F16 weights from `<vault>/.bt/models/
//! qwen3-embedding-0.6b/`, runs forward on Apple Metal when available
//! (CPU fallback for non-mac dev hosts), pulls the last hidden state
//! at the EOS token, L2-normalizes, and truncates to the configured
//! dimension.
//!
//! ## Threading
//!
//! `Qwen3Model::forward` takes `&mut self` because the candle
//! `ConcatKvCache` is interior to each layer. We therefore wrap the
//! whole runtime in `Mutex` upstream — see
//! [`super::embeddings::Qwen3EmbeddingProvider`].
//!
//! ## Why F16 safetensors instead of GGUF Q4_K_M
//!
//! The `candle_transformers::models::qwen3::Model` (non-quantized)
//! exposes the *hidden state* as its forward output. The quantized
//! sibling bakes `lm_head` into forward, which is wrong for an
//! embedding model. Using F16 safetensors (~1.2 GB) keeps the model
//! code path identical to upstream candle and gives us correct
//! pre-`lm_head` activations without forking the crate.

use std::path::{Path, PathBuf};

use candle_core::{DType, Device, Tensor};
use candle_nn::VarBuilder;
use sha2::{Digest, Sha256};

use crate::error::BtError;
use crate::notes::qwen3_model as qwen3;
use crate::notes::tokenizer::{Encoded, Qwen3Tokenizer};

/// Default dimension we slice the model output down to. Matches the
/// existing schema (1024). Smaller values are valid (32..=1024) and
/// the caller can plumb them through; out of range falls back to 1024.
pub const DEFAULT_DIM: usize = 1024;

/// What we record on each row of `note_chunks` so future `mismatched
/// model` sweeps know what to re-embed. The string is "<algo>:<hex>"
/// where the hex is the SHA-256 of the safetensors file we loaded.
pub fn compute_source_hash(model_path: &Path) -> Result<String, BtError> {
    let mut hasher = Sha256::new();
    let mut f = std::fs::File::open(model_path)
        .map_err(|e| BtError::Internal(format!("open weights: {e}")))?;
    let mut buf = [0u8; 64 * 1024];
    use std::io::Read;
    loop {
        let n = f
            .read(&mut buf)
            .map_err(|e| BtError::Internal(format!("read weights: {e}")))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(format!("sha256:{:x}", hasher.finalize()))
}

#[derive(Debug)]
pub struct Qwen3Runtime {
    model: qwen3::Model,
    tokenizer: Qwen3Tokenizer,
    device: Device,
    #[allow(dead_code)] // surfaced via Debug + future inspection FFI
    dtype: DType,
    target_dim: usize,
    hidden_size: usize,
    source_hash: String,
}

impl Qwen3Runtime {
    /// Load the model from a directory containing `config.json`,
    /// `tokenizer.json`, and `model.safetensors`. Picks the Metal
    /// device on macOS and falls back to CPU otherwise.
    pub fn load(model_dir: &Path, target_dim: usize) -> Result<Self, BtError> {
        let target_dim = target_dim.clamp(32, DEFAULT_DIM);
        let config_path = model_dir.join("config.json");
        let weights_path = model_dir.join("model.safetensors");
        let tokenizer_path = model_dir.join("tokenizer.json");

        let cfg_raw = std::fs::read_to_string(&config_path)
            .map_err(|e| BtError::Internal(format!("read config.json: {e}")))?;
        let cfg: qwen3::Config = serde_json::from_str(&cfg_raw)
            .map_err(|e| BtError::Internal(format!("parse config.json: {e}")))?;

        let device = pick_device();
        let dtype = pick_dtype(&device);

        // Memory-mapped safetensors load. ~1.2 GB on disk for F16,
        // memory cost stays low because candle keeps tensors lazy.
        let vb = unsafe {
            VarBuilder::from_mmaped_safetensors(&[&weights_path], dtype, &device)
                .map_err(|e| BtError::Internal(format!("mmap weights: {e}")))?
        };
        let model = qwen3::Model::new(&cfg, vb)
            .map_err(|e| BtError::Internal(format!("build qwen3 model: {e}")))?;
        let tokenizer = Qwen3Tokenizer::load(&tokenizer_path)?;
        let source_hash = compute_source_hash(&weights_path)?;

        Ok(Self {
            model,
            tokenizer,
            device,
            dtype,
            target_dim,
            hidden_size: cfg.hidden_size,
            source_hash,
        })
    }

    pub fn dimension(&self) -> usize {
        self.target_dim
    }

    pub fn hidden_size(&self) -> usize {
        self.hidden_size
    }

    pub fn source_hash(&self) -> &str {
        &self.source_hash
    }

    /// Embed a passage (indexed content). No instruction prefix —
    /// passages are stored "raw" per the Qwen3-Embedding model card.
    pub fn embed_passage(&mut self, content: &str) -> Result<Vec<f32>, BtError> {
        let encoded = self.tokenizer.encode_passage(content)?;
        self.run_forward(&encoded)
    }

    /// Embed a query with an instruction prefix. Use this for the
    /// query side of search; the cosine vs `embed_passage` is what
    /// gets ranked.
    pub fn embed_query(&mut self, instruction: &str, query: &str) -> Result<Vec<f32>, BtError> {
        let encoded = self.tokenizer.encode_query(instruction, query)?;
        self.run_forward(&encoded)
    }

    fn run_forward(&mut self, encoded: &Encoded) -> Result<Vec<f32>, BtError> {
        if encoded.ids.is_empty() {
            return Ok(vec![0.0_f32; self.target_dim]);
        }

        // batch=1 path. Multi-batch needs a padding-aware mask which
        // candle's qwen3 forward doesn't accept out of the box; the
        // single-input throughput is enough for v1 (Phase 4 incremental
        // updates dominate over full rebuilds).
        let input = Tensor::from_slice(
            &encoded.ids,
            (1, encoded.real_len),
            &self.device,
        )
        .map_err(|e| BtError::Internal(format!("input tensor: {e}")))?;

        // Each call is a fresh sequence; clear state from the prior
        // embedding so KV cache doesn't leak across inputs.
        self.model.clear_kv_cache();

        let hidden = self
            .model
            .forward(&input, 0)
            .map_err(|e| BtError::Internal(format!("model forward: {e}")))?;

        let last_index = encoded.real_len - 1;
        let last: Tensor = hidden
            .narrow(1, last_index, 1)
            .and_then(|t| t.squeeze(1))
            .and_then(|t| t.squeeze(0))
            .and_then(|t| t.to_dtype(DType::F32))
            .map_err(|e| BtError::Internal(format!("pool last token: {e}")))?;

        let mut v: Vec<f32> = last
            .to_vec1()
            .map_err(|e| BtError::Internal(format!("read embedding: {e}")))?;

        if v.len() > self.target_dim {
            v.truncate(self.target_dim);
        } else if v.len() < self.target_dim {
            v.resize(self.target_dim, 0.0);
        }
        l2_normalize(&mut v);
        Ok(v)
    }
}

/// L2-normalize in place. No-op on zero vectors.
pub fn l2_normalize(v: &mut [f32]) {
    let mag: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if mag > f32::EPSILON {
        for x in v.iter_mut() {
            *x /= mag;
        }
    }
}

fn pick_device() -> Device {
    // candle's `Device::new_metal(0)` is gated behind the `metal`
    // feature; on non-mac hosts that compiles but returns Err. CPU
    // is always available.
    #[cfg(target_os = "macos")]
    {
        if let Ok(d) = Device::new_metal(0) {
            return d;
        }
    }
    Device::Cpu
}

fn pick_dtype(device: &Device) -> DType {
    // F16 on Metal is materially faster and the recall hit vs F32 is
    // <0.1 MTEB. CPU prefers F32 because candle's CPU kernels are
    // F32-first.
    if device.is_metal() {
        DType::F16
    } else {
        DType::F32
    }
}

/// Public alias kept stable so the embedder module doesn't need to
/// reach into private types.
pub type Runtime = Qwen3Runtime;

#[allow(dead_code)]
pub(crate) fn ensure_paths(model_dir: &Path) -> Result<PathBuf, BtError> {
    if !model_dir.is_dir() {
        return Err(BtError::Internal(format!(
            "model dir missing: {}",
            model_dir.display()
        )));
    }
    for name in ["config.json", "tokenizer.json", "model.safetensors"] {
        let p = model_dir.join(name);
        if !p.is_file() {
            return Err(BtError::Internal(format!(
                "model file missing: {}",
                p.display()
            )));
        }
    }
    Ok(model_dir.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn l2_normalize_zero_vector_stays_zero() {
        let mut v = vec![0.0_f32; 8];
        l2_normalize(&mut v);
        assert!(v.iter().all(|x| *x == 0.0));
    }

    #[test]
    fn l2_normalize_unit_norm() {
        let mut v = vec![3.0_f32, 4.0];
        l2_normalize(&mut v);
        assert!((v[0] * v[0] + v[1] * v[1] - 1.0).abs() < 1e-6);
    }

    /// End-to-end smoke test: load the real Qwen3-Embedding-0.6B
    /// model from a user-supplied directory and verify that
    /// (a) the safetensors weights map cleanly onto our vendored
    /// model graph, and (b) the runtime produces semantically
    /// meaningful vectors — paraphrases are closer to each other
    /// than to unrelated inputs.
    ///
    /// `#[ignore]` so it doesn't run in CI without weights. Invoke
    /// manually:
    /// ```sh
    /// TADO_DOME_TEST_MODEL_DIR=~/Library/Application\ Support/Tado/dome/.bt/models/qwen3-embedding-0.6b \
    ///   cargo test -p bt-core --lib qwen3_runtime::tests::loads_real_model -- --ignored --nocapture
    /// ```
    #[test]
    #[ignore]
    fn loads_real_model() {
        let Ok(dir) = std::env::var("TADO_DOME_TEST_MODEL_DIR") else {
            eprintln!("set TADO_DOME_TEST_MODEL_DIR to run this");
            return;
        };
        let dir = std::path::PathBuf::from(dir);
        let mut rt = Qwen3Runtime::load(&dir, DEFAULT_DIM)
            .expect("load qwen3 runtime");
        assert_eq!(rt.dimension(), DEFAULT_DIM);
        let v_cat = rt.embed_passage("the cat sat on the mat").expect("embed cat");
        let v_feline = rt.embed_passage("a feline rested upon the carpet").expect("embed feline");
        let v_unrelated = rt.embed_passage("rocket trajectory at low orbit").expect("embed rocket");
        assert_eq!(v_cat.len(), DEFAULT_DIM);
        let dot_paraphrase: f32 = v_cat.iter().zip(v_feline.iter()).map(|(a, b)| a * b).sum();
        let dot_unrelated: f32 = v_cat.iter().zip(v_unrelated.iter()).map(|(a, b)| a * b).sum();
        eprintln!("paraphrase cosine={dot_paraphrase} unrelated cosine={dot_unrelated}");
        assert!(
            dot_paraphrase > dot_unrelated,
            "expected paraphrase to be closer than unrelated: para={dot_paraphrase} unrel={dot_unrelated}"
        );
    }
}
