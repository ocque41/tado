//! Deterministic entity extraction from doc markdown.
//!
//! Reads `docs.user_path` + `docs.agent_path` (the paired markdown
//! files) — actually the *concatenated* body the FTS5 lane already
//! sees — and emits typed `graph_nodes` + `graph_edges`:
//!
//! - **Markdown link parser**:
//!   `[label](dome://note/<id>)`  → `references` edge (current → linked)
//!   `[label](file://path)`       → `mentions_file` edge (+ file node)
//!   `[label](agent://name)`      → `authored_by` edge (+ agent node)
//!   `[label](run://<id>)`        → `occurred_in_run` edge (+ run node)
//!
//! - **Heading parser** (lines starting with `## `):
//!   `## Decision: …`  → `decision` graph_node + body chunk
//!   `## Intent: …`    → `intent`   graph_node
//!   `## Outcome: …`   → `outcome`  graph_node
//!   `## Retro …`      → `retro`    graph_node
//!
//! - **File-mention scanner**: regex `(\.{0,2}/)?[\w./-]+\.(\w{1,8})`
//!   over body text. Emits `mentions_file` for every unique path the
//!   note references (file extension whitelist keeps URLs / hashes
//!   from polluting the graph).
//!
//! Idempotency: every emitted node carries a `content_hash` derived
//! from `(doc_id, kind, normalized_label)`. Re-running the extractor
//! on the same doc updates timestamps but doesn't multiply rows.

use crate::enrichment::EnrichmentJob;
use crate::error::BtError;
use rusqlite::{params, Connection, OptionalExtension};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use uuid::Uuid;

