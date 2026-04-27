//! First-launch fetch for the Qwen3-Embedding-0.6B model files.
//!
//! Downloads `config.json`, `tokenizer.json`, `tokenizer_config.json`,
//! and `model.safetensors` from HuggingFace into
//! `<vault>/.bt/models/qwen3-embedding-0.6b/`. Resumable via HTTP
//! `Range` headers.
//!
//! ## Source of truth: the disk
//!
//! The progress reported to the UI is computed from on-disk file
//! sizes, not from an in-memory atomic counter. Reasons:
//!
//! 1. Progress survives app restarts. If a previous run wrote 800 MB
//!    and was killed, the next launch can pick up at 800 MB instead
//!    of resetting the bar to 0.
//! 2. Single source of truth — no atomic-counter / file-size drift to
//!    debug.
//! 3. The UI doesn't depend on the worker thread having published
//!    anything yet; the moment the download starts the bar moves.
//!
//! ## No retries, no watchdog
//!
//! Per CLAUDE.md (`No new safety systems around dispatch`). We do
//! one attempt per file, surface failures via the fetch log + the
//! status FFI, and rely on the user to click "Download" again. The
//! resume-from-Range path makes a re-click cheap.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use sha2::{Digest, Sha256};

use crate::error::BtError;

pub const HF_REPO: &str = "Qwen/Qwen3-Embedding-0.6B";

/// Expected sizes, in bytes, for the four files we pull from
/// HuggingFace. Hardcoded because:
///
/// - `HEAD https://huggingface.co/...` returns the redirect body
///   length (e.g., 1343 bytes), not the file length, unless the
///   client explicitly follows the redirect *and* the CDN responds
///   with `Content-Length` rather than `Transfer-Encoding: chunked`.
///   That dance is fragile across CDN configurations.
/// - These four files are pinned to the published Qwen3-Embedding-0.6B
///   release. They don't change. If HF ever republishes with
///   different bytes, the `is_complete` check below will reject the
///   download and force a re-fetch — better than a corrupt model
///   loading silently.
pub const FILES: &[ModelFile] = &[
    ModelFile {
        name: "config.json",
        relative_url: "config.json",
        expected_bytes: 727,
    },
    ModelFile {
        name: "tokenizer.json",
        relative_url: "tokenizer.json",
        expected_bytes: 11_423_705,
    },
    ModelFile {
        name: "tokenizer_config.json",
        relative_url: "tokenizer_config.json",
        expected_bytes: 9_706,
    },
    ModelFile {
        name: "model.safetensors",
        relative_url: "model.safetensors",
        expected_bytes: 1_191_586_416,
    },
];

#[derive(Debug, Clone, Copy)]
pub struct ModelFile {
    pub name: &'static str,
    pub relative_url: &'static str,
    pub expected_bytes: u64,
}

/// Sum of the canonical sizes — the denominator for the UI progress
/// bar. ≈ 1.20 GB.
pub fn expected_total_bytes() -> u64 {
    FILES.iter().map(|f| f.expected_bytes).sum()
}

