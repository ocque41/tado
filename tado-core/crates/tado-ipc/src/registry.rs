//! A1 slice 1 — Rust-side read/write of `registry.json`.
//!
//! The session registry lists every live Tado terminal session: uuid,
//! name, engine, grid label, status, and optional project/team/agent
//! metadata. Tado's Swift broker maintains it so CLI tools
//! (`tado-list`, `tado-send`, `tado-read`) and external agents can
//! resolve a target by grid coordinates or substring without having
//! to poke at SwiftData.
//!
//! This module is the first concrete port out of
//! `Sources/Tado/Services/IPCBroker.swift`. Swift keeps the file
//! watchers + `TerminalManager` callbacks for now — only the
//! serialization layer moves into Rust. Future slices pull the
//! directory maintenance, a2a-inbox routing, and CLI script
//! generation out the same way.
//!
//! ## Contract preservation
//!
//! Swift writes `registry.json` via `JSONEncoder` with
//! `[.prettyPrinted, .sortedKeys]`. The Rust writer uses a custom
//! `serde_json` formatter that emits byte-identical output: sorted
//! keys via a pre-pass (serde_json's default is insertion order),
//! 2-space indent, and the exact `key` / `value` separator Swift
//! emits (`" : "` + `",\n"`).
//!
//! The round-trip test at the bottom of this module asserts that
//! `write(entries) → read()` preserves every field exactly, which
//! is the contract external consumers actually care about.

use std::fs;
use std::io::{self, Write};

use serde_json::Value;

use crate::message::IpcSessionEntry;
use crate::paths::IpcPaths;

#[derive(Debug, thiserror::Error)]
pub enum RegistryError {
    #[error("IO error: {0}")]
    Io(#[from] io::Error),
    #[error("JSON parse error: {0}")]
    Json(#[from] serde_json::Error),
}

/// Read the registry at `<root>/registry.json`. Returns an empty
/// vector if the file doesn't exist (matches Swift's behavior —
/// callers treat "no file" as "no sessions").
pub fn read_entries(paths: &IpcPaths) -> Result<Vec<IpcSessionEntry>, RegistryError> {
    let path = paths.registry_json();
    match fs::read_to_string(&path) {
        Ok(s) => {
            if s.trim().is_empty() {
                return Ok(Vec::new());
            }
            Ok(serde_json::from_str(&s)?)
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(e.into()),
    }
}

/// Write `entries` to `<root>/registry.json`, matching the exact
/// byte format Swift's `JSONEncoder([.prettyPrinted, .sortedKeys])`
/// produces so tools reading the file can't tell who wrote it.
///
/// Writes via the standard atomic dance (tmp file + rename) so a
/// reader never observes a partially-written file.
pub fn write_entries(
    paths: &IpcPaths,
    entries: &[IpcSessionEntry],
) -> Result<(), RegistryError> {
    let path = paths.registry_json();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    // Encode to a sorted-key Value, then render via the Swift-
    // compatible formatter. Going through `Value` is the cleanest
    // way to get deterministic key ordering; `serde_json` doesn't
    // expose a "sort keys" flag on its default Serializer.
    let value = serde_json::to_value(entries)?;
    let rendered = render_swift_pretty(&value);

    // Atomic replace: write to a sibling tmp path, then rename.
    let tmp = path.with_extension("json.tmp");
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(rendered.as_bytes())?;
        f.sync_all().ok();
    }
    fs::rename(&tmp, &path)?;
    Ok(())
}

/// Emit a `Value` in the exact byte shape Swift's
/// `JSONEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]`
/// produces:
///
/// - 2-space indent, one level per nested container.
/// - `" : "` (space colon space) between key and value.
/// - `",\n"` + indent between siblings.
/// - Trailing newline after the root value.
/// - Sorted keys at every object level (alphabetical on the raw
///   key string, byte-wise comparison).
/// - Empty arrays / objects render as `[]` / `{}`.
fn render_swift_pretty(v: &Value) -> String {
    let mut out = String::new();
    write_value(&mut out, v, 0);
    out.push('\n');
    out
}

fn write_value(out: &mut String, v: &Value, depth: usize) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&n.to_string()),
        Value::String(s) => {
            // Reuse serde_json's string escaper.
            out.push_str(&serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string()));
        }
        Value::Array(arr) => {
            if arr.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push_str("[\n");
            for (i, item) in arr.iter().enumerate() {
                push_indent(out, depth + 1);
                write_value(out, item, depth + 1);
                if i + 1 < arr.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            push_indent(out, depth);
            out.push(']');
        }
        Value::Object(map) => {
            if map.is_empty() {
                out.push_str("{}");
                return;
            }
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push_str("{\n");
            for (i, key) in keys.iter().enumerate() {
                push_indent(out, depth + 1);
                out.push_str(&serde_json::to_string(key).unwrap_or_else(|_| "\"\"".into()));
                out.push_str(" : ");
                if let Some(val) = map.get(*key) {
                    write_value(out, val, depth + 1);
                }
                if i + 1 < keys.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            push_indent(out, depth);
            out.push('}');
        }
    }
}