/// Run the extractor over one job. The job's `target_id` is the doc id.
pub fn run(conn: &Connection, job: &EnrichmentJob) -> Result<ExtractReport, BtError> {
    if job.target_kind != "doc" {
        return Err(BtError::Validation(format!(
            "extractor requires target_kind='doc', got '{}'",
            job.target_kind
        )));
    }
    let doc_id = &job.target_id;

    // Pull the full text the FTS5 lane indexes (via the chunk store —
    // chunks already carry the parsed body and survive purge/reindex).
    let body = load_doc_text(conn, doc_id)?;
    let project_id = job.project_id.clone();

    let mut report = ExtractReport::default();
    let tx = conn.unchecked_transaction()?;

    // 1. Heading-derived typed nodes.
    for heading in detect_headings(&body) {
        let canonical_id = canonical_node_id(doc_id, &heading.kind, &heading.label);
        upsert_graph_node(
            &tx,
            &canonical_id,
            &heading.kind,
            doc_id,
            &heading.label,
            project_id.as_deref(),
            &heading.content_hash,
        )?;
        // Edge: doc → typed node ("contains")
        upsert_graph_edge(
            &tx,
            doc_id,
            &canonical_id,
            "contains",
            "deterministic_extract",
            0.95,
            Some(&job.job_id),
        )?;
        report.headings_extracted += 1;
    }

    // 2. Markdown link edges.
    let mut seen_links: HashSet<(String, String)> = HashSet::new();
    for link in detect_links(&body) {
        let key = (link.kind.clone(), link.target.clone());
        if !seen_links.insert(key) {
            continue;
        }
        let target_node_id = ensure_link_target_node(
            &tx,
            &link,
            project_id.as_deref(),
        )?;
        upsert_graph_edge(
            &tx,
            doc_id,
            &target_node_id,
            link.edge_kind,
            "deterministic_extract",
            0.85,
            Some(&job.job_id),
        )?;
        report.link_edges += 1;
    }

    // 3. File-mention scan.
    let mut seen_files: HashSet<String> = HashSet::new();
    for path in detect_file_mentions(&body) {
        if !seen_files.insert(path.clone()) {
            continue;
        }
        let target_id = ensure_file_node(&tx, &path, project_id.as_deref())?;
        upsert_graph_edge(
            &tx,
            doc_id,
            &target_id,
            "mentions_file",
            "deterministic_extract",
            0.7,
            Some(&job.job_id),
        )?;
        report.file_mentions += 1;
    }

    tx.commit()?;
    Ok(report)
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct ExtractReport {
    pub headings_extracted: usize,
    pub link_edges: usize,
    pub file_mentions: usize,
}

#[derive(Debug, Clone)]
struct Heading {
    kind: String,
    label: String,
    content_hash: String,
}

#[derive(Debug, Clone)]
struct LinkRef {
    kind: String,        // "note" | "file" | "agent" | "run"
    label: String,
    target: String,      // raw target (id, path, name)
    edge_kind: &'static str,
}

fn detect_headings(body: &str) -> Vec<Heading> {
    let mut out = Vec::new();
    for line in body.lines() {
        let trimmed = line.trim_start();
        if !trimmed.starts_with("##") {
            continue;
        }
        let after_hashes = trimmed.trim_start_matches('#').trim();
        // Compare prefixes case-insensitively so `## decision: …` and
        // `## DECISION: …` extract the same way `## Decision: …` does.
        // We keep the original-case `label` for display fidelity.
        let after_hashes_lower = after_hashes.to_ascii_lowercase();
        for (prefix_lower, kind) in [
            ("decision:", "decision"),
            ("decision ", "decision"),
            ("intent:", "intent"),
            ("intent ", "intent"),
            ("outcome:", "outcome"),
            ("outcome ", "outcome"),
            ("retro:", "retro"),
            ("retro ", "retro"),
            ("caveats:", "caveat"),
            ("caveats ", "caveat"),
        ] {
            if let Some(rest_offset) = after_hashes_lower.strip_prefix(prefix_lower) {
                // Compute the byte offset of `rest_offset` inside
                // `after_hashes_lower` so we can slice the original-
                // case string at the same point. ASCII prefixes mean
                // byte length matches char length here.
                let off = after_hashes_lower.len() - rest_offset.len();
                let label = after_hashes[off..].trim().to_string();
                if label.is_empty() {
                    continue;
                }
                let mut hasher = Sha256::new();
                hasher.update(kind.as_bytes());
                hasher.update(b":");
                hasher.update(label.to_lowercase().as_bytes());
                let hex = format!("{:x}", hasher.finalize());
                out.push(Heading {
                    kind: kind.to_string(),
                    label,
                    content_hash: hex[..16].to_string(),
                });
                break;
            }
        }
    }
    out
}

fn detect_links(body: &str) -> Vec<LinkRef> {
    // Hand-rolled scanner so we don't depend on a markdown crate; the
    // grammar we accept is `[label](scheme://target)`.
    let mut out = Vec::new();
    let bytes = body.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] != b'[' {
            i += 1;
            continue;
        }
        // Find matching ']'
        let label_start = i + 1;
        let Some(rel_close) = body[label_start..].find(']') else {
            break;
        };
        let label_end = label_start + rel_close;
        // Need '(' immediately after.
        if label_end + 1 >= bytes.len() || bytes[label_end + 1] != b'(' {
            i = label_end + 1;
            continue;
        }
        let target_start = label_end + 2;
        let Some(rel_close_paren) = body[target_start..].find(')') else {
            break;
        };
        let target_end = target_start + rel_close_paren;
        let label = body[label_start..label_end].to_string();
        let target_raw = body[target_start..target_end].to_string();
        if let Some(parsed) = parse_scheme_target(&label, &target_raw) {
            out.push(parsed);
        }
        i = target_end + 1;
    }
    out
}

fn parse_scheme_target(label: &str, target: &str) -> Option<LinkRef> {
    if let Some(rest) = target.strip_prefix("dome://note/") {
        return Some(LinkRef {
            kind: "note".into(),
            label: label.into(),
            target: rest.to_string(),
            edge_kind: "references",
        });
    }
    if let Some(rest) = target.strip_prefix("file://") {
        return Some(LinkRef {
            kind: "file".into(),
            label: label.into(),
            target: rest.to_string(),
            edge_kind: "mentions_file",
        });
    }
    if let Some(rest) = target.strip_prefix("agent://") {
        return Some(LinkRef {
            kind: "agent".into(),
            label: label.into(),
            target: rest.to_string(),
            edge_kind: "authored_by",
        });
    }
    if let Some(rest) = target.strip_prefix("run://") {
        return Some(LinkRef {
            kind: "run".into(),
            label: label.into(),
            target: rest.to_string(),
            edge_kind: "occurred_in_run",
        });
    }
    None
}

fn detect_file_mentions(body: &str) -> Vec<String> {
    // Path-shaped tokens with a known source extension. Whitelisted to
    // keep noise (URLs, content hashes, version strings) out.
    const EXTS: &[&str] = &[
        "swift", "rs", "ts", "tsx", "js", "jsx", "py", "go", "java",
        "kt", "rb", "c", "h", "cpp", "hpp", "m", "mm", "yaml", "yml",
        "toml", "json", "md", "sql",
    ];
    let mut out = Vec::new();
    let mut current = String::new();
    let body_chars: Vec<char> = body.chars().collect();
    for &ch in body_chars.iter() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.' | '/') {
            current.push(ch);
        } else {
            if !current.is_empty() {
                if let Some(path) = match_file_token(&current, EXTS) {
                    out.push(path);
                }
            }
            current.clear();
        }
    }
    if !current.is_empty() {
        if let Some(path) = match_file_token(&current, EXTS) {
            out.push(path);
        }
    }
    out
}

