use crate::error::BtError;
use chrono::Utc;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Component, Path, PathBuf};

const AUDIT_ROTATE_BYTES: u64 = 20 * 1024 * 1024;
const AUDIT_ROTATE_COUNT: usize = 5;

pub fn sanitize_segment(input: &str) -> Result<String, BtError> {
    let mut out = String::new();
    for c in input.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if c.is_whitespace() || c == '-' || c == '_' {
            out.push('-');
        }
    }
    let out = out
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    if out.is_empty() {
        return Err(BtError::Validation(
            "empty slug after sanitization".to_string(),
        ));
    }
    Ok(out)
}

pub fn ensure_vault_layout(vault_root: &Path) -> Result<(), BtError> {
    fs::create_dir_all(vault_root.join("topics"))?;
    fs::create_dir_all(vault_root.join(".bt"))?;
    fs::create_dir_all(vault_root.join(".bt/locks"))?;
    fs::create_dir_all(vault_root.join(".bt/cache"))?;
    fs::create_dir_all(vault_root.join(".bt/artifacts"))?;
    fs::create_dir_all(vault_root.join(".bt/artifacts/runs"))?;
    fs::create_dir_all(vault_root.join(".bt/context/packs"))?;
    if !vault_root.join("tasks.md").exists() {
        atomic_write(vault_root, &vault_root.join("tasks.md"), "# Tasks\n\n")?;
    }
    Ok(())
}

pub fn canonicalize_vault(path: &Path) -> Result<PathBuf, BtError> {
    let full = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    fs::create_dir_all(&full).map_err(|e| {
        BtError::Io(format!(
            "could not create vault directory {}: {}",
            full.display(),
            e
        ))
    })?;
    let canonical = fs::canonicalize(&full).map_err(|e| {
        BtError::Io(format!(
            "could not resolve vault path {} (directory was created but could not be canonicalized — check for broken symlinks or inaccessible mounts): {}",
            full.display(),
            e
        ))
    })?;
    if !canonical.is_dir() {
        return Err(BtError::InvalidVaultPath(format!(
            "{} is not a directory",
            canonical.display()
        )));
    }
    Ok(canonical)
}

fn validate_relative(rel: &Path) -> Result<(), BtError> {
    for c in rel.components() {
        match c {
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(BtError::PathEscape(format!(
                    "invalid component in {}",
                    rel.display()
                )))
            }
            Component::CurDir => {}
            Component::Normal(_) => {}
        }
    }
    Ok(())
}

pub fn safe_join(vault_root: &Path, rel: &Path) -> Result<PathBuf, BtError> {
    validate_relative(rel)?;
    let joined = vault_root.join(rel);
    let parent = joined
        .parent()
        .ok_or_else(|| BtError::PathEscape("missing parent".to_string()))?;
    fs::create_dir_all(parent)?;
    let parent_canon = fs::canonicalize(parent)?;
    let vault_canon = fs::canonicalize(vault_root)?;
    if !parent_canon.starts_with(&vault_canon) {
        return Err(BtError::PathEscape(format!(
            "{} escapes vault",
            joined.display()
        )));
    }
    Ok(joined)
}

pub fn atomic_write(vault_root: &Path, target: &Path, content: &str) -> Result<(), BtError> {
    let parent = target
        .parent()
        .ok_or_else(|| BtError::Io("target has no parent".to_string()))?;
    fs::create_dir_all(parent)?;
    let parent_canon = fs::canonicalize(parent)?;
    let vault_canon = fs::canonicalize(vault_root)?;
    if !parent_canon.starts_with(&vault_canon) {
        return Err(BtError::PathEscape(format!(
            "{} escapes vault",
            target.display()
        )));
    }

    let nanos = Utc::now().timestamp_nanos_opt().unwrap_or_default();
    let tmp = parent.join(format!(
        ".{}.tmp-{}",
        target
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("write"),
        nanos
    ));

    {
        let mut f = File::create(&tmp)?;
        f.write_all(content.as_bytes())?;
        f.sync_all()?;
    }

    fs::rename(&tmp, target)?;
    Ok(())
}