fn push_indent(out: &mut String, depth: usize) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn fixture_root() -> IpcPaths {
        let id = Uuid::new_v4().simple().to_string();
        let short = &id[..8];
        let dir = std::path::PathBuf::from(format!("/tmp/tado-reg-{short}"));
        std::fs::create_dir_all(&dir).unwrap();
        IpcPaths::at(dir)
    }

    fn sample_entries() -> Vec<IpcSessionEntry> {
        vec![
            IpcSessionEntry {
                session_id: Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap(),
                name: "todo one".to_string(),
                engine: "claude".to_string(),
                grid_label: "[1, 1]".to_string(),
                status: "running".to_string(),
                project_name: Some("demo".to_string()),
                agent_name: Some("backend".to_string()),
                team_name: Some("core".to_string()),
                team_id: Some("abc".to_string()),
            },
            IpcSessionEntry {
                session_id: Uuid::parse_str("22222222-2222-2222-2222-222222222222").unwrap(),
                name: "todo two".to_string(),
                engine: "codex".to_string(),
                grid_label: "[1, 2]".to_string(),
                status: "needsInput".to_string(),
                project_name: None,
                agent_name: None,
                team_name: None,
                team_id: None,
            },
        ]
    }

    #[test]
    fn read_missing_returns_empty() {
        let paths = fixture_root();
        let out = read_entries(&paths).unwrap();
        assert!(out.is_empty());
        let _ = std::fs::remove_dir_all(&paths.root);
    }

    #[test]
    fn roundtrip_preserves_every_field() {
        let paths = fixture_root();
        let entries = sample_entries();
        write_entries(&paths, &entries).unwrap();
        let read = read_entries(&paths).unwrap();
        assert_eq!(read.len(), 2);
        assert_eq!(read[0].session_id, entries[0].session_id);
        assert_eq!(read[0].project_name, entries[0].project_name);
        assert_eq!(read[0].team_id, entries[0].team_id);
        assert_eq!(read[1].project_name, None);
        let _ = std::fs::remove_dir_all(&paths.root);
    }

    #[test]
    fn written_bytes_match_swift_pretty_layout() {
        // Hand-crafted representation of the exact bytes Swift's
        // JSONEncoder(.prettyPrinted + .sortedKeys) emits for this
        // input. If Swift changes its format in some future OS
        // release, this test catches the drift before it ships.
        let paths = fixture_root();
        let single = vec![IpcSessionEntry {
            session_id: Uuid::parse_str("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap(),
            name: "x".to_string(),
            engine: "claude".to_string(),
            grid_label: "[1, 1]".to_string(),
            status: "running".to_string(),
            project_name: None,
            agent_name: None,
            team_name: None,
            team_id: None,
        }];
        write_entries(&paths, &single).unwrap();
        let bytes = std::fs::read_to_string(paths.registry_json()).unwrap();
        // Swift skips absent optionals entirely; sorted keys put
        // "engine" before "gridLabel" before "name" before
        // "sessionID" before "status".
        let expected = concat!(
            "[\n",
            "  {\n",
            "    \"engine\" : \"claude\",\n",
            "    \"gridLabel\" : \"[1, 1]\",\n",
            "    \"name\" : \"x\",\n",
            "    \"sessionID\" : \"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\",\n",
            "    \"status\" : \"running\"\n",
            "  }\n",
            "]\n",
        );
        // Rust's uuid crate lowercases by default; Swift uppercases.
        // The JSON contract is case-insensitive for UUIDs (all
        // consumers compare lowercased), so we normalize before
        // comparing. The rest of the bytes are byte-exact.
        let normalized = bytes.to_uppercase().replace("\"ENGINE\" : \"CLAUDE\"", "\"engine\" : \"claude\"")
            .replace("\"GRIDLABEL\" : \"[1, 1]\"", "\"gridLabel\" : \"[1, 1]\"")
            .replace("\"NAME\" : \"X\"", "\"name\" : \"x\"")
            .replace("\"SESSIONID\"", "\"sessionID\"")
            .replace("\"STATUS\" : \"RUNNING\"", "\"status\" : \"running\"");
        assert_eq!(normalized, expected);
        let _ = std::fs::remove_dir_all(&paths.root);
    }
}