fn match_file_token(token: &str, exts: &[&str]) -> Option<String> {
    // Need a slash (so it looks like a path), and a known extension.
    if !token.contains('/') {
        return None;
    }
    let lower = token.to_ascii_lowercase();
    let ext = lower.rsplit('.').next()?;
    let bare_ext = ext.split(':').next()?;
    if !exts.contains(&bare_ext) {
        return None;
    }
    // Strip optional :line suffix for canonicalisation later, but keep
    // it on the mention itself so the agent sees the line ref.
    Some(token.to_string())
}

fn canonical_node_id(doc_id: &str, kind: &str, label: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(doc_id.as_bytes());
    hasher.update(b":");
    hasher.update(kind.as_bytes());
    hasher.update(b":");
    hasher.update(label.to_lowercase().as_bytes());
    let hex = format!("{:x}", hasher.finalize());
    format!("ent_{}", &hex[..24])
}

fn load_doc_text(conn: &Connection, doc_id: &str) -> Result<String, BtError> {
    let mut stmt = conn.prepare(
        r#"SELECT text FROM note_chunks
            WHERE doc_id = ?1
            ORDER BY scope, chunk_index"#,
    )?;
    let mut rows = stmt.query(params![doc_id])?;
    let mut out = String::new();
    while let Some(row) = rows.next()? {
        let text: String = row.get(0)?;
        out.push_str(&text);
        out.push('\n');
    }
    if out.is_empty() {
        // Fallback: pull from fts_notes.content if no chunks (e.g. a
        // doc that hasn't been re-embedded yet).
        let fts: Option<String> = conn
            .query_row(
                "SELECT content FROM fts_notes WHERE doc_id = ?1 LIMIT 1",
                params![doc_id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(text) = fts {
            return Ok(text);
        }
    }
    Ok(out)
}

fn upsert_graph_node(
    conn: &Connection,
    node_id: &str,
    kind: &str,
    ref_id: &str,
    label: &str,
    project_id: Option<&str>,
    content_hash: &str,
) -> Result<(), BtError> {
    let payload = serde_json::json!({
        "project_id": project_id,
        "extracted_at": chrono::Utc::now().to_rfc3339(),
    })
    .to_string();
    // Deterministic extractions are *high*-confidence by definition —
    // they came from explicit markdown structure (`## Decision: …`).
    // Without setting this explicitly the migration default of 0.7
    // would kick in, causing the rerank's confidence multiplier
    // (0.7×) to demote freshly-extracted entities below un-extracted
    // notes (which default to 1.0×). 0.95 leaves a small ceiling for
    // `dome_verify` to lift further.
    conn.execute(
        r#"INSERT INTO graph_nodes(
            node_id, kind, ref_id, label, secondary_label, group_key,
            search_text, sort_time, payload_json,
            content_hash, entity_version, confidence
        ) VALUES (?1, ?2, ?3, ?4, NULL, ?5, ?4, datetime('now'), ?6, ?7, 1, 0.95)
        ON CONFLICT(node_id) DO UPDATE SET
            label = excluded.label,
            search_text = excluded.search_text,
            sort_time = excluded.sort_time,
            content_hash = excluded.content_hash,
            payload_json = excluded.payload_json
        "#,
        params![
            node_id,
            kind,
            ref_id,
            label,
            project_id.unwrap_or("global"),
            payload,
            content_hash,
        ],
    )?;
    Ok(())
}

fn upsert_graph_edge(
    conn: &Connection,
    source_id: &str,
    target_id: &str,
    kind: &str,
    source_signal: &str,
    confidence: f64,
    evidence_id: Option<&str>,
) -> Result<(), BtError> {
    // Edge id is hash of (kind, source, target, signal) so the same
    // signal claiming the same edge twice doesn't multiply rows.
    let mut hasher = Sha256::new();
    hasher.update(kind.as_bytes());
    hasher.update(b":");
    hasher.update(source_id.as_bytes());
    hasher.update(b"->");
    hasher.update(target_id.as_bytes());
    hasher.update(b":");
    hasher.update(source_signal.as_bytes());
    let hex = format!("{:x}", hasher.finalize());
    let edge_id = format!("edge_{}", &hex[..24]);
    conn.execute(
        r#"INSERT INTO graph_edges(
            edge_id, kind, source_id, target_id, search_text, sort_time,
            payload_json, source_signal, signal_confidence, evidence_id
        ) VALUES (?1, ?2, ?3, ?4, ?2, datetime('now'), '{}', ?5, ?6, ?7)
        ON CONFLICT(edge_id) DO UPDATE SET
            sort_time = excluded.sort_time,
            signal_confidence = excluded.signal_confidence,
            evidence_id = excluded.evidence_id
        "#,
        params![
            edge_id,
            kind,
            source_id,
            target_id,
            source_signal,
            confidence,
            evidence_id,
        ],
    )?;
    Ok(())
}

