//! Rust implementation of the spawn-time preamble composer.
//!
//! Byte-equivalent to `Sources/Tado/Extensions/Dome/DomeContextPreamble.swift`
//! once Phase 4's Swift change adopts the deterministic relative-time
//! formatter shared by both implementations
//! ([`crate::context::relative::format_relative_ago`]).
//!
//! The composer is *pure* — input goes in, string comes out. No DB
//! reads. The recent-notes fragment takes pre-fetched [`RecentNote`]
//! values; callers pull them from `dome_search` (Swift today,
//! [`crate::service::CoreService::spawn_pack_recent_notes`] in Rust).
//!
//! Output shape (must remain byte-stable):
//!
//! ```text
//! <!-- tado:context:begin -->
//! ## Session context
//!
//! <fragments separated by "\n\n">
//!
//! <!-- tado:context:end -->
//! ```

use crate::context::relative::format_relative_ago;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub const SPAWN_PACK_MAX_CHARS: usize = 6000;

/// Per-spawn input. Mirrors `DomeContextPreamble.Context` field-for-field.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SpawnPackContext {
    pub agent_name: Option<String>,
    pub project_name: Option<String>,
    pub project_id: Option<String>,
    pub project_root: Option<String>,
    pub team_name: Option<String>,
    pub teammates: Vec<String>,
    pub recent_notes: Vec<RecentNote>,
}

/// One row consumed by the recent-notes fragment.
///
/// Pre-sorted by caller — descending by the timestamp the agent
/// should display, which matches what the Swift composer's
/// `note.sortTimestamp` field returned.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecentNote {
    pub title: String,
    /// RFC3339 timestamp of the last update / reference. The composer
    /// passes this through [`format_relative_ago`] when rendering.
    pub display_at: Option<DateTime<Utc>>,
}

/// Compose the preamble. Returns `None` when there's nothing useful
/// to say (matches Swift behaviour for raw terminal spawns).
pub fn compose_spawn_preamble(ctx: &SpawnPackContext, now: DateTime<Utc>) -> Option<String> {
    let mut fragments: Vec<String> = Vec::new();

    if let Some(s) = identity_fragment(ctx) {
        fragments.push(s);
    }
    if let Some(s) = project_fragment(ctx) {
        fragments.push(s);
    }
    if let Some(s) = team_fragment(ctx) {
        fragments.push(s);
    }
    if let Some(s) = recent_notes_fragment(ctx, now) {
        fragments.push(s);
    }
    fragments.push(retrieval_contract_fragment(ctx));

    if fragments.is_empty() {
        return None;
    }
    let body = fragments.join("\n\n");
    let wrapped = format!(
        "<!-- tado:context:begin -->\n## Session context\n\n{body}\n\n<!-- tado:context:end -->"
    );
    if wrapped.chars().count() <= SPAWN_PACK_MAX_CHARS {
        Some(wrapped)
    } else {
        Some(wrapped.chars().take(SPAWN_PACK_MAX_CHARS).collect())
    }
}

fn identity_fragment(ctx: &SpawnPackContext) -> Option<String> {
    let agent = ctx.agent_name.as_deref()?.trim();
    if agent.is_empty() {
        return None;
    }
    Some(format!(
        "- **you are**: `{agent}` (agent definition: `.claude/agents/{agent}.md`)"
    ))
}

fn project_fragment(ctx: &SpawnPackContext) -> Option<String> {
    let name = ctx.project_name.as_deref()?.trim();
    if name.is_empty() {
        return None;
    }
    let mut lines = vec![format!("- **project**: {name}")];
    if let Some(root) = ctx.project_root.as_deref() {
        lines.push(format!("- **root**: `{root}`"));
    }
    if let Some(id) = ctx.project_id.as_deref() {
        lines.push(format!("- **dome topic**: `project-{}`", short_project_id(id)));
    }
    Some(lines.join("\n"))
}

fn team_fragment(ctx: &SpawnPackContext) -> Option<String> {
    let team = ctx.team_name.as_deref()?.trim();
    if team.is_empty() {
        return None;
    }
    let mut lines = vec![format!("- **team**: {team}")];
    let others: Vec<&str> = ctx
        .teammates
        .iter()
        .filter(|n| {
            // Match Swift behaviour: filter out our own name.
            ctx.agent_name.as_deref() != Some(n.as_str())
        })
        .map(|s| s.as_str())
        .collect();
    if !others.is_empty() {
        lines.push(format!(
            "- **teammates**: {}",
            others.iter().map(|n| format!("`{n}`")).collect::<Vec<_>>().join(", ")
        ));
    }
    Some(lines.join("\n"))
}

