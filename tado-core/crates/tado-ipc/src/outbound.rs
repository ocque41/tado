//! External-sender outbound helper.
//!
//! Writes one [`IpcMessage`] envelope into
//! `<root>/a2a-inbox/<uuid>.msg` atomically (write-temp + rename).
//! The Tado broker polls that directory and routes delivered
//! messages into the target session's inbox within ~3s.
//!
//! Dome's Copy-to-Tado extension does the same thing from Swift
//! today; exposing it here means future non-Swift callers share a
//! single implementation and a single envelope encoding.

use crate::message::IpcMessage;
use crate::paths::IpcPaths;
use std::fs;
use std::io::Write;
use std::path::Path;
use thiserror::Error;

/// Failures writing to the inbox.
#[derive(Debug, Error)]
pub enum OutboundError {
    /// `<root>/a2a-inbox/` is not present — typically means Tado
    /// isn't running on the machine right now.
    #[error("a2a-inbox not present at {path}; is Tado running?")]
    InboxMissing { path: String },

    #[error("failed to serialize message: {0}")]
    Serialize(#[from] serde_json::Error),

    #[error("filesystem error: {0}")]
    Io(#[from] std::io::Error),
}

/// Write a message envelope into the broker's external inbox at
/// `<paths.root>/a2a-inbox/<id>.msg`.
///
/// Atomic write discipline: serialize into a temp file next to the
/// destination (same directory, same filesystem so `rename` is
/// atomic), fsync, then rename. Prevents the broker's poller from
/// picking up a half-written JSON blob.
pub fn write_external_message(
    paths: &IpcPaths,
    message: &IpcMessage,
) -> Result<std::path::PathBuf, OutboundError> {
    let inbox = paths.a2a_inbox();
    if !Path::new(&inbox).exists() {
        return Err(OutboundError::InboxMissing {
            path: inbox.display().to_string(),
        });
    }

    let filename = IpcPaths::message_filename(&message.id);
    let final_path = inbox.join(&filename);
    let tmp_path = inbox.join(format!(".{filename}.tmp"));

    let bytes = serde_json::to_vec(message)?;
    {
        let mut tmp = fs::File::create(&tmp_path)?;
        tmp.write_all(&bytes)?;
        tmp.sync_data()?;
    }
    fs::rename(&tmp_path, &final_path)?;

    Ok(final_path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::{IpcMessage, IpcMessageStatus};
    use std::fs;
    use uuid::Uuid;

    fn tempdir() -> std::path::PathBuf {
        let base = std::env::temp_dir().join(format!(
            "tado-ipc-test-{}",
            Uuid::new_v4().as_hyphenated()
        ));
        fs::create_dir_all(&base).unwrap();
        fs::create_dir_all(base.join("a2a-inbox")).unwrap();
        base
    }

    #[test]
    fn write_external_message_creates_msg_file() {
        let root = tempdir();
        let paths = IpcPaths::at(&root);
        let to = Uuid::new_v4();
        let msg = IpcMessage::new(
            IpcMessage::external_origin_uuid(),
            "dome test",
            to,
            "hello",
        );
        let written = write_external_message(&paths, &msg).unwrap();
        assert!(written.exists());
        // Round-trip the written file through the decoder.
        let raw = fs::read(&written).unwrap();
        let back: IpcMessage = serde_json::from_slice(&raw).unwrap();
        assert_eq!(back.body, "hello");
        assert_eq!(back.from_name, "dome test");
        assert!(matches!(back.status, IpcMessageStatus::Pending));
        // Cleanup
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn write_external_message_errors_when_inbox_missing() {
        let root = std::env::temp_dir().join(format!(
            "tado-ipc-missing-{}",
            Uuid::new_v4().as_hyphenated()
        ));
        // NB: no a2a-inbox subdir
        fs::create_dir_all(&root).unwrap();
        let paths = IpcPaths::at(&root);
        let to = Uuid::new_v4();
        let msg = IpcMessage::new(Uuid::nil(), "x", to, "y");
        let err = write_external_message(&paths, &msg).unwrap_err();
        assert!(matches!(err, OutboundError::InboxMissing { .. }));
        let _ = fs::remove_dir_all(&root);
    }
}