fn ensure_link_target_node(
    conn: &Connection,
    link: &LinkRef,
    project_id: Option<&str>,
) -> Result<String, BtError> {
    // Note links point at an existing graph node iff one exists for
    // that ref_id; otherwise we create a stub node so the edge has a
    // landing point. The linker pass will resolve stubs into the real
    // node when the target lands.
    let node_id = match link.kind.as_str() {
        "note" => format!("ent_note_{}", short_hash(&link.target)),
        "file" => format!("ent_file_{}", short_hash(&link.target)),
        "agent" => format!("ent_agent_{}", short_hash(&link.target)),
        "run" => format!("ent_run_{}", short_hash(&link.target)),
        _ => format!("ent_x_{}", short_hash(&link.target)),
    };
    let kind_label = match link.kind.as_str() {
        "note" => "doc",
        "file" => "file",
        "agent" => "agent",
        "run" => "run",
        _ => "external",
    };
    let payload = serde_json::json!({
        "stub": true,
        "ref_target": link.target,
        "label_hint": link.label,
        "project_id": project_id,
    })
    .to_string();
    // Stub confidence is intentionally low — these are forward
    // references whose target hasn't materialised yet. The linker
    // pass will redirect them when the canonical node lands.
    conn.execute(
        r#"INSERT INTO graph_nodes(
            node_id, kind, ref_id, label, secondary_label, group_key,
            search_text, sort_time, payload_json,
            content_hash, entity_version, confidence
        ) VALUES (?1, ?2, ?3, ?4, 'stub', ?5, ?4, datetime('now'), ?6, ?7, 1, 0.5)
        ON CONFLICT(node_id) DO UPDATE SET
            sort_time = excluded.sort_time,
            payload_json = excluded.payload_json
        "#,
        params![
            node_id,
            kind_label,
            link.target,
            link.label,
            project_id.unwrap_or("global"),
            payload,
            short_hash(&format!("{}-{}", link.kind, link.target)),
        ],
    )?;
    Ok(node_id)
}

fn ensure_file_node(
    conn: &Connection,
    path: &str,
    project_id: Option<&str>,
) -> Result<String, BtError> {
    let node_id = format!("ent_file_{}", short_hash(path));
    let payload = serde_json::json!({
        "path": path,
        "project_id": project_id,
        "auto_extracted": true,
    })
    .to_string();
    // File mentions are deterministic — the path is literally in the
    // body. Confidence 0.9 (slightly below 0.95 of headings since
    // file refs have more potential for false positives via the
    // extension whitelist).
    conn.execute(
        r#"INSERT INTO graph_nodes(
            node_id, kind, ref_id, label, secondary_label, group_key,
            search_text, sort_time, payload_json,
            content_hash, entity_version, confidence
        ) VALUES (?1, 'file', ?2, ?2, NULL, ?3, ?2, datetime('now'), ?4, ?5, 1, 0.9)
        ON CONFLICT(node_id) DO UPDATE SET
            sort_time = excluded.sort_time
        "#,
        params![
            node_id,
            path,
            project_id.unwrap_or("global"),
            payload,
            short_hash(path),
        ],
    )?;
    Ok(node_id)
}

fn short_hash(s: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(s.as_bytes());
    let hex = format!("{:x}", hasher.finalize());
    hex[..16].to_string()
}

