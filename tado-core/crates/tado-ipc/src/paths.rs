//! Canonical IPC path layout.
//!
//! The Swift broker in `Sources/Tado/Services/IPCBroker.swift`
//! maintains two parallel paths:
//!
//! - `/tmp/tado-ipc-<pid>` — the _actual_ directory for this Tado
//!   instance. PID-suffixed so two Tado binaries running
//!   simultaneously don't collide.
//! - `/tmp/tado-ipc` — a symlink to the current live directory.
//!   Every external consumer (Dome's Copy-to-Tado, CLI tools,
//!   agents written in other languages) reads through this stable
//!   name so they don't have to know the PID.
//!
//! Inside either root, the layout is:
//!
//! ```text
//! <root>/
//!   registry.json                — list of [IpcSessionEntry]
//!   a2a-inbox/<uuid>.msg         — external sender drop-box
//!   sessions/<session-id>/
//!     inbox/<uuid>.msg
//!     outbox/<uuid>.msg
//!     log                        — tail of terminal output
//! ```

use std::path::{Path, PathBuf};

/// Known locations under one IPC root.
#[derive(Debug, Clone)]
pub struct IpcPaths {
    pub root: PathBuf,
}

impl IpcPaths {
    /// Stable, PID-independent root: `/tmp/tado-ipc`.
    pub fn stable() -> Self {
        Self {
            root: PathBuf::from("/tmp/tado-ipc"),
        }
    }

    /// Per-PID root Tado actually writes into: `/tmp/tado-ipc-<pid>`.
    /// External consumers should use [`Self::stable`] and let Tado's
    /// broker maintain the symlink.
    pub fn for_pid(pid: u32) -> Self {
        Self {
            root: PathBuf::from(format!("/tmp/tado-ipc-{pid}")),
        }
    }

    /// Manually specify the root. Useful in tests that don't want to
    /// touch `/tmp`.
    pub fn at(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn registry_json(&self) -> PathBuf {
        self.root.join("registry.json")
    }

    pub fn a2a_inbox(&self) -> PathBuf {
        self.root.join("a2a-inbox")
    }

    pub fn sessions(&self) -> PathBuf {
        self.root.join("sessions")
    }

    pub fn session_dir(&self, session_id: &str) -> PathBuf {
        self.sessions().join(session_id)
    }

    pub fn session_inbox(&self, session_id: &str) -> PathBuf {
        self.session_dir(session_id).join("inbox")
    }

    pub fn session_outbox(&self, session_id: &str) -> PathBuf {
        self.session_dir(session_id).join("outbox")
    }

    pub fn session_log(&self, session_id: &str) -> PathBuf {
        self.session_dir(session_id).join("log")
    }

    /// Side-channel real-time event socket (A6). Unix domain socket
    /// hosting line-delimited subscribe requests + JSON event pushes.
    /// Lives under the IPC root so the symlink-stable `/tmp/tado-ipc`
    /// path reaches it from any process.
    pub fn events_sock(&self) -> PathBuf {
        self.root.join("events.sock")
    }

    /// Filename a caller should use when dropping an envelope into
    /// `a2a-inbox/`. `<uuid>.msg` matches Swift's convention.
    pub fn message_filename(id: &uuid::Uuid) -> String {
        format!("{}.msg", id.as_hyphenated())
    }
}

impl Default for IpcPaths {
    fn default() -> Self {
        Self::stable()
    }
}

impl AsRef<Path> for IpcPaths {
    fn as_ref(&self) -> &Path {
        &self.root
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_root_is_classic_path() {
        let p = IpcPaths::stable();
        assert_eq!(p.root, PathBuf::from("/tmp/tado-ipc"));
        assert_eq!(p.registry_json(), PathBuf::from("/tmp/tado-ipc/registry.json"));
        assert_eq!(p.a2a_inbox(), PathBuf::from("/tmp/tado-ipc/a2a-inbox"));
    }

    #[test]
    fn pid_root_is_suffixed() {
        let p = IpcPaths::for_pid(42);
        assert_eq!(p.root, PathBuf::from("/tmp/tado-ipc-42"));
    }

    #[test]
    fn session_subdirs_compose_correctly() {
        let p = IpcPaths::at("/tmp/test-root");
        assert_eq!(
            p.session_inbox("abc-123"),
            PathBuf::from("/tmp/test-root/sessions/abc-123/inbox")
        );
        assert_eq!(
            p.session_outbox("abc-123"),
            PathBuf::from("/tmp/test-root/sessions/abc-123/outbox")
        );
        assert_eq!(
            p.session_log("abc-123"),
            PathBuf::from("/tmp/test-root/sessions/abc-123/log")
        );
    }

    #[test]
    fn message_filename_is_lowercase_uuid_with_suffix() {
        let id = uuid::Uuid::parse_str("00000000-0000-0000-0000-000000000001").unwrap();
        assert_eq!(
            IpcPaths::message_filename(&id),
            "00000000-0000-0000-0000-000000000001.msg"
        );
    }
}