/// Resolve the model directory under the vault. Created if missing.
pub fn model_dir(vault_root: &Path) -> std::io::Result<PathBuf> {
    let dir = vault_root.join(".bt").join("models").join("qwen3-embedding-0.6b");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// Path to the human-readable fetch log. Written line-by-line as
/// the worker thread progresses so a `tail -f` from another terminal
/// can show what's going on.
pub fn fetch_log_path(vault_root: &Path) -> std::io::Result<PathBuf> {
    Ok(model_dir(vault_root)?.join("_fetch.log"))
}

/// True when every file is present **and at its expected size**.
/// `len > 0` is not enough — a 800 MB partial of a 1.2 GB file would
/// pass that check and silently break load.
pub fn is_complete(vault_root: &Path) -> bool {
    let Ok(dir) = model_dir(vault_root) else {
        return false;
    };
    FILES.iter().all(|f| {
        let p = dir.join(f.name);
        match fs::metadata(&p) {
            Ok(m) => m.is_file() && m.len() == f.expected_bytes,
            Err(_) => false,
        }
    })
}

/// Backwards-compatible alias used by older callers. Now means "any
/// trace of the model on disk" — kept for API compatibility but the
/// load path uses [`is_complete`] before attaching the runtime.
pub fn is_present(vault_root: &Path) -> bool {
    let Ok(dir) = model_dir(vault_root) else {
        return false;
    };
    FILES.iter().all(|f| dir.join(f.name).is_file())
}

pub const MODEL_PATH_ENV: &str = "TADO_DOME_EMBEDDING_MODEL_PATH";

/// Resolve the directory we should load from. Returns `None` when the
/// model is not yet complete (caller should kick off `fetch_all`).
pub fn resolve_model_dir(vault_root: &Path) -> Option<PathBuf> {
    if let Ok(override_dir) = std::env::var(MODEL_PATH_ENV) {
        let p = PathBuf::from(override_dir.trim());
        if p.is_dir() && FILES.iter().all(|f| p.join(f.name).is_file()) {
            return Some(p);
        }
    }
    let dir = model_dir(vault_root).ok()?;
    if is_complete(vault_root) {
        Some(dir)
    } else {
        None
    }
}

/// State shared between the worker thread and the FFI. The actual
/// byte counts come from the disk; this struct only holds the live
/// "current file" label and a sticky error string so the UI can
/// surface failures.
#[derive(Debug, Default)]
pub struct FetchProgress {
    current_file: Mutex<Option<String>>,
    completed: Mutex<bool>,
    error: Mutex<Option<String>>,
}

impl FetchProgress {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn set_current(&self, name: &str) {
        if let Ok(mut g) = self.current_file.lock() {
            *g = Some(name.to_string());
        }
    }

    pub fn mark_completed(&self) {
        if let Ok(mut g) = self.completed.lock() {
            *g = true;
        }
    }

    pub fn record_error(&self, message: impl Into<String>) {
        if let Ok(mut g) = self.error.lock() {
            *g = Some(message.into());
        }
    }

    pub fn record_error_clear(&self) {
        if let Ok(mut g) = self.error.lock() {
            *g = None;
        }
    }

    pub fn snapshot(&self, vault_root: &Path) -> FetchSnapshot {
        let downloaded = downloaded_bytes(vault_root);
        let total = expected_total_bytes();
        let completed_flag = self.completed.lock().map(|g| *g).unwrap_or(false);
        let completed = completed_flag || (downloaded >= total && total > 0);
        FetchSnapshot {
            total_bytes: total,
            downloaded_bytes: downloaded,
            current_file: self
                .current_file
                .lock()
                .ok()
                .and_then(|g| g.clone()),
            completed,
            error: self.error.lock().ok().and_then(|g| g.clone()),
        }
    }
}

/// Sum of the on-disk sizes for every expected file, capped at the
/// expected size per file (so a corrupt over-sized file can't push
/// the bar past 100%).
pub fn downloaded_bytes(vault_root: &Path) -> u64 {
    let Ok(dir) = model_dir(vault_root) else {
        return 0;
    };
    FILES
        .iter()
        .map(|f| {
            fs::metadata(dir.join(f.name))
                .map(|m| m.len().min(f.expected_bytes))
                .unwrap_or(0)
        })
        .sum()
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct FetchSnapshot {
    pub total_bytes: u64,
    pub downloaded_bytes: u64,
    pub current_file: Option<String>,
    pub completed: bool,
    pub error: Option<String>,
}

/// Append a line to `<vault>/.bt/models/qwen3-embedding-0.6b/_fetch.log`.
/// Best-effort — if the log can't be written we keep going.
fn log_line(vault_root: &Path, line: &str) {
    let Ok(p) = fetch_log_path(vault_root) else {
        return;
    };
    let timestamp = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ");
    let _ = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&p)
        .and_then(|mut f| writeln!(f, "{timestamp} {line}"));
}

/// Download every required file. Resumes partial downloads using HTTP
/// `Range`. Updates `progress.current_file` as it advances; the UI
/// reads byte counts from disk, not from `progress`.
pub fn fetch_all(vault_root: &Path, progress: &Arc<FetchProgress>) -> Result<PathBuf, BtError> {
    let dir = model_dir(vault_root)
        .map_err(|e| BtError::Internal(format!("model dir create failed: {e}")))?;

    log_line(
        vault_root,
        &format!(
            "fetch_all start: dir={} expected_total={}",
            dir.display(),
            expected_total_bytes()
        ),
    );

    for file in FILES {
        progress.set_current(file.name);
        log_line(
            vault_root,
            &format!("fetch_one start: {} (expected {} bytes)", file.name, file.expected_bytes),
        );
        let target = dir.join(file.name);
        if let Err(e) = fetch_one(vault_root, file, &target) {
            let msg = format!("download {} failed: {e}", file.name);
            log_line(vault_root, &format!("ERROR: {msg}"));
            progress.record_error(&msg);
            return Err(BtError::Internal(msg));
        }
        log_line(
            vault_root,
            &format!(
                "fetch_one done: {} (on-disk={} bytes)",
                file.name,
                fs::metadata(&target).map(|m| m.len()).unwrap_or(0)
            ),
        );
    }

    progress.mark_completed();
    log_line(vault_root, "fetch_all completed");
    Ok(dir)
}

fn fetch_one(
    vault_root: &Path,
    file: &ModelFile,
    target: &Path,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let url = format!(
        "https://huggingface.co/{}/resolve/main/{}",
        HF_REPO, file.relative_url
    );

    let already = match fs::metadata(target) {
        Ok(m) => m.len(),
        Err(_) => 0,
    };

    // If we already have the exact expected bytes on disk, skip the
    // request entirely. Saves a round-trip on second-launch where the
    // user's vault is already complete.
    if already == file.expected_bytes {
        log_line(
            vault_root,
            &format!(
                "fetch_one skip (size matches expected): {} ({} bytes)",
                file.name, already
            ),
        );
        return Ok(());
    }

    // Over-sized files are likely junk from a previous error path;
    // start over to avoid trusting whatever's on disk.
    let already = if already > file.expected_bytes {
        log_line(
            vault_root,
            &format!(
                "fetch_one truncating oversized {}: had {}, expected {}",
                file.name, already, file.expected_bytes
            ),
        );
        let _ = fs::remove_file(target);
        0
    } else {
        already
    };

    let client = blocking_client()?;
    let mut req = client.get(&url);
    if already > 0 {
        req = req.header("Range", format!("bytes={already}-"));
        log_line(
            vault_root,
            &format!("fetch_one resume: {} from byte {}", file.name, already),
        );
    }
    let mut resp = req.send()?;
    let status = resp.status().as_u16();
    log_line(
        vault_root,
        &format!(
            "fetch_one HTTP: {} status={} content-length={}",
            file.name,
            status,
            resp.content_length().unwrap_or(0)
        ),
    );
    if !(resp.status().is_success() || status == 206) {
        return Err(format!("HTTP {status} for {url}").into());
    }

    // 206 honors our Range; 200 means the server ignored it (rare for
    // HF) and we restart from byte 0.
    let mut sink: Box<dyn Write> = if already > 0 && status == 206 {
        Box::new(OpenOptions::new().append(true).open(target)?)
    } else {
        if already > 0 {
            log_line(
                vault_root,
                &format!(
                    "fetch_one server ignored Range header for {} — restarting at 0",
                    file.name
                ),
            );
        }
        Box::new(File::create(target)?)
    };

    let mut buf = [0u8; 256 * 1024];
    let mut last_log = SystemTime::now();
    let log_interval = Duration::from_secs(3);
    loop {
        let n = resp.read(&mut buf)?;
        if n == 0 {
            break;
        }
        sink.write_all(&buf[..n])?;
        if let Ok(elapsed) = last_log.elapsed() {
            if elapsed >= log_interval {
                if let Ok(meta) = fs::metadata(target) {
                    log_line(
                        vault_root,
                        &format!(
                            "fetch_one progress: {} on-disk={} / expected={}",
                            file.name, meta.len(), file.expected_bytes
                        ),
                    );
                }
                last_log = SystemTime::now();
            }
        }
    }
    sink.flush()?;

    let final_size = fs::metadata(target).map(|m| m.len()).unwrap_or(0);
    if final_size != file.expected_bytes {
        return Err(format!(
            "size mismatch for {}: got {final_size}, expected {}",
            file.name, file.expected_bytes
        )
        .into());
    }

    Ok(())
}

fn blocking_client() -> Result<reqwest::blocking::Client, reqwest::Error> {
    reqwest::blocking::Client::builder()
        .user_agent("tado-dome/0.10")
        .timeout(Duration::from_secs(60 * 30))
        .connect_timeout(Duration::from_secs(20))
        .pool_idle_timeout(Some(Duration::from_secs(30)))
        // Default redirect policy is `limited(10)` — already follows
        // HF's CloudFront 302s. No need to override.
        .build()
}

#[allow(dead_code)] // kept for symmetry with caller error paths
pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    let mut hasher = Sha256::new();
    let mut f = File::open(path)?;
    f.seek(SeekFrom::Start(0))?;
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_dir_creates_under_vault() {
        let tmp = tempfile_dir();
        let dir = model_dir(&tmp).unwrap();
        assert!(dir.exists());
        assert!(dir.ends_with("qwen3-embedding-0.6b"));
    }

    #[test]
    fn is_complete_false_for_empty_vault() {
        let tmp = tempfile_dir();
        assert!(!is_complete(&tmp));
        assert_eq!(downloaded_bytes(&tmp), 0);
    }

    #[test]
    fn snapshot_reports_disk_size() {
        let tmp = tempfile_dir();
        let dir = model_dir(&tmp).unwrap();
        // Write a partial config.json (300 bytes of 727).
        std::fs::write(dir.join("config.json"), vec![0u8; 300]).unwrap();
        let progress = FetchProgress::new();
        let snap = progress.snapshot(&tmp);
        assert_eq!(snap.downloaded_bytes, 300);
        assert_eq!(snap.total_bytes, expected_total_bytes());
        assert!(!snap.completed);
    }

    #[test]
    fn snapshot_caps_oversized_file_at_expected() {
        let tmp = tempfile_dir();
        let dir = model_dir(&tmp).unwrap();
        // 5000 bytes of a 727-byte file — should cap at 727.
        std::fs::write(dir.join("config.json"), vec![0u8; 5000]).unwrap();
        let progress = FetchProgress::new();
        let snap = progress.snapshot(&tmp);
        assert_eq!(snap.downloaded_bytes, 727);
    }

    fn tempfile_dir() -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("tado-model-fetch-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }
}