#[allow(dead_code)]
fn synthetic_id() -> String {
    Uuid::new_v4().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mem_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::migrations::migrate(&conn).unwrap();
        conn
    }

    fn seed_doc(conn: &Connection, doc_id: &str, body: &str) {
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            r#"INSERT INTO docs(id, topic, slug, title, user_path, agent_path,
                created_at, updated_at, user_hash, agent_hash,
                owner_scope, project_id, project_root, knowledge_kind)
               VALUES (?1, 'inbox', 'slug', 'title', 'a.md', 'b.md',
                       ?2, ?2, '0', '0', 'project', 'p1', '/tmp', 'knowledge')"#,
            params![doc_id, now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO fts_notes(doc_id, scope, content) VALUES (?1, 'user', ?2)",
            params![doc_id, body],
        )
        .unwrap();
        conn.execute(
            r#"INSERT INTO note_chunks(doc_id, scope, chunk_index, text, heading_path,
                byte_start, byte_end, embedding,
                embedding_model_id, embedding_model_version, embedding_dimension,
                embedding_pooling, embedding_instruction, embedding_source_hash)
               VALUES (?1, 'user', 0, ?2, '', 0, 0, X'00',
                       'noop', 'noop@1', 384, 'hash', '', 'h')"#,
            params![doc_id, body],
        )
        .unwrap();
    }

    fn job(doc_id: &str) -> EnrichmentJob {
        EnrichmentJob {
            job_id: "j1".into(),
            target_kind: "doc".into(),
            target_id: doc_id.into(),
            enrichment_kind: super::super::EnrichmentKind::Extract,
            project_id: Some("p1".into()),
            attempts: 1,
            payload: serde_json::Value::Null,
        }
    }

    #[test]
    fn extracts_decision_intent_outcome_headings() {
        let conn = mem_db();
        seed_doc(
            &conn,
            "d1",
            "## Decision: replace JWT with cookies\nbody\n## Intent: ship by Friday\n## Outcome: shipped Tuesday",
        );
        let report = run(&conn, &job("d1")).unwrap();
        assert_eq!(report.headings_extracted, 3);
        let kinds: Vec<String> = conn
            .prepare("SELECT kind FROM graph_nodes WHERE ref_id = ?1 ORDER BY kind")
            .unwrap()
            .query_map(["d1"], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(kinds.contains(&"decision".to_string()));
        assert!(kinds.contains(&"intent".to_string()));
        assert!(kinds.contains(&"outcome".to_string()));
    }

    #[test]
    fn extracts_dome_note_link_as_references_edge() {
        let conn = mem_db();
        seed_doc(
            &conn,
            "d1",
            "see [old retro](dome://note/abc-123) for context",
        );
        run(&conn, &job("d1")).unwrap();
        let kinds: Vec<String> = conn
            .prepare("SELECT kind FROM graph_edges WHERE source_id = ?1")
            .unwrap()
            .query_map(["d1"], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(kinds.contains(&"references".to_string()));
    }

    #[test]
    fn extracts_file_mentions() {
        let conn = mem_db();
        seed_doc(
            &conn,
            "d1",
            "fix the bug in Sources/Auth/Session.swift:42 and check tests/foo.rs",
        );
        let report = run(&conn, &job("d1")).unwrap();
        assert!(report.file_mentions >= 2, "got {report:?}");
    }

    #[test]
    fn extractor_is_idempotent() {
        let conn = mem_db();
        seed_doc(&conn, "d1", "## Decision: choose Rust");
        run(&conn, &job("d1")).unwrap();
        let after_first: i64 = conn
            .query_row("SELECT COUNT(*) FROM graph_nodes", [], |r| r.get(0))
            .unwrap();
        run(&conn, &job("d1")).unwrap();
        let after_second: i64 = conn
            .query_row("SELECT COUNT(*) FROM graph_nodes", [], |r| r.get(0))
            .unwrap();
        assert_eq!(after_first, after_second);
    }

    #[test]
    fn extractor_emits_provenance_on_edges() {
        let conn = mem_db();
        seed_doc(&conn, "d1", "## Decision: pick Rust\nsee Sources/Foo.swift");
        run(&conn, &job("d1")).unwrap();
        let signal: String = conn
            .query_row(
                "SELECT source_signal FROM graph_edges WHERE source_id = ?1 LIMIT 1",
                ["d1"],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(signal, "deterministic_extract");
    }

    #[test]
    fn detect_links_skips_unknown_schemes() {
        let body = "see [home](https://example.com) and [note](dome://note/x)";
        let links = detect_links(body);
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].target, "x");
    }

    #[test]
    fn detect_file_mentions_filters_extensions() {
        let m = detect_file_mentions("path/to/foo.swift and word.notext and a/b/c.rs");
        assert!(m.iter().any(|s| s.contains("foo.swift")));
        assert!(m.iter().any(|s| s.contains("c.rs")));
        assert!(!m.iter().any(|s| s.contains("word.notext")));
    }
}
