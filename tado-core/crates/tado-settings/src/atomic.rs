//! Atomic JSON reader + writer.
//!
//! Matches the discipline of Swift's `AtomicStore`: write into a
//! sibling temp file on the same filesystem, fsync, then `rename`
//! into place so readers never see a partial write.
//!
//! Not (yet) a cross-process lock. The Swift layer still holds
//! `flock` today; once the Rust code owns the write path at
//! runtime we'll add the same lock here via `fs4` or similar.
//! Until then, treat this as single-writer: safe for the one
//! Swift process that's serializing through the existing
//! AtomicStore, fine for test workloads, but not guaranteed if two
//! Rust processes raced on the same key right now.

use serde::{de::DeserializeOwned, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use thiserror::Error;

/// Reasons a read or write might fail.
#[derive(Debug, Error)]
pub enum AtomicError {
    #[error("filesystem error on {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to serialize JSON: {0}")]
    Serialize(#[from] serde_json::Error),
    #[error("file is empty: {path}")]
    Empty { path: String },
}

/// Read a JSON value from `path`. Returns `Ok(None)` when the file
/// is absent — callers then fall through to the next scope in the
/// hierarchy. Any other failure becomes a typed error.
pub fn read_json<T: DeserializeOwned>(path: impl AsRef<Path>) -> Result<Option<T>, AtomicError> {
    let path = path.as_ref();
    match fs::read(path) {
        Ok(bytes) if bytes.is_empty() => Err(AtomicError::Empty {
            path: path.display().to_string(),
        }),
        Ok(bytes) => {
            let parsed: T = serde_json::from_slice(&bytes)?;
            Ok(Some(parsed))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(AtomicError::Io {
            path: path.display().to_string(),
            source: err,
        }),
    }
}

/// Write `value` as pretty JSON to `path` atomically. Creates
/// missing parent directories.
///
/// Discipline:
/// 1. Serialize to an in-memory `Vec<u8>` so a serde error never
///    leaves a half-written file behind.
/// 2. `create` a sibling temp file `.{filename}.tmp` in the same
///    parent directory so `rename` stays atomic (rename across
///    filesystems is not atomic).
/// 3. `write_all` + `sync_data` on the temp handle.
/// 4. `rename` the temp file to `path`, replacing any existing
///    content.
pub fn write_json<T: Serialize + ?Sized>(
    path: impl AsRef<Path>,
    value: &T,
) -> Result<PathBuf, AtomicError> {
    let path = path.as_ref();
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    if !parent.exists() {
        fs::create_dir_all(parent).map_err(|source| AtomicError::Io {
            path: parent.display().to_string(),
            source,
        })?;
    }

    let bytes = serde_json::to_vec_pretty(value)?;

    let file_name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "value".to_string());
    let tmp_path = parent.join(format!(".{file_name}.tmp"));

    {
        let mut tmp = fs::File::create(&tmp_path).map_err(|source| AtomicError::Io {
            path: tmp_path.display().to_string(),
            source,
        })?;
        tmp.write_all(&bytes).map_err(|source| AtomicError::Io {
            path: tmp_path.display().to_string(),
            source,
        })?;
        tmp.sync_data().map_err(|source| AtomicError::Io {
            path: tmp_path.display().to_string(),
            source,
        })?;
    }

    fs::rename(&tmp_path, path).map_err(|source| AtomicError::Io {
        path: path.display().to_string(),
        source,
    })?;

    Ok(path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};
    use tempfile::tempdir;

    #[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
    struct Payload {
        name: String,
        count: u32,
    }

    #[test]
    fn absent_file_is_none() {
        let dir = tempdir().unwrap();
        let result: Option<Payload> =
            read_json(dir.path().join("missing.json")).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn roundtrip_is_identity() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("config.json");
        let value = Payload {
            name: "alice".into(),
            count: 42,
        };
        write_json(&path, &value).unwrap();
        let back: Option<Payload> = read_json(&path).unwrap();
        assert_eq!(back, Some(value));
    }

    #[test]
    fn write_creates_missing_parent_dirs() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("deep/nested/config.json");
        let value = Payload {
            name: "x".into(),
            count: 1,
        };
        write_json(&path, &value).unwrap();
        assert!(path.exists());
    }

    #[test]
    fn atomic_write_does_not_leave_tmp_behind() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("config.json");
        let value = Payload {
            name: "x".into(),
            count: 1,
        };
        write_json(&path, &value).unwrap();
        // Ensure only config.json exists; the `.config.json.tmp`
        // sibling must have been renamed away.
        let entries: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(entries, vec!["config.json".to_string()]);
    }

    #[test]
    fn empty_file_returns_empty_error() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("empty.json");
        fs::write(&path, b"").unwrap();
        let err = read_json::<Payload>(&path).unwrap_err();
        assert!(matches!(err, AtomicError::Empty { .. }));
    }

    #[test]
    fn malformed_json_surfaces_serialize_error() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("bad.json");
        fs::write(&path, b"{ not json }").unwrap();
        let err = read_json::<Payload>(&path).unwrap_err();
        assert!(matches!(err, AtomicError::Serialize(_)));
    }
}
