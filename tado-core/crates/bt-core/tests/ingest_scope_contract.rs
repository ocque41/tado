//! Pin the contract: `vault_ingest_path` must persist
//! `(owner_scope, project_id)` exactly as passed in. This is the test
//! that prevents v0.10's "everything ingested global" foot-gun from
//! ever returning silently — if a future refactor drops scope on the
//! floor, this fails before it ships.
//!
//! Lives as an integration test (not a `#[cfg(test)]` unit) so it
//! exercises the public API a Swift caller would hit, and so the
//! coverage is greppable from a release-checklist standpoint.

use bt_core::{Actor, CoreService};
use std::env;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_root(label: &str) -> PathBuf {
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    let pid = std::process::id();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let n = COUNTER.fetch_add(1, Ordering::SeqCst);
    let dir = env::temp_dir().join(format!("bt-core-{label}-{pid}-{nanos}-{n}"));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn ui_actor() -> Actor {
    Actor::UserUi {
        session_id: "test-ui".into(),
    }
}

#[test]
fn ingest_persists_scope_for_project_and_global() {
    let vault = temp_root("ingest-scope-vault");
    let project_src = temp_root("ingest-scope-source-project");
    let global_src = temp_root("ingest-scope-source-global");

    fs::write(project_src.join("alpha.rs"), "fn alpha() {}").unwrap();
    fs::write(global_src.join("beta.rs"), "fn beta() {}").unwrap();

    let svc = CoreService::new();
    svc.open_vault(&vault).unwrap();
    let actor = ui_actor();

    // 1. Project scope — must persist owner_scope='project' + project_id
    let res = svc
        .vault_ingest_path(
            &actor,
            &project_src,
            Some("codebase"),
            "project",
            Some("pid-AAA"),
            Some(project_src.as_path()),
        )
        .unwrap();
    assert_eq!(
        res.get("created").and_then(|v| v.as_i64()),
        Some(1),
        "expected one doc created from one .rs file"
    );

    // 2. Global scope — must persist owner_scope='global' + project_id NULL
    let res = svc
        .vault_ingest_path(&actor, &global_src, Some("codebase-global"), "global", None, None)
        .unwrap();
    assert_eq!(res.get("created").and_then(|v| v.as_i64()), Some(1));

    // 3. Verify both rows directly from the schema we expect callers to read.
    let dome_db = vault.join(".bt").join("index.sqlite");
    let conn = rusqlite::Connection::open(&dome_db).unwrap();
    let mut stmt = conn
        .prepare("SELECT topic, owner_scope, project_id FROM docs ORDER BY topic")
        .unwrap();
    let rows: Vec<(String, String, Option<String>)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();

    assert_eq!(rows.len(), 2, "expected exactly two ingested docs");
    let (project_row, global_row) = match rows.as_slice() {
        [a, b] if a.0 == "codebase" => (a, b),
        [a, b] if b.0 == "codebase" => (b, a),
        _ => panic!("missing one of the expected topics: {:?}", rows),
    };
    assert_eq!(project_row.0, "codebase");
    assert_eq!(project_row.1, "project");
    assert_eq!(project_row.2.as_deref(), Some("pid-AAA"));
    assert_eq!(global_row.0, "codebase-global");
    assert_eq!(global_row.1, "global");
    assert!(
        global_row.2.is_none(),
        "global owner_scope must persist project_id as NULL"
    );

    let _ = fs::remove_dir_all(&vault);
    let _ = fs::remove_dir_all(&project_src);
    let _ = fs::remove_dir_all(&global_src);
}

#[test]
fn purge_only_targets_matching_scope() {
    let vault = temp_root("purge-scope-vault");
    let project_src = temp_root("purge-scope-source-project");
    let global_src = temp_root("purge-scope-source-global");

    fs::write(project_src.join("p.rs"), "fn p() {}").unwrap();
    fs::write(global_src.join("g.rs"), "fn g() {}").unwrap();

    let svc = CoreService::new();
    svc.open_vault(&vault).unwrap();
    let actor = ui_actor();

    // Two docs at the SAME topic, different scopes — exact replay of
    // the v0.10 production state where 357 codebase rows landed
    // global while project-scoped notes coexisted.
    svc.vault_ingest_path(&actor, &global_src, Some("codebase"), "global", None, None)
        .unwrap();
    svc.vault_ingest_path(
        &actor,
        &project_src,
        Some("codebase"),
        "project",
        Some("pid-Z"),
        Some(project_src.as_path()),
    )
    .unwrap();

    // Read-only count helper sees exactly the global row.
    let count = svc
        .vault_purge_topic_scope_count("codebase", "global", None)
        .unwrap();
    assert_eq!(count.get("count").and_then(|v| v.as_i64()), Some(1));

    // Purge global. Project doc must survive.
    let purged = svc
        .vault_purge_topic_scope(&actor, "codebase", "global", None)
        .unwrap();
    assert_eq!(purged.get("purged").and_then(|v| v.as_i64()), Some(1));

    let dome_db = vault.join(".bt").join("index.sqlite");
    let conn = rusqlite::Connection::open(&dome_db).unwrap();
    let surviving: Vec<(String, String, Option<String>)> = conn
        .prepare("SELECT topic, owner_scope, project_id FROM docs WHERE topic='codebase'")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(surviving.len(), 1, "project doc must survive");
    assert_eq!(surviving[0].1, "project");
    assert_eq!(surviving[0].2.as_deref(), Some("pid-Z"));

    // Re-running the purge is a clean no-op.
    let purged = svc
        .vault_purge_topic_scope(&actor, "codebase", "global", None)
        .unwrap();
    assert_eq!(purged.get("purged").and_then(|v| v.as_i64()), Some(0));

    let _ = fs::remove_dir_all(&vault);
    let _ = fs::remove_dir_all(&project_src);
    let _ = fs::remove_dir_all(&global_src);
}
