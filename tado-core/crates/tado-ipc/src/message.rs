//! On-disk JSON types for Tado's IPC contract.
//!
//! Shapes must stay byte-compatible with Swift's
//! `Sources/Tado/Models/IPCMessage.swift`:
//!
//! ```text
//! struct IPCMessage: Codable {
//!     let id: UUID
//!     let from: UUID
//!     let fromName: String
//!     let to: UUID
//!     let timestamp: Date      // ISO 8601
//!     let body: String
//!     var status: IPCMessageStatus  // "pending" | "delivered"
//! }
//! ```
//!
//! Swift's `JSONEncoder.dateEncodingStrategy = .iso8601` encodes
//! `Date` as an ISO8601 string (not epoch seconds), so
//! `chrono::DateTime<Utc>` with its default serde representation
//! matches out of the box.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Envelope exchanged between agents / extensions / the Tado broker.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IpcMessage {
    pub id: Uuid,
    pub from: Uuid,
    pub from_name: String,
    pub to: Uuid,
    pub timestamp: DateTime<Utc>,
    pub body: String,
    pub status: IpcMessageStatus,
}

impl IpcMessage {
    /// Create a new message envelope stamped with "now".
    pub fn new(from: Uuid, from_name: impl Into<String>, to: Uuid, body: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            from,
            from_name: from_name.into(),
            to,
            timestamp: Utc::now(),
            body: body.into(),
            status: IpcMessageStatus::Pending,
        }
    }

    /// Convention for external (non-session) senders: an all-zero
    /// UUID stands in as `from` so the receiving session can tell
    /// the message arrived from outside its own canvas world.
    pub fn external_origin_uuid() -> Uuid {
        Uuid::nil()
    }
}

/// Matches Swift's `enum IPCMessageStatus: String`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum IpcMessageStatus {
    Pending,
    Delivered,
}

/// Registry row published by Tado to `/tmp/tado-ipc/registry.json`.
/// Matches Swift's `IPCSessionEntry`. `rename_all = "camelCase"`
/// maps Rust's snake_case fields to the Swift/JSON form.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IpcSessionEntry {
    #[serde(rename = "sessionID")]
    pub session_id: Uuid,
    pub name: String,
    pub engine: String,
    pub grid_label: String,
    pub status: String,
    // `skip_serializing_if = "Option::is_none"` matches Swift's
    // `JSONEncoder` default, which omits nil optionals entirely
    // rather than emitting explicit `null`s. Important for byte-
    // compatibility with the Swift-written `registry.json`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team_name: Option<String>,
    #[serde(default, rename = "teamID", skip_serializing_if = "Option::is_none")]
    pub team_id: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_roundtrip_matches_swift_shape() {
        // Hand-crafted JSON that a Swift-written broker would produce.
        // If we can round-trip it we stay byte-compatible.
        let json = r#"{
            "id": "00000000-0000-0000-0000-000000000001",
            "from": "00000000-0000-0000-0000-000000000000",
            "fromName": "Dome / Copy to Tado",
            "to": "7a7a0000-0000-0000-0000-000000000000",
            "timestamp": "2026-04-22T01:00:00Z",
            "body": "hello from dome",
            "status": "pending"
        }"#;
        let msg: IpcMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg.from_name, "Dome / Copy to Tado");
        assert_eq!(msg.body, "hello from dome");
        assert!(matches!(msg.status, IpcMessageStatus::Pending));
        let reencoded = serde_json::to_string(&msg).unwrap();
        // Ensure the camelCase fromName + camelCase top-level survived.
        assert!(reencoded.contains("\"fromName\""));
        assert!(reencoded.contains("\"status\":\"pending\""));
    }

    #[test]
    fn session_entry_roundtrip_with_optionals_missing() {
        let json = r#"{
            "sessionID": "11111111-1111-1111-1111-111111111111",
            "name": "notes",
            "engine": "claude",
            "gridLabel": "1,1",
            "status": "running"
        }"#;
        let entry: IpcSessionEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.name, "notes");
        assert!(entry.project_name.is_none());
        assert!(entry.team_id.is_none());
    }

    #[test]
    fn session_entry_roundtrip_with_optionals_present() {
        let json = r#"{
            "sessionID": "11111111-1111-1111-1111-111111111111",
            "name": "notes",
            "engine": "claude",
            "gridLabel": "1,1",
            "status": "running",
            "projectName": "p",
            "agentName": "a",
            "teamName": "t",
            "teamID": "abc"
        }"#;
        let entry: IpcSessionEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.project_name.as_deref(), Some("p"));
        assert_eq!(entry.agent_name.as_deref(), Some("a"));
        assert_eq!(entry.team_name.as_deref(), Some("t"));
        assert_eq!(entry.team_id.as_deref(), Some("abc"));
    }

    #[test]
    fn external_origin_is_nil_uuid() {
        assert_eq!(IpcMessage::external_origin_uuid(), Uuid::nil());
    }
}