fn recent_notes_fragment(ctx: &SpawnPackContext, now: DateTime<Utc>) -> Option<String> {
    let project_id = ctx.project_id.as_deref()?;
    if ctx.recent_notes.is_empty() {
        return None;
    }
    let topic = format!("project-{}", short_project_id(project_id));
    let limit = ctx.recent_notes.len().min(5);
    let bullets: Vec<String> = ctx.recent_notes[..limit]
        .iter()
        .map(|note| match note.display_at {
            Some(ts) => format!("  - `{}` ({})", note.title, format_relative_ago(ts, now)),
            None => format!("  - `{}`", note.title),
        })
        .collect();
    Some(format!(
        "### Recent project notes (topic `{topic}`)\n{}\n\nUse `dome_search` and `dome_read` for the cited details before relying on these notes.",
        bullets.join("\n"),
    ))
}

/// Public so callers (and the Swift mirror) can produce the exact
/// retrieval-contract block.
pub fn retrieval_contract_fragment(ctx: &SpawnPackContext) -> String {
    let topic = ctx
        .project_id
        .as_deref()
        .map(|id| format!("project-{}", short_project_id(id)));
    let mut lines: Vec<String> = vec![
        "### Dome retrieval contract".to_string(),
        "- Before architecture decisions, unfamiliar edits, team handoffs, stale context, or completion claims, query Dome first.".to_string(),
        "- Use `dome_graph_query` to find related notes, tasks, runs, context packs, and agent activity.".to_string(),
        "- Use `dome_context_resolve` for compact cited context; use `dome_context_compact` when the pack is missing or stale.".to_string(),
        "- Cite Dome note ids, context pack ids, or graph node ids when prior knowledge affects your answer.".to_string(),
        "- If retrieval is unavailable, say that clearly before proceeding.".to_string(),
    ];
    if let Some(topic) = topic {
        lines.push(format!(
            "- For this project, start with topic `{topic}` when using `dome_search`."
        ));
    }
    lines.join("\n")
}

