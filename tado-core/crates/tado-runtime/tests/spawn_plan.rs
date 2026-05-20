use tado_runtime::spawn::{plan_spawn, sanitize_flags, Engine, SpawnRequest};

#[test]
fn shell_plan_uses_login_zsh() {
    let plan = plan_spawn(SpawnRequest {
        engine: Engine::Shell,
        prompt: Some("echo hi".into()),
        command: None,
        args: Vec::new(),
        title: None,
        cwd: Some("/tmp".into()),
        project_id: None,
        project_root: None,
        env: Vec::new(),
        flags: Vec::new(),
        agent_name: None,
        team_name: None,
        cols: 120,
        rows: 36,
    })
    .unwrap();
    assert_eq!(plan.executable, "/bin/zsh");
    assert_eq!(plan.args, vec!["-l", "-c", "echo hi"]);
    assert_eq!(plan.cwd.as_deref(), Some("/tmp"));
}

#[test]
fn auto_flag_sentinels_do_not_reach_engine_command() {
    assert_eq!(
        sanitize_flags(vec![
            "--model".into(),
            "auto".into(),
            "-c".into(),
            "model_reasoning_effort=auto".into(),
            "--effort".into(),
            "high".into(),
        ]),
        vec!["--effort".to_string(), "high".to_string()]
    );
}
