use chrono::Utc;
use tado_runtime::db::{RuntimeDb, SessionRecord, LATEST_SCHEMA_VERSION};
use tado_runtime::profile::{sanitize_profile, ProfilePaths};

#[test]
fn profile_paths_are_isolated() {
    let cli = ProfilePaths::new("cli", "/tmp/tado-runtime-test", "/tmp/tado-sock-test");
    let team = ProfilePaths::new("team", "/tmp/tado-runtime-test", "/tmp/tado-sock-test");
    assert_ne!(cli.db_path, team.db_path);
    assert_ne!(cli.socket_path, team.socket_path);
}

#[test]
fn profile_names_are_path_safe() {
    assert_eq!(sanitize_profile("main/project").unwrap(), "main-project");
}

#[test]
fn db_migration_can_run_more_than_once() {
    let dir = tempfile::tempdir().unwrap();
    let db = RuntimeDb::open(&dir.path().join("runtime.sqlite")).unwrap();
    db.migrate().unwrap();
    assert_eq!(db.schema_version().unwrap(), LATEST_SCHEMA_VERSION);
}

#[test]
fn db_persists_runtime_metadata_and_kanban_lane() {
    let dir = tempfile::tempdir().unwrap();
    let db = RuntimeDb::open(&dir.path().join("runtime.sqlite")).unwrap();
    let now = Utc::now().to_rfc3339();
    let record = SessionRecord {
        id: "s1".into(),
        title: "runtime worker".into(),
        kind: "pty".into(),
        status: "running".into(),
        engine: Some("shell".into()),
        command: "/bin/zsh".into(),
        args: vec!["-l".into()],
        cwd: Some("/tmp".into()),
        project_id: Some("project".into()),
        project_root: Some("/tmp/project".into()),
        agent_name: Some("backend".into()),
        team_name: Some("core".into()),
        grid_row: Some(1),
        grid_col: Some(2),
        pid: Some(123),
        created_at: now.clone(),
        updated_at: now,
        exit_code: None,
        cowork_result_path: None,
    };
    db.insert_session(&record).unwrap();
    let stored = db.get_session("s1").unwrap().unwrap();
    assert_eq!(stored.agent_name.as_deref(), Some("backend"));
    assert_eq!(stored.team_name.as_deref(), Some("core"));
    assert_eq!(stored.grid_row, Some(1));
    assert_eq!(stored.grid_col, Some(2));

    db.add_kanban_column("review", "Review", "custom").unwrap();
    db.move_kanban_card(&stored, "review").unwrap();
    let lanes = db.kanban_card_lanes().unwrap();
    assert_eq!(lanes.get("s1").map(String::as_str), Some("review"));
}