/// Append a single line to an append-only log file inside the vault.
///
/// This is the fast path for the audit log (and any other append-only log
/// we might ship later). It uses `O_APPEND | O_CREAT` so the kernel does
/// the seek-to-end atomically, and writes the payload in a single syscall
/// so other concurrent writers cannot interleave bytes.
///
/// Why this exists as a separate primitive: the naïve
/// `fs::read_to_string + push_str + atomic_write` pattern is O(N²) in the
/// number of entries written — each append re-reads and re-writes the
/// entire log. That was the root cause of the `craftship_session_launch`
/// RPC timeouts that kept returning in phases of development: the audit
/// log would grow, every audit() call would slow down proportionally,
/// and eventually the 45-second client timeout on the doc-plan handoff
/// path would fire. See
/// `operations/quality/2026-04-08-rpc-latency-hardening.md`.
///
/// This primitive is O(1) regardless of how many lines are already in the
/// file. Callers are responsible for calling `rotate_audit_if_needed` on
/// their own cadence.
///
/// Safety: single writes under `PIPE_BUF` (4 KB on macOS / 4 KB on Linux)
/// are atomic under `O_APPEND`. Audit entries are well under that limit.
/// For larger payloads the atomicity guarantee degrades to "no interleave
/// on the same fd" which is still correct for our append-only use case.
pub fn append_log_line(vault_root: &Path, target: &Path, line_without_newline: &str) -> Result<(), BtError> {
    let parent = target
        .parent()
        .ok_or_else(|| BtError::Io("target has no parent".to_string()))?;
    fs::create_dir_all(parent)?;
    let parent_canon = fs::canonicalize(parent)?;
    let vault_canon = fs::canonicalize(vault_root)?;
    if !parent_canon.starts_with(&vault_canon) {
        return Err(BtError::PathEscape(format!(
            "{} escapes vault",
            target.display()
        )));
    }

    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(target)?;

    // One write, one syscall, newline-terminated. This is the entire fix.
    let mut payload = String::with_capacity(line_without_newline.len() + 1);
    payload.push_str(line_without_newline);
    payload.push('\n');
    f.write_all(payload.as_bytes())?;
    // Intentionally NOT calling `f.sync_all()` here: audit entries are
    // event logs, not transactional state, and fsync on every append adds
    // tens of milliseconds per call which would re-create the slow path
    // this primitive exists to kill. The OS page cache gives us per-write
    // durability under normal shutdown; the SQLite audit table
    // (populated in parallel) is the durable ledger for crash recovery.
    Ok(())
}

pub struct DocLock {
    path: PathBuf,
}

impl Drop for DocLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub fn acquire_doc_lock(vault_root: &Path, doc_id: &str, actor: &str) -> Result<DocLock, BtError> {
    let lock_path = safe_join(vault_root, Path::new(&format!(".bt/locks/{}.lock", doc_id)))?;
    if lock_path.exists() {
        return Err(BtError::Conflict(format!(
            "doc {} is already locked",
            doc_id
        )));
    }

    let mut f = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&lock_path)?;
    let payload = format!(
        "actor={}\npid={}\nts={}\n",
        actor,
        std::process::id(),
        Utc::now().to_rfc3339()
    );
    f.write_all(payload.as_bytes())?;
    f.sync_all()?;

    Ok(DocLock { path: lock_path })
}

pub fn rotate_audit_if_needed(vault_root: &Path) -> Result<(), BtError> {
    let audit_path = safe_join(vault_root, Path::new(".bt/audit.log"))?;
    if !audit_path.exists() {
        return Ok(());
    }
    let metadata = fs::metadata(&audit_path)?;
    if metadata.len() < AUDIT_ROTATE_BYTES {
        return Ok(());
    }

    for i in (1..=AUDIT_ROTATE_COUNT).rev() {
        let current = audit_path.with_extension(format!("log.{}", i));
        if i == AUDIT_ROTATE_COUNT {
            if current.exists() {
                let _ = fs::remove_file(&current);
            }
            continue;
        }
        let next = audit_path.with_extension(format!("log.{}", i + 1));
        if current.exists() {
            let _ = fs::rename(&current, &next);
        }
    }

    let first = audit_path.with_extension("log.1");
    fs::rename(&audit_path, first)?;
    Ok(())
}