/// First 8 chars of a UUID lowercased — matches the Swift
/// `id.uuidString.prefix(8).lowercased()` convention used in
/// `DomeProjectMemory.topic(for:)` and `DomeContextPreamble.projectFragment`.
fn short_project_id(id: &str) -> String {
    let mut out = String::with_capacity(8);
    for c in id.chars() {
        if c == '-' {
            continue;
        }
        if out.len() >= 8 {
            break;
        }
        out.push(c.to_ascii_lowercase());
    }
    // If id is shorter than 8 hex chars (test fixtures) we still
    // honor it. Pad never — agents see what we actually have.
    out.chars().take(8).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn t(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    fn ctx_full() -> SpawnPackContext {
        SpawnPackContext {
            agent_name: Some("backend".into()),
            project_name: Some("Tado".into()),
            project_id: Some("11111111-2222-3333-4444-555555555555".into()),
            project_root: Some("/Users/miguel/Documents/tado".into()),
            team_name: Some("core".into()),
            teammates: vec!["frontend".into(), "backend".into()],
            recent_notes: vec![
                RecentNote {
                    title: "Auth refactor decision".into(),
                    display_at: Some(t("2026-04-27T11:30:00Z")),
                },
                RecentNote {
                    title: "Storage relocator".into(),
                    display_at: Some(t("2026-04-26T12:00:00Z")),
                },
            ],
        }
    }

    #[test]
    fn full_context_renders_all_fragments_in_canonical_order() {
        let ctx = ctx_full();
        let out = compose_spawn_preamble(&ctx, t("2026-04-27T12:00:00Z")).unwrap();
        assert!(out.starts_with("<!-- tado:context:begin -->"));
        assert!(out.ends_with("<!-- tado:context:end -->"));
        // Order assertion: identity → project → team → notes → contract.
        let agent_idx = out.find("you are").unwrap();
        let project_idx = out.find("project**: Tado").unwrap();
        let team_idx = out.find("team**: core").unwrap();
        let notes_idx = out.find("Recent project notes").unwrap();
        let contract_idx = out.find("Dome retrieval contract").unwrap();
        assert!(agent_idx < project_idx);
        assert!(project_idx < team_idx);
        assert!(team_idx < notes_idx);
        assert!(notes_idx < contract_idx);
    }

    #[test]
    fn empty_context_returns_none_unless_contract_alone_satisfies() {
        // Even a fully empty context yields the contract fragment, so
        // `compose_spawn_preamble` returns Some — matches Swift's
        // behavior of always emitting the contract section if any
        // fragment exists. Verify the wrapper still applies.
        let ctx = SpawnPackContext::default();
        let out = compose_spawn_preamble(&ctx, t("2026-04-27T12:00:00Z")).unwrap();
        assert!(out.contains("Dome retrieval contract"));
        assert!(!out.contains("you are"));
        assert!(!out.contains("project**:"));
    }

    #[test]
    fn agent_only_renders_identity_plus_contract() {
        let ctx = SpawnPackContext {
            agent_name: Some("solo".into()),
            ..Default::default()
        };
        let out = compose_spawn_preamble(&ctx, t("2026-04-27T12:00:00Z")).unwrap();
        assert!(out.contains("`solo`"));
        assert!(!out.contains("Recent project notes"));
        assert!(out.contains("Dome retrieval contract"));
    }

    #[test]
    fn teammates_filter_out_self() {
        let ctx = SpawnPackContext {
            agent_name: Some("backend".into()),
            team_name: Some("core".into()),
            teammates: vec!["backend".into(), "frontend".into()],
            ..Default::default()
        };
        let out = compose_spawn_preamble(&ctx, t("2026-04-27T12:00:00Z")).unwrap();
        assert!(out.contains("`frontend`"));
        // "backend" appears as the agent name but should not show
        // up as a teammate listing.
        let teammates_section = out
            .lines()
            .find(|l| l.contains("teammates"))
            .unwrap_or_default();
        assert!(!teammates_section.contains("`backend`"));
    }

    #[test]
    fn recent_notes_render_relative_times() {
        let ctx = ctx_full();
        let out = compose_spawn_preamble(&ctx, t("2026-04-27T12:00:00Z")).unwrap();
        assert!(out.contains("`Auth refactor decision` (30m ago)"));
        assert!(out.contains("`Storage relocator` (1d ago)"));
    }

    #[test]
    fn recent_notes_fragment_capped_at_5() {
        let mut ctx = ctx_full();
        ctx.recent_notes = (0..10)
            .map(|i| RecentNote {
                title: format!("note-{i}"),
                display_at: Some(t("2026-04-27T11:55:00Z") - Duration::minutes(i as i64)),
            })
            .collect();
        let out = compose_spawn_preamble(&ctx, t("2026-04-27T12:00:00Z")).unwrap();
        let note_count = out.matches("`note-").count();
        assert_eq!(note_count, 5);
    }

    #[test]
    fn project_topic_uses_first_8_hex_chars() {
        let ctx = SpawnPackContext {
            project_id: Some("ABCDEF12-3456-7890-ABCD-EF1234567890".into()),
            project_name: Some("X".into()),
            ..Default::default()
        };
        let out = compose_spawn_preamble(&ctx, t("2026-04-27T12:00:00Z")).unwrap();
        assert!(out.contains("`project-abcdef12`"));
    }

    #[test]
    fn output_is_under_max_chars_for_typical_input() {
        let ctx = ctx_full();
        let out = compose_spawn_preamble(&ctx, t("2026-04-27T12:00:00Z")).unwrap();
        assert!(out.chars().count() <= SPAWN_PACK_MAX_CHARS);
    }

    #[test]
    fn output_truncates_at_max_chars() {
        let mut ctx = ctx_full();
        // Stuff a giant project name to push past the cap.
        ctx.project_name = Some("X".repeat(SPAWN_PACK_MAX_CHARS * 2));
        let out = compose_spawn_preamble(&ctx, t("2026-04-27T12:00:00Z")).unwrap();
        assert_eq!(out.chars().count(), SPAWN_PACK_MAX_CHARS);
    }

    #[test]
    fn marker_contract_is_byte_stable() {
        // The exact open + close + section header is what every
        // bootstrapped project relies on; pin the bytes.
        let ctx = SpawnPackContext::default();
        let out = compose_spawn_preamble(&ctx, t("2026-04-27T12:00:00Z")).unwrap();
        assert!(out.starts_with("<!-- tado:context:begin -->\n## Session context\n\n"));
        assert!(out.ends_with("\n\n<!-- tado:context:end -->"));
    }
}
