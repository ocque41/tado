//! HuggingFace tokenizer wrapper for Qwen3-Embedding-0.6B.
//!
//! Two responsibilities:
//! 1. Load `tokenizer.json` once at startup, keep it `Send + Sync` so
//!    `Arc<Tokenizer>` can fan out to per-call workers.
//! 2. Apply the embedder's instruction prefix and truncate to a token
//!    budget. Qwen3 supports a 32k context, but for retrieval recall
//!    plateaus past ~512 tokens — we cap there to keep the model fast
//!    and the GPU memory bounded.

use std::path::Path;

use tokenizers::Tokenizer;

use crate::error::BtError;

/// Hard token cap fed into the model. Tunable via env without a code
/// change so we can A/B test cap length on real workloads.
pub const DEFAULT_MAX_TOKENS: usize = 512;

/// One pre-tokenized input ready for the model. We carry both the ids
/// and the count of real (non-padded) tokens so the runtime can read
/// the last hidden state at the right position when batching adds
/// padding.
#[derive(Debug, Clone)]
pub struct Encoded {
    pub ids: Vec<u32>,
    pub real_len: usize,
}

#[derive(Debug)]
pub struct Qwen3Tokenizer {
    inner: Tokenizer,
    max_tokens: usize,
    pad_id: u32,
    eos_id: u32,
}

impl Qwen3Tokenizer {
    pub fn load(tokenizer_path: &Path) -> Result<Self, BtError> {
        let inner = Tokenizer::from_file(tokenizer_path)
            .map_err(|e| BtError::Internal(format!("tokenizer load failed: {e}")))?;
        let max_tokens = std::env::var("TADO_DOME_EMBEDDING_MAX_TOKENS")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .map(|n| n.clamp(64, 8192))
            .unwrap_or(DEFAULT_MAX_TOKENS);

        let pad_id = inner
            .token_to_id("<|endoftext|>")
            .or_else(|| inner.token_to_id("[PAD]"))
            .unwrap_or(0);
        let eos_id = inner
            .token_to_id("<|endoftext|>")
            .or_else(|| inner.token_to_id("</s>"))
            .unwrap_or(pad_id);

        Ok(Self {
            inner,
            max_tokens,
            pad_id,
            eos_id,
        })
    }

    pub fn pad_id(&self) -> u32 {
        self.pad_id
    }

    pub fn eos_id(&self) -> u32 {
        self.eos_id
    }

    pub fn max_tokens(&self) -> usize {
        self.max_tokens
    }

    /// Encode a passage (the content we *index*). Per the Qwen3-Embedding
    /// model card: passages are embedded **without** an instruction
    /// prefix. Adding one here would silently degrade retrieval recall.
    pub fn encode_passage(&self, content: &str) -> Result<Encoded, BtError> {
        self.encode_inner(content)
    }

    /// Encode a query (the user's search). Per the Qwen3-Embedding
    /// model card: queries get an `Instruct: ...\nQuery: ...` prefix
    /// that tells the model what kind of relevance it's measuring.
    pub fn encode_query(&self, instruction: &str, query: &str) -> Result<Encoded, BtError> {
        let prompt = if instruction.trim().is_empty() {
            query.to_string()
        } else {
            format!("Instruct: {instruction}\nQuery: {query}")
        };
        self.encode_inner(&prompt)
    }

    fn encode_inner(&self, text: &str) -> Result<Encoded, BtError> {
        let encoding = self
            .inner
            .encode(text, true)
            .map_err(|e| BtError::Internal(format!("tokenize failed: {e}")))?;

        let mut ids = encoding.get_ids().to_vec();
        // Reserve one slot for the EOS so last-token pooling sees the
        // marker the model was trained on.
        if ids.len() > self.max_tokens.saturating_sub(1) {
            ids.truncate(self.max_tokens.saturating_sub(1));
        }
        if ids.last() != Some(&self.eos_id) {
            ids.push(self.eos_id);
        }
        let real_len = ids.len();
        Ok(Encoded { ids, real_len })
    }
}

#[cfg(test)]
mod tests {
    // The tokenizer file is multi-MB and not checked into the repo;
    // these tests only run when the model is present locally.
    use super::*;

    #[test]
    fn missing_file_errors_cleanly() {
        let p = std::path::PathBuf::from("/nonexistent/path/tokenizer.json");
        assert!(Qwen3Tokenizer::load(&p).is_err());
    }
}
