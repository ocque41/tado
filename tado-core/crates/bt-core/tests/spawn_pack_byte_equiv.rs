//! Phase 4 — pin the spawn-pack contract bytes.
//!
//! The Swift composer and the Rust pack engine must produce
//! byte-identical output for the same input. This test stores
//! "golden" outputs as expected strings and runs the Rust composer
//! against the same fixtures the Swift composer is expected to
//! match. The Swift side ships a mirror test in
//! `Sources/Tado/Tests/` that compares against the same goldens —
//! when both are green, byte-equivalence holds.
//!
//! Use `cargo test --test spawn_pack_byte_equiv -- --nocapture` to
//! print the actual rendered output if you need to update goldens.

use bt_core::context::{compose_spawn_preamble, RecentNote, SpawnPackContext};
use chrono::{DateTime, Utc};

fn t(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
}

fn now() -> DateTime<Utc> {
    t("2026-04-27T12:00:00Z")
}

#[test]
fn fixture_solo_agent_no_project() {
    let ctx = SpawnPackContext {
        agent_name: Some("solo".into()),
        ..Default::default()
    };
    let out = compose_spawn_preamble(&ctx, now()).unwrap();

    let expected = "<!-- tado:context:begin -->\n## Session context\n\n\
        - **you are**: `solo` (agent definition: `.claude/agents/solo.md`)\n\n\
        ### Dome retrieval contract\n\
        - Before architecture decisions, unfamiliar edits, team handoffs, stale context, or completion claims, query Dome first.\n\
        - Use `dome_graph_query` to find related notes, tasks, runs, context packs, and agent activity.\n\
        - Use `dome_context_resolve` for compact cited context; use `dome_context_compact` when the pack is missing or stale.\n\
        - Cite Dome note ids, context pack ids, or graph node ids when prior knowledge affects your answer.\n\
        - If retrieval is unavailable, say that clearly before proceeding.\n\n\
        <!-- tado:context:end -->";
    assert_eq!(out, expected);
}

#[test]
fn fixture_full_team_with_recent_notes() {
    let ctx = SpawnPackContext {
        agent_name: Some("backend".into()),
        project_name: Some("Tado".into()),
        project_id: Some("ABCDEF12-3456-7890-ABCD-EF1234567890".into()),
        project_root: Some("/Users/miguel/Documents/tado".into()),
        team_name: Some("core".into()),
        teammates: vec!["frontend".into(), "backend".into(), "infra".into()],
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
    };
    let out = compose_spawn_preamble(&ctx, now()).unwrap();

    let expected = "<!-- tado:context:begin -->\n## Session context\n\n\
        - **you are**: `backend` (agent definition: `.claude/agents/backend.md`)\n\n\
        - **project**: Tado\n\
        - **root**: `/Users/miguel/Documents/tado`\n\
        - **dome topic**: `project-abcdef12`\n\n\
        - **team**: core\n\
        - **teammates**: `frontend`, `infra`\n\n\
        ### Recent project notes (topic `project-abcdef12`)\n  \
          - `Auth refactor decision` (30m ago)\n  \
          - `Storage relocator` (1d ago)\n\n\
        Use `dome_search` and `dome_read` for the cited details before relying on these notes.\n\n\
        ### Dome retrieval contract\n\
        - Before architecture decisions, unfamiliar edits, team handoffs, stale context, or completion claims, query Dome first.\n\
        - Use `dome_graph_query` to find related notes, tasks, runs, context packs, and agent activity.\n\
        - Use `dome_context_resolve` for compact cited context; use `dome_context_compact` when the pack is missing or stale.\n\
        - Cite Dome note ids, context pack ids, or graph node ids when prior knowledge affects your answer.\n\
        - If retrieval is unavailable, say that clearly before proceeding.\n\
        - For this project, start with topic `project-abcdef12` when using `dome_search`.\n\n\
        <!-- tado:context:end -->";
    assert_eq!(out, expected);
}

#[test]
fn fixture_project_only_no_team_no_notes() {
    let ctx = SpawnPackContext {
        project_name: Some("Tado".into()),
        project_id: Some("00000000-0000-0000-0000-000000000abc".into()),
        ..Default::default()
    };
    let out = compose_spawn_preamble(&ctx, now()).unwrap();
    assert!(out.contains("- **project**: Tado"));
    assert!(out.contains("`project-00000000`"));
    assert!(!out.contains("you are"));
    assert!(!out.contains("Recent project notes"));
}

#[test]
fn fixture_marker_contract_is_locked() {
    // No matter what, the begin / end markers + section header are
    // byte-stable. This test pins the bytes — every bootstrapped
    // project's agent prompt depends on this.
    let ctx = SpawnPackContext::default();
    let out = compose_spawn_preamble(&ctx, now()).unwrap();
    assert!(out.starts_with("<!-- tado:context:begin -->\n## Session context\n\n"));
    assert!(out.ends_with("\n\n<!-- tado:context:end -->"));
}
