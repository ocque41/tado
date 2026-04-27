use crate::error::BtError;
use rusqlite::{Connection, OptionalExtension};

pub const LATEST_SCHEMA_VERSION: i32 = 24;

/// Apply SQLite schema migrations.
///
/// We use `PRAGMA user_version` for DB schema versioning.
///
/// Reliability goals:
/// - safe to call on every open
/// - safe on partially-initialized DBs
/// - idempotent (migrations use IF NOT EXISTS / guarded ALTERs)
pub fn migrate(conn: &Connection) -> Result<i32, BtError> {
    let mut v: i32 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;

    if v < 1 {
        migration_1(conn)?;
        set_user_version(conn, 1)?;
        v = 1;
    }

    if v < 2 {
        migration_2(conn)?;
        set_user_version(conn, 2)?;
        v = 2;
    }

    if v < 3 {
        migration_3(conn)?;
        set_user_version(conn, 3)?;
        v = 3;
    }

    if v < 4 {
        migration_4(conn)?;
        set_user_version(conn, 4)?;
        v = 4;
    }

    if v < 5 {
        migration_5(conn)?;
        set_user_version(conn, 5)?;
        v = 5;
    }

    if v < 6 {
        migration_6(conn)?;
        set_user_version(conn, 6)?;
        v = 6;
    }

    if v < 7 {
        migration_7(conn)?;
        set_user_version(conn, 7)?;
        v = 7;
    }

    if v < 8 {
        migration_8(conn)?;
        set_user_version(conn, 8)?;
        v = 8;
    }

    if v < 9 {
        migration_9(conn)?;
        set_user_version(conn, 9)?;
        v = 9;
    }

    if v < 10 {
        migration_10(conn)?;
        set_user_version(conn, 10)?;
        v = 10;
    }

    if v < 11 {
        migration_11(conn)?;
        set_user_version(conn, 11)?;
        v = 11;
    }

    if v < 12 {
        migration_12(conn)?;
        set_user_version(conn, 12)?;
        v = 12;
    }

    if v < 13 {
        migration_13(conn)?;
        set_user_version(conn, 13)?;
        v = 13;
    }

    if v < 14 {
        migration_14(conn)?;
        set_user_version(conn, 14)?;
        v = 14;
    }

    if v < 15 {
        migration_15(conn)?;
        set_user_version(conn, 15)?;
        v = 15;
    }

    if v < 16 {
        migration_16(conn)?;
        set_user_version(conn, 16)?;
        v = 16;
    }

    if v < 17 {
        migration_17(conn)?;
        set_user_version(conn, 17)?;
        v = 17;
    }

    if v < 18 {
        migration_18(conn)?;
        set_user_version(conn, 18)?;
        v = 18;
    }

    if v < 19 {
        migration_19(conn)?;
        set_user_version(conn, 19)?;
        v = 19;
    }

    if v < 20 {
        migration_20(conn)?;
        set_user_version(conn, 20)?;
        v = 20;
    }

    if v < 21 {
        migration_21(conn)?;
        set_user_version(conn, 21)?;
        v = 21;
    }

    if v < 22 {
        migration_22(conn)?;
        set_user_version(conn, 22)?;
        v = 22;
    }

    if v < 23 {
        migration_23(conn)?;
        set_user_version(conn, 23)?;
        v = 23;
    }

    if v < 24 {
        migration_24(conn)?;
        set_user_version(conn, 24)?;
        v = 24;
    }

    Ok(v)
}

fn set_user_version(conn: &Connection, v: i32) -> Result<(), BtError> {
    conn.pragma_update(None, "user_version", v)?;
    Ok(())
}

fn migration_1(conn: &Connection) -> Result<(), BtError> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS docs (
            id TEXT PRIMARY KEY,
            topic TEXT NOT NULL,
            slug TEXT NOT NULL,
            title TEXT NOT NULL,
            user_path TEXT NOT NULL,
            agent_path TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            user_hash TEXT,
            agent_hash TEXT
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_docs_topic_slug ON docs(topic, slug);

        CREATE TABLE IF NOT EXISTS doc_meta (
            doc_id TEXT PRIMARY KEY,
            tags_json TEXT NOT NULL,
            links_out_json TEXT NOT NULL,
            status TEXT,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(doc_id) REFERENCES docs(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            priority TEXT,
            due_at TEXT,
            topic TEXT,
            doc_id TEXT,
            created_at TEXT NOT NULL,
            completed_at TEXT
        );

        CREATE TABLE IF NOT EXISTS suggestions (
            id TEXT PRIMARY KEY,
            doc_id TEXT NOT NULL,
            format TEXT NOT NULL,
            patch TEXT NOT NULL,
            summary TEXT NOT NULL,
            status TEXT NOT NULL,
            created_by TEXT NOT NULL,
            created_at TEXT NOT NULL,
            applied_at TEXT,
            rejected_at TEXT
        );

        CREATE TABLE IF NOT EXISTS audit (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            actor_type TEXT NOT NULL,
            actor_id TEXT NOT NULL,
            action TEXT NOT NULL,
            args_hash TEXT NOT NULL,
            doc_id TEXT,
            result TEXT NOT NULL,
            details_json TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS links (
            from_doc_id TEXT NOT NULL,
            to_ref TEXT NOT NULL,
            kind TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS agent_activity (
            doc_id TEXT NOT NULL,
            token_id TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            PRIMARY KEY(doc_id, token_id)
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS fts_notes USING fts5(
            doc_id UNINDEXED,
            scope,
            content,
            tokenize='porter unicode61'
        );
        "#,
    )?;
    Ok(())
}

fn migration_2(conn: &Connection) -> Result<(), BtError> {
    // Runs + artifacts (observability)
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS runs (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            status TEXT NOT NULL,
            summary TEXT NOT NULL,
            task_id TEXT,
            doc_id TEXT,
            created_at TEXT NOT NULL,
            started_at TEXT,
            ended_at TEXT,
            error_kind TEXT,
            error_message TEXT,
            openclaw_session_id TEXT,
            openclaw_agent_name TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_runs_task_id ON runs(task_id);
        CREATE INDEX IF NOT EXISTS idx_runs_doc_id ON runs(doc_id);
        CREATE INDEX IF NOT EXISTS idx_runs_status_created ON runs(status, created_at);

        CREATE TABLE IF NOT EXISTS run_artifacts (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            path TEXT,
            content_inline TEXT,
            sha256 TEXT,
            meta_json TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY(run_id) REFERENCES runs(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_run_artifacts_run_id ON run_artifacts(run_id);
        "#,
    )?;

    // Link audit rows to runs (optional column). Guarded ALTER for existing DBs.
    if !table_has_column(conn, "audit", "run_id")? {
        conn.execute("ALTER TABLE audit ADD COLUMN run_id TEXT", [])?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_audit_run_id ON audit(run_id)",
            [],
        )?;
    }

    Ok(())
}

fn migration_3(conn: &Connection) -> Result<(), BtError> {
    // Durable event log (at-least-once) for connectors.
    // `dedupe_key` is reserved for idempotent emissions (e.g., scheduler).
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS events (
            event_id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            type TEXT NOT NULL,
            actor_type TEXT NOT NULL,
            actor_id TEXT NOT NULL,
            doc_id TEXT,
            run_id TEXT,
            payload_json TEXT NOT NULL,
            dedupe_key TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
        CREATE INDEX IF NOT EXISTS idx_events_type_event_id ON events(type, event_id);
        CREATE INDEX IF NOT EXISTS idx_events_doc_id_event_id ON events(doc_id, event_id);
        CREATE INDEX IF NOT EXISTS idx_events_run_id_event_id ON events(run_id, event_id);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_events_dedupe_key_unique ON events(dedupe_key)
            WHERE dedupe_key IS NOT NULL;
        "#,
    )?;

    Ok(())
}

fn migration_4(conn: &Connection) -> Result<(), BtError> {
    // Task v2 groundwork: leases + scheduling fields (additive, nullable for existing rows).
    // These fields are required to support a reliable scheduler + worker claiming.
    if !table_has_column(conn, "tasks", "updated_at")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN updated_at TEXT", [])?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_updated_at ON tasks(updated_at)",
            [],
        )?;
    }
    if !table_has_column(conn, "tasks", "earliest_start_at")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN earliest_start_at TEXT", [])?;
    }
    if !table_has_column(conn, "tasks", "snooze_until")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN snooze_until TEXT", [])?;
    }
    if !table_has_column(conn, "tasks", "lease_owner")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN lease_owner TEXT", [])?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_lease_owner ON tasks(lease_owner)",
            [],
        )?;
    }
    if !table_has_column(conn, "tasks", "lease_expires_at")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN lease_expires_at TEXT", [])?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tasks_lease_expires_at ON tasks(lease_expires_at)",
            [],
        )?;
    }

    Ok(())
}

fn migration_5(conn: &Connection) -> Result<(), BtError> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS automations (
            id TEXT PRIMARY KEY,
            executor_kind TEXT NOT NULL,
            executor_config_json TEXT NOT NULL,
            title TEXT NOT NULL,
            prompt_template TEXT NOT NULL,
            doc_id TEXT,
            task_id TEXT,
            shared_context_key TEXT,
            schedule_kind TEXT NOT NULL,
            schedule_json TEXT NOT NULL,
            retry_policy_json TEXT NOT NULL,
            concurrency_policy TEXT NOT NULL,
            timezone TEXT NOT NULL,
            enabled INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            paused_at TEXT,
            last_planned_at TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_automations_enabled_schedule
            ON automations(enabled, schedule_kind, updated_at);
        CREATE INDEX IF NOT EXISTS idx_automations_shared_context
            ON automations(shared_context_key);

        CREATE TABLE IF NOT EXISTS automation_occurrences (
            id TEXT PRIMARY KEY,
            automation_id TEXT NOT NULL,
            attempt INTEGER NOT NULL,
            trigger_reason TEXT NOT NULL,
            planned_at TEXT NOT NULL,
            ready_at TEXT,
            leased_at TEXT,
            started_at TEXT,
            finished_at TEXT,
            status TEXT NOT NULL,
            dedupe_key TEXT NOT NULL,
            lease_owner TEXT,
            lease_expires_at TEXT,
            last_heartbeat_at TEXT,
            run_id TEXT,
            failure_kind TEXT,
            failure_message TEXT,
            retry_count INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(automation_id) REFERENCES automations(id) ON DELETE CASCADE,
            FOREIGN KEY(run_id) REFERENCES runs(id) ON DELETE SET NULL
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_automation_occurrences_dedupe
            ON automation_occurrences(dedupe_key);
        CREATE INDEX IF NOT EXISTS idx_automation_occurrences_status_planned
            ON automation_occurrences(status, planned_at);
        CREATE INDEX IF NOT EXISTS idx_automation_occurrences_automation_planned
            ON automation_occurrences(automation_id, planned_at);
        CREATE INDEX IF NOT EXISTS idx_automation_occurrences_lease
            ON automation_occurrences(lease_owner, lease_expires_at);

        CREATE TABLE IF NOT EXISTS worker_cursors (
            worker_id TEXT PRIMARY KEY,
            consumer_group TEXT NOT NULL,
            executor_kind TEXT NOT NULL,
            last_event_id INTEGER NOT NULL DEFAULT 0,
            last_heartbeat_at TEXT NOT NULL,
            status TEXT NOT NULL,
            lease_count INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS run_evaluations (
            run_id TEXT PRIMARY KEY,
            quality_score REAL NOT NULL,
            completion_class TEXT NOT NULL,
            intervention_count INTEGER NOT NULL,
            retry_count INTEGER NOT NULL,
            lateness_seconds INTEGER NOT NULL,
            evaluated_at TEXT NOT NULL,
            FOREIGN KEY(run_id) REFERENCES runs(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS shared_contexts (
            context_key TEXT PRIMARY KEY,
            automation_id TEXT,
            latest_run_id TEXT,
            latest_occurrence_id TEXT,
            state_json TEXT NOT NULL,
            artifact_path TEXT,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(automation_id) REFERENCES automations(id) ON DELETE SET NULL,
            FOREIGN KEY(latest_run_id) REFERENCES runs(id) ON DELETE SET NULL,
            FOREIGN KEY(latest_occurrence_id) REFERENCES automation_occurrences(id) ON DELETE SET NULL
        );
        "#,
    )?;

    if !table_has_column(conn, "runs", "automation_id")? {
        conn.execute("ALTER TABLE runs ADD COLUMN automation_id TEXT", [])?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_runs_automation_id ON runs(automation_id)",
            [],
        )?;
    }

    if !table_has_column(conn, "runs", "occurrence_id")? {
        conn.execute("ALTER TABLE runs ADD COLUMN occurrence_id TEXT", [])?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_runs_occurrence_id ON runs(occurrence_id)",
            [],
        )?;
    }

    Ok(())
}

fn migration_6(conn: &Connection) -> Result<(), BtError> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS graph_nodes (
            node_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            ref_id TEXT NOT NULL,
            label TEXT NOT NULL,
            secondary_label TEXT,
            group_key TEXT NOT NULL,
            search_text TEXT NOT NULL,
            sort_time TEXT,
            payload_json TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_graph_nodes_kind ON graph_nodes(kind);
        CREATE INDEX IF NOT EXISTS idx_graph_nodes_ref_id ON graph_nodes(ref_id);
        CREATE INDEX IF NOT EXISTS idx_graph_nodes_sort_time ON graph_nodes(sort_time);

        CREATE TABLE IF NOT EXISTS graph_edges (
            edge_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            source_id TEXT NOT NULL,
            target_id TEXT NOT NULL,
            search_text TEXT NOT NULL,
            sort_time TEXT,
            payload_json TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_graph_edges_kind ON graph_edges(kind);
        CREATE INDEX IF NOT EXISTS idx_graph_edges_source_id ON graph_edges(source_id);
        CREATE INDEX IF NOT EXISTS idx_graph_edges_target_id ON graph_edges(target_id);
        CREATE INDEX IF NOT EXISTS idx_graph_edges_sort_time ON graph_edges(sort_time);
        "#,
    )?;

    Ok(())
}

fn migration_7(conn: &Connection) -> Result<(), BtError> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS crafting_agents (
            agent_id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            kind TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_crafting_agents_kind ON crafting_agents(kind);
        CREATE INDEX IF NOT EXISTS idx_crafting_agents_enabled ON crafting_agents(enabled);

        CREATE TABLE IF NOT EXISTS crafting_frameworks (
            framework_id TEXT PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            custom_instruction TEXT NOT NULL,
            enhanced_instruction TEXT NOT NULL,
            chain_of_thought_json TEXT NOT NULL,
            chain_of_knowledge_json TEXT NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            enhancement_version TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_crafting_frameworks_archived
            ON crafting_frameworks(archived, updated_at);

        CREATE TABLE IF NOT EXISTS crafting_assignments (
            agent_id TEXT PRIMARY KEY,
            framework_id TEXT,
            auto_inject_default INTEGER NOT NULL DEFAULT 1,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(agent_id) REFERENCES crafting_agents(agent_id) ON DELETE CASCADE,
            FOREIGN KEY(framework_id) REFERENCES crafting_frameworks(framework_id) ON DELETE SET NULL
        );
        "#,
    )?;

    Ok(())
}

fn migration_8(conn: &Connection) -> Result<(), BtError> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS brands (
            brand_id TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            adapter_kind TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_brands_enabled ON brands(enabled);
        CREATE INDEX IF NOT EXISTS idx_brands_adapter_kind ON brands(adapter_kind);

        CREATE TABLE IF NOT EXISTS adapters (
            adapter_kind TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            config_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_adapters_enabled ON adapters(enabled);

        CREATE TABLE IF NOT EXISTS companies (
            company_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            mission TEXT NOT NULL DEFAULT '',
            active INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_companies_active ON companies(active);

        CREATE TABLE IF NOT EXISTS agents (
            agent_id TEXT PRIMARY KEY,
            company_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            role_title TEXT NOT NULL,
            role_description TEXT NOT NULL,
            manager_agent_id TEXT,
            brand_id TEXT NOT NULL,
            adapter_kind TEXT NOT NULL,
            runtime_mode TEXT NOT NULL DEFAULT 'event_driven',
            budget_monthly_cap_usd REAL NOT NULL DEFAULT 0,
            budget_warn_percent REAL NOT NULL DEFAULT 80,
            state TEXT NOT NULL DEFAULT 'active',
            policy_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            paused_at TEXT,
            FOREIGN KEY(company_id) REFERENCES companies(company_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agents_company_id ON agents(company_id);
        CREATE INDEX IF NOT EXISTS idx_agents_manager_agent_id ON agents(manager_agent_id);
        CREATE INDEX IF NOT EXISTS idx_agents_runtime_mode ON agents(runtime_mode);
        CREATE INDEX IF NOT EXISTS idx_agents_state ON agents(state);

        CREATE TABLE IF NOT EXISTS goals (
            goal_id TEXT PRIMARY KEY,
            company_id TEXT NOT NULL,
            parent_goal_id TEXT,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            owner_agent_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(company_id) REFERENCES companies(company_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_goals_company_id ON goals(company_id);
        CREATE INDEX IF NOT EXISTS idx_goals_parent_goal_id ON goals(parent_goal_id);
        CREATE INDEX IF NOT EXISTS idx_goals_owner_agent_id ON goals(owner_agent_id);

        CREATE TABLE IF NOT EXISTS tickets (
            ticket_id TEXT PRIMARY KEY,
            company_id TEXT NOT NULL,
            goal_id TEXT,
            task_id TEXT,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            priority TEXT,
            assigned_agent_id TEXT,
            current_run_id TEXT,
            plan_required INTEGER NOT NULL DEFAULT 1,
            plan_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(company_id) REFERENCES companies(company_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_tickets_company_id ON tickets(company_id);
        CREATE INDEX IF NOT EXISTS idx_tickets_goal_id ON tickets(goal_id);
        CREATE INDEX IF NOT EXISTS idx_tickets_task_id ON tickets(task_id);
        CREATE INDEX IF NOT EXISTS idx_tickets_assigned_agent_id ON tickets(assigned_agent_id);
        CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status);

        CREATE TABLE IF NOT EXISTS ticket_thread_messages (
            message_id TEXT PRIMARY KEY,
            ticket_id TEXT NOT NULL,
            run_id TEXT,
            actor_type TEXT NOT NULL,
            actor_id TEXT NOT NULL,
            body_md TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(ticket_id) REFERENCES tickets(ticket_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_ticket_thread_messages_ticket_id
            ON ticket_thread_messages(ticket_id, created_at);

        CREATE TABLE IF NOT EXISTS ticket_decisions (
            decision_id TEXT PRIMARY KEY,
            ticket_id TEXT NOT NULL,
            run_id TEXT,
            decision_type TEXT NOT NULL,
            decision_text TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(ticket_id) REFERENCES tickets(ticket_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_ticket_decisions_ticket_id
            ON ticket_decisions(ticket_id, created_at);

        CREATE TABLE IF NOT EXISTS ticket_tool_traces (
            trace_id TEXT PRIMARY KEY,
            ticket_id TEXT NOT NULL,
            run_id TEXT,
            tool_name TEXT NOT NULL,
            input_json TEXT NOT NULL,
            output_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(ticket_id) REFERENCES tickets(ticket_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_ticket_tool_traces_ticket_id
            ON ticket_tool_traces(ticket_id, created_at);

        CREATE TABLE IF NOT EXISTS budget_monthly_usage (
            usage_id TEXT PRIMARY KEY,
            company_id TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            run_id TEXT,
            month_key TEXT NOT NULL,
            usd_cost REAL NOT NULL DEFAULT 0,
            source TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_budget_usage_agent_month
            ON budget_monthly_usage(agent_id, month_key);
        CREATE INDEX IF NOT EXISTS idx_budget_usage_company_month
            ON budget_monthly_usage(company_id, month_key);

        CREATE TABLE IF NOT EXISTS budget_overrides (
            override_id TEXT PRIMARY KEY,
            company_id TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            reason TEXT NOT NULL,
            approved_by TEXT NOT NULL,
            active INTEGER NOT NULL DEFAULT 1,
            expires_at TEXT,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_budget_overrides_agent_active
            ON budget_overrides(agent_id, active);

        CREATE TABLE IF NOT EXISTS plans (
            plan_id TEXT PRIMARY KEY,
            company_id TEXT NOT NULL,
            ticket_id TEXT,
            task_id TEXT,
            agent_id TEXT,
            status TEXT NOT NULL,
            plan_path TEXT NOT NULL,
            latest_revision INTEGER NOT NULL DEFAULT 0,
            submitted_by TEXT,
            approved_by TEXT,
            approved_at TEXT,
            review_note TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_plans_company_id ON plans(company_id);
        CREATE INDEX IF NOT EXISTS idx_plans_ticket_id ON plans(ticket_id);
        CREATE INDEX IF NOT EXISTS idx_plans_task_id ON plans(task_id);
        CREATE INDEX IF NOT EXISTS idx_plans_status ON plans(status);

        CREATE TABLE IF NOT EXISTS plan_revisions (
            revision_id TEXT PRIMARY KEY,
            plan_id TEXT NOT NULL,
            revision_number INTEGER NOT NULL,
            file_path TEXT NOT NULL,
            content_md TEXT NOT NULL,
            submitted_by TEXT NOT NULL,
            submitted_at TEXT NOT NULL,
            review_status TEXT NOT NULL,
            review_comment TEXT,
            FOREIGN KEY(plan_id) REFERENCES plans(plan_id) ON DELETE CASCADE
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_plan_revisions_unique
            ON plan_revisions(plan_id, revision_number);

        CREATE TABLE IF NOT EXISTS governance_approvals (
            approval_id TEXT PRIMARY KEY,
            company_id TEXT NOT NULL,
            subject_type TEXT NOT NULL,
            subject_id TEXT NOT NULL,
            action TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            requested_by TEXT NOT NULL,
            status TEXT NOT NULL,
            reviewed_by TEXT,
            reviewed_at TEXT,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_governance_approvals_subject
            ON governance_approvals(company_id, subject_type, subject_id, status);

        CREATE TABLE IF NOT EXISTS config_revisions (
            revision_id TEXT PRIMARY KEY,
            company_id TEXT NOT NULL,
            config_scope TEXT NOT NULL,
            config_json TEXT NOT NULL,
            previous_revision_id TEXT,
            created_by TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_config_revisions_company_scope
            ON config_revisions(company_id, config_scope, created_at);
        "#,
    )?;

    if !table_has_column(conn, "runs", "agent_brand")? {
        conn.execute("ALTER TABLE runs ADD COLUMN agent_brand TEXT", [])?;
    }
    if !table_has_column(conn, "runs", "agent_name")? {
        conn.execute("ALTER TABLE runs ADD COLUMN agent_name TEXT", [])?;
    }
    if !table_has_column(conn, "runs", "agent_session_id")? {
        conn.execute("ALTER TABLE runs ADD COLUMN agent_session_id TEXT", [])?;
    }
    if !table_has_column(conn, "runs", "adapter_kind")? {
        conn.execute("ALTER TABLE runs ADD COLUMN adapter_kind TEXT", [])?;
    }
    if !table_has_column(conn, "runs", "company_id")? {
        conn.execute("ALTER TABLE runs ADD COLUMN company_id TEXT", [])?;
    }
    if !table_has_column(conn, "runs", "agent_id")? {
        conn.execute("ALTER TABLE runs ADD COLUMN agent_id TEXT", [])?;
    }
    if !table_has_column(conn, "runs", "goal_id")? {
        conn.execute("ALTER TABLE runs ADD COLUMN goal_id TEXT", [])?;
    }
    if !table_has_column(conn, "runs", "ticket_id")? {
        conn.execute("ALTER TABLE runs ADD COLUMN ticket_id TEXT", [])?;
    }
    conn.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_runs_agent_brand ON runs(agent_brand);
        CREATE INDEX IF NOT EXISTS idx_runs_agent_id ON runs(agent_id);
        CREATE INDEX IF NOT EXISTS idx_runs_ticket_id ON runs(ticket_id);
        CREATE INDEX IF NOT EXISTS idx_runs_company_id ON runs(company_id);
        "#,
    )?;

    conn.execute_batch(
        r#"
        UPDATE runs
        SET agent_name=COALESCE(agent_name, openclaw_agent_name),
            agent_session_id=COALESCE(agent_session_id, openclaw_session_id),
            agent_brand=COALESCE(
                agent_brand,
                CASE
                    WHEN openclaw_agent_name IS NOT NULL OR openclaw_session_id IS NOT NULL OR lower(source) LIKE '%openclaw%' THEN 'openclaw'
                    ELSE NULL
                END
            ),
            adapter_kind=COALESCE(adapter_kind, source)
        "#,
    )?;

    if !table_has_column(conn, "automations", "company_id")? {
        conn.execute("ALTER TABLE automations ADD COLUMN company_id TEXT", [])?;
    }
    if !table_has_column(conn, "automations", "goal_id")? {
        conn.execute("ALTER TABLE automations ADD COLUMN goal_id TEXT", [])?;
    }
    if !table_has_column(conn, "automations", "brand_id")? {
        conn.execute("ALTER TABLE automations ADD COLUMN brand_id TEXT", [])?;
    }
    if !table_has_column(conn, "automations", "adapter_kind")? {
        conn.execute("ALTER TABLE automations ADD COLUMN adapter_kind TEXT", [])?;
    }
    conn.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_automations_company_id ON automations(company_id);
        CREATE INDEX IF NOT EXISTS idx_automations_goal_id ON automations(goal_id);
        CREATE INDEX IF NOT EXISTS idx_automations_brand_id ON automations(brand_id);
        CREATE INDEX IF NOT EXISTS idx_automations_adapter_kind ON automations(adapter_kind);
        "#,
    )?;
    conn.execute_batch(
        r#"
        UPDATE automations
        SET company_id=COALESCE(company_id, 'company_default'),
            adapter_kind=COALESCE(adapter_kind, executor_kind),
            brand_id=COALESCE(
                brand_id,
                CASE
                    WHEN executor_kind='openclaw_local' THEN 'openclaw'
                    WHEN executor_kind='command_local' THEN 'bash'
                    ELSE 'other'
                END
            )
        "#,
    )?;

    if !table_has_column(conn, "events", "company_id")? {
        conn.execute("ALTER TABLE events ADD COLUMN company_id TEXT", [])?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_events_company_id_event_id ON events(company_id, event_id)",
            [],
        )?;
    }

    conn.execute_batch(
        r#"
        INSERT OR IGNORE INTO companies(company_id, name, mission, active, created_at, updated_at)
        VALUES('company_default', 'Default Company', '', 1, datetime('now'), datetime('now'));

        INSERT OR IGNORE INTO adapters(adapter_kind, display_name, enabled, config_json, created_at, updated_at)
        VALUES
            ('openclaw_local', 'OpenClaw Local', 1, '{}', datetime('now'), datetime('now')),
            ('command_local', 'Command Local', 1, '{}', datetime('now'), datetime('now')),
            ('bash_local', 'Bash Local', 1, '{}', datetime('now'), datetime('now')),
            ('http_webhook', 'HTTP Webhook', 1, '{}', datetime('now'), datetime('now')),
            ('generic_local', 'Generic Local', 1, '{}', datetime('now'), datetime('now'));

        INSERT OR IGNORE INTO brands(brand_id, label, adapter_kind, enabled, metadata_json, created_at, updated_at)
        VALUES
            ('openclaw', 'OpenClaw', 'openclaw_local', 1, '{}', datetime('now'), datetime('now')),
            ('nemoclaw', 'NemoClaw', 'openclaw_local', 1, '{}', datetime('now'), datetime('now')),
            ('claude_code', 'Claude Code', 'command_local', 1, '{}', datetime('now'), datetime('now')),
            ('codex', 'Codex', 'command_local', 1, '{}', datetime('now'), datetime('now')),
            ('cursor', 'Cursor', 'command_local', 1, '{}', datetime('now'), datetime('now')),
            ('antigravity', 'Antigravity', 'command_local', 1, '{}', datetime('now'), datetime('now')),
            ('bash', 'Bash', 'bash_local', 1, '{}', datetime('now'), datetime('now')),
            ('http', 'HTTP', 'http_webhook', 1, '{}', datetime('now'), datetime('now')),
            ('other', 'Other', 'generic_local', 1, '{}', datetime('now'), datetime('now'));
        "#,
    )?;

    Ok(())
}

fn migration_9(conn: &Connection) -> Result<(), BtError> {
    if !table_has_column(conn, "tasks", "queue_lane")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN queue_lane TEXT", [])?;
    }
    if !table_has_column(conn, "tasks", "queue_order")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN queue_order INTEGER", [])?;
    }
    if !table_has_column(conn, "tasks", "success_criteria_json")? {
        conn.execute(
            "ALTER TABLE tasks ADD COLUMN success_criteria_json TEXT",
            [],
        )?;
    }
    if !table_has_column(conn, "tasks", "verification_hint")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN verification_hint TEXT", [])?;
    }
    if !table_has_column(conn, "tasks", "verification_summary")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN verification_summary TEXT", [])?;
    }
    if !table_has_column(conn, "tasks", "archived_at")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN archived_at TEXT", [])?;
    }
    if !table_has_column(conn, "tasks", "merged_into_task_id")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN merged_into_task_id TEXT", [])?;
    }
    if !table_has_column(conn, "tasks", "verified_by_run_id")? {
        conn.execute("ALTER TABLE tasks ADD COLUMN verified_by_run_id TEXT", [])?;
    }

    conn.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_tasks_doc_lane_order
            ON tasks(doc_id, queue_lane, queue_order);
        CREATE INDEX IF NOT EXISTS idx_tasks_lane_updated
            ON tasks(queue_lane, updated_at);
        CREATE INDEX IF NOT EXISTS idx_tasks_archived_at
            ON tasks(archived_at);
        CREATE INDEX IF NOT EXISTS idx_tasks_merged_into_task_id
            ON tasks(merged_into_task_id);
        CREATE INDEX IF NOT EXISTS idx_tasks_verified_by_run_id
            ON tasks(verified_by_run_id);

        UPDATE tasks
        SET queue_lane = CASE
                WHEN status = 'completed' THEN 'archived'
                ELSE 'queued'
            END
        WHERE queue_lane IS NULL;

        UPDATE tasks
        SET archived_at = COALESCE(archived_at, completed_at)
        WHERE archived_at IS NULL
          AND completed_at IS NOT NULL;

        UPDATE tasks
        SET success_criteria_json = COALESCE(success_criteria_json, '[]')
        WHERE success_criteria_json IS NULL;
        "#,
    )?;

    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS task_edit_handoffs (
            handoff_id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            doc_id TEXT,
            status TEXT NOT NULL,
            created_by TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            claimed_at TEXT,
            claimed_by TEXT,
            completed_at TEXT,
            completed_by TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_task_edit_handoffs_status_created
            ON task_edit_handoffs(status, created_at);
        CREATE INDEX IF NOT EXISTS idx_task_edit_handoffs_task_id
            ON task_edit_handoffs(task_id);
        CREATE INDEX IF NOT EXISTS idx_task_edit_handoffs_doc_id
            ON task_edit_handoffs(doc_id);
        "#,
    )?;

    Ok(())
}

fn migration_10(conn: &Connection) -> Result<(), BtError> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS context_packs (
            context_id TEXT PRIMARY KEY,
            brand TEXT NOT NULL,
            session_id TEXT,
            doc_id TEXT,
            status TEXT NOT NULL,
            source_hash TEXT NOT NULL,
            token_estimate INTEGER NOT NULL DEFAULT 0,
            citation_count INTEGER NOT NULL DEFAULT 0,
            unresolved_citation_count INTEGER NOT NULL DEFAULT 0,
            previous_context_id TEXT,
            manifest_path TEXT NOT NULL,
            summary_path TEXT NOT NULL,
            created_at TEXT NOT NULL,
            superseded_at TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_context_packs_brand_created
            ON context_packs(brand, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_context_packs_session_created
            ON context_packs(session_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_context_packs_doc_created
            ON context_packs(doc_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_context_packs_active
            ON context_packs(brand, session_id, doc_id, superseded_at);

        CREATE TABLE IF NOT EXISTS context_pack_sources (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            context_id TEXT NOT NULL,
            source_kind TEXT NOT NULL,
            source_ref TEXT NOT NULL,
            source_path TEXT,
            source_hash TEXT NOT NULL,
            source_rank INTEGER NOT NULL DEFAULT 0,
            locator_json TEXT NOT NULL,
            FOREIGN KEY(context_id) REFERENCES context_packs(context_id) ON DELETE CASCADE
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_context_pack_sources_unique
            ON context_pack_sources(context_id, source_kind, source_ref);
        CREATE INDEX IF NOT EXISTS idx_context_pack_sources_context_rank
            ON context_pack_sources(context_id, source_rank);
        "#,
    )?;

    Ok(())
}

fn migration_11(conn: &Connection) -> Result<(), BtError> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS craftships (
            craftship_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            necessity TEXT NOT NULL,
            mode TEXT NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_craftships_archived_updated
            ON craftships(archived, updated_at DESC);

        CREATE TABLE IF NOT EXISTS craftship_nodes (
            node_id TEXT PRIMARY KEY,
            craftship_id TEXT NOT NULL,
            parent_node_id TEXT,
            label TEXT NOT NULL,
            node_kind TEXT NOT NULL,
            framework_id TEXT,
            brand_id TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(craftship_id) REFERENCES craftships(craftship_id) ON DELETE CASCADE,
            FOREIGN KEY(parent_node_id) REFERENCES craftship_nodes(node_id) ON DELETE CASCADE,
            FOREIGN KEY(framework_id) REFERENCES crafting_frameworks(framework_id) ON DELETE SET NULL,
            FOREIGN KEY(brand_id) REFERENCES brands(brand_id) ON DELETE SET NULL
        );

        CREATE INDEX IF NOT EXISTS idx_craftship_nodes_craftship_order
            ON craftship_nodes(craftship_id, sort_order, created_at);
        CREATE INDEX IF NOT EXISTS idx_craftship_nodes_parent
            ON craftship_nodes(parent_node_id);

        CREATE TABLE IF NOT EXISTS craftship_sessions (
            craftship_session_id TEXT PRIMARY KEY,
            craftship_id TEXT NOT NULL,
            name TEXT NOT NULL,
            status TEXT NOT NULL,
            launch_mode TEXT NOT NULL,
            runtime_brand TEXT NOT NULL,
            doc_id TEXT,
            last_context_pack_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(craftship_id) REFERENCES craftships(craftship_id) ON DELETE CASCADE,
            FOREIGN KEY(doc_id) REFERENCES docs(id) ON DELETE SET NULL,
            FOREIGN KEY(last_context_pack_id) REFERENCES context_packs(context_id) ON DELETE SET NULL
        );

        CREATE INDEX IF NOT EXISTS idx_craftship_sessions_status_updated
            ON craftship_sessions(status, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_craftship_sessions_craftship
            ON craftship_sessions(craftship_id, updated_at DESC);

        CREATE TABLE IF NOT EXISTS craftship_session_nodes (
            session_node_id TEXT PRIMARY KEY,
            craftship_session_id TEXT NOT NULL,
            template_node_id TEXT,
            parent_session_node_id TEXT,
            label TEXT NOT NULL,
            framework_id TEXT,
            brand_id TEXT,
            terminal_ref TEXT,
            run_id TEXT,
            status TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(craftship_session_id) REFERENCES craftship_sessions(craftship_session_id) ON DELETE CASCADE,
            FOREIGN KEY(template_node_id) REFERENCES craftship_nodes(node_id) ON DELETE SET NULL,
            FOREIGN KEY(parent_session_node_id) REFERENCES craftship_session_nodes(session_node_id) ON DELETE CASCADE,
            FOREIGN KEY(framework_id) REFERENCES crafting_frameworks(framework_id) ON DELETE SET NULL,
            FOREIGN KEY(brand_id) REFERENCES brands(brand_id) ON DELETE SET NULL,
            FOREIGN KEY(run_id) REFERENCES runs(id) ON DELETE SET NULL
        );

        CREATE INDEX IF NOT EXISTS idx_craftship_session_nodes_session_order
            ON craftship_session_nodes(craftship_session_id, sort_order, created_at);
        CREATE INDEX IF NOT EXISTS idx_craftship_session_nodes_terminal_ref
            ON craftship_session_nodes(terminal_ref);
        CREATE INDEX IF NOT EXISTS idx_craftship_session_nodes_run
            ON craftship_session_nodes(run_id);
        "#,
    )?;

    if !table_has_column(conn, "runs", "craftship_session_id")? {
        conn.execute("ALTER TABLE runs ADD COLUMN craftship_session_id TEXT", [])?;
    }
    if !table_has_column(conn, "runs", "craftship_session_node_id")? {
        conn.execute(
            "ALTER TABLE runs ADD COLUMN craftship_session_node_id TEXT",
            [],
        )?;
    }

    conn.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_runs_craftship_session_id
            ON runs(craftship_session_id);
        CREATE INDEX IF NOT EXISTS idx_runs_craftship_session_node_id
            ON runs(craftship_session_node_id);
        "#,
    )?;

    Ok(())
}

fn migration_12(conn: &Connection) -> Result<(), BtError> {
    if !table_has_column(conn, "craftship_nodes", "brand_id")? {
        conn.execute("ALTER TABLE craftship_nodes ADD COLUMN brand_id TEXT", [])?;
    }
    if !table_has_column(conn, "craftship_session_nodes", "brand_id")? {
        conn.execute(
            "ALTER TABLE craftship_session_nodes ADD COLUMN brand_id TEXT",
            [],
        )?;
    }

    conn.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_craftship_nodes_brand
            ON craftship_nodes(brand_id);
        CREATE INDEX IF NOT EXISTS idx_craftship_session_nodes_brand
            ON craftship_session_nodes(brand_id);
        "#,
    )?;

    Ok(())
}

fn migration_13(conn: &Connection) -> Result<(), BtError> {
    if !table_has_column(conn, "craftship_session_nodes", "worktree_path")? {
        conn.execute(
            "ALTER TABLE craftship_session_nodes ADD COLUMN worktree_path TEXT",
            [],
        )?;
    }
    if !table_has_column(conn, "craftship_session_nodes", "branch_name")? {
        conn.execute(
            "ALTER TABLE craftship_session_nodes ADD COLUMN branch_name TEXT",
            [],
        )?;
    }
    if !table_has_column(conn, "craftship_session_nodes", "event_cursor")? {
        conn.execute(
            "ALTER TABLE craftship_session_nodes ADD COLUMN event_cursor INTEGER",
            [],
        )?;
    }
    if !table_has_column(conn, "craftship_session_nodes", "presence")? {
        conn.execute(
            "ALTER TABLE craftship_session_nodes ADD COLUMN presence TEXT",
            [],
        )?;
    }
    if !table_has_column(conn, "craftship_session_nodes", "agent_name")? {
        conn.execute(
            "ALTER TABLE craftship_session_nodes ADD COLUMN agent_name TEXT",
            [],
        )?;
    }
    if !table_has_column(conn, "craftship_session_nodes", "agent_token_id")? {
        conn.execute(
            "ALTER TABLE craftship_session_nodes ADD COLUMN agent_token_id TEXT",
            [],
        )?;
    }

    conn.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_craftship_session_nodes_worktree
            ON craftship_session_nodes(worktree_path);
        CREATE INDEX IF NOT EXISTS idx_craftship_session_nodes_agent_token
            ON craftship_session_nodes(agent_token_id);

        CREATE TABLE IF NOT EXISTS craftship_team_work_items (
            work_item_id TEXT PRIMARY KEY,
            craftship_session_id TEXT NOT NULL,
            source_task_id TEXT,
            created_by_session_node_id TEXT,
            assigned_session_node_id TEXT,
            status TEXT NOT NULL,
            title TEXT NOT NULL,
            description_md TEXT,
            success_criteria_json TEXT NOT NULL DEFAULT '[]',
            verification_hint TEXT,
            result_summary TEXT,
            worktree_ref TEXT,
            branch_name TEXT,
            changed_files_json TEXT NOT NULL DEFAULT '[]',
            commit_hash TEXT,
            claimed_at TEXT,
            completed_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(craftship_session_id) REFERENCES craftship_sessions(craftship_session_id) ON DELETE CASCADE,
            FOREIGN KEY(source_task_id) REFERENCES tasks(id) ON DELETE SET NULL,
            FOREIGN KEY(created_by_session_node_id) REFERENCES craftship_session_nodes(session_node_id) ON DELETE SET NULL,
            FOREIGN KEY(assigned_session_node_id) REFERENCES craftship_session_nodes(session_node_id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS idx_craftship_team_work_items_session_status
            ON craftship_team_work_items(craftship_session_id, status, updated_at);
        CREATE INDEX IF NOT EXISTS idx_craftship_team_work_items_assignee_status
            ON craftship_team_work_items(assigned_session_node_id, status, updated_at);

        CREATE TABLE IF NOT EXISTS craftship_team_messages (
            message_id TEXT PRIMARY KEY,
            craftship_session_id TEXT NOT NULL,
            sender_session_node_id TEXT,
            message_kind TEXT NOT NULL,
            subject TEXT,
            body_md TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(craftship_session_id) REFERENCES craftship_sessions(craftship_session_id) ON DELETE CASCADE,
            FOREIGN KEY(sender_session_node_id) REFERENCES craftship_session_nodes(session_node_id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS idx_craftship_team_messages_session_created
            ON craftship_team_messages(craftship_session_id, created_at);

        CREATE TABLE IF NOT EXISTS craftship_team_message_receipts (
            receipt_id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            recipient_session_node_id TEXT NOT NULL,
            state TEXT NOT NULL,
            delivered_at TEXT,
            acknowledged_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(message_id) REFERENCES craftship_team_messages(message_id) ON DELETE CASCADE,
            FOREIGN KEY(recipient_session_node_id) REFERENCES craftship_session_nodes(session_node_id) ON DELETE CASCADE
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_craftship_team_message_receipts_unique
            ON craftship_team_message_receipts(message_id, recipient_session_node_id);
        CREATE INDEX IF NOT EXISTS idx_craftship_team_message_receipts_recipient_state
            ON craftship_team_message_receipts(recipient_session_node_id, state, updated_at);
        "#,
    )?;

    Ok(())
}

fn migration_14(conn: &Connection) -> Result<(), BtError> {
    if !table_has_column(conn, "craftship_sessions", "source_doc_id")? {
        conn.execute(
            "ALTER TABLE craftship_sessions ADD COLUMN source_doc_id TEXT",
            [],
        )?;
    }

    conn.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_craftship_sessions_source_doc
            ON craftship_sessions(source_doc_id);

        CREATE TABLE IF NOT EXISTS doc_plan_handoffs (
            handoff_id TEXT PRIMARY KEY,
            doc_id TEXT NOT NULL,
            status TEXT NOT NULL,
            reason TEXT NOT NULL,
            requested_user_updated_at TEXT NOT NULL,
            created_by TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            claimed_at TEXT,
            claimed_by TEXT,
            completed_at TEXT,
            completed_by TEXT,
            FOREIGN KEY(doc_id) REFERENCES docs(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_doc_plan_handoffs_status_updated
            ON doc_plan_handoffs(status, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_doc_plan_handoffs_doc_updated
            ON doc_plan_handoffs(doc_id, updated_at DESC);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_doc_plan_handoffs_active_doc
            ON doc_plan_handoffs(doc_id)
            WHERE status IN ('pending', 'claimed');
        "#,
    )?;

    Ok(())
}

fn migration_15(conn: &Connection) -> Result<(), BtError> {
    // Contracts service tables (System A).
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS contracts (
            contract_id          TEXT PRIMARY KEY,
            domain               TEXT NOT NULL,
            title                TEXT NOT NULL,
            status               TEXT NOT NULL,
            current_state_json   TEXT NOT NULL,
            desired_state_json   TEXT NOT NULL,
            inputs_json          TEXT NOT NULL,
            constraints_json     TEXT NOT NULL,
            invariants_json      TEXT NOT NULL,
            completion_tests_json TEXT NOT NULL,
            quality_threshold    REAL NOT NULL DEFAULT 0.0,
            retry_policy_json    TEXT NOT NULL,
            cost_profile_json    TEXT NOT NULL,
            parent_contract_id   TEXT,
            craftship_session_id TEXT,
            pre_work_phase_id    TEXT,
            doc_id               TEXT,
            created_by_actor     TEXT NOT NULL,
            created_at           TEXT NOT NULL,
            updated_at           TEXT NOT NULL,
            resolved_at          TEXT,
            FOREIGN KEY (parent_contract_id) REFERENCES contracts(contract_id) ON DELETE SET NULL,
            FOREIGN KEY (craftship_session_id) REFERENCES craftship_sessions(craftship_session_id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS idx_contracts_domain  ON contracts(domain);
        CREATE INDEX IF NOT EXISTS idx_contracts_status  ON contracts(status);
        CREATE INDEX IF NOT EXISTS idx_contracts_session ON contracts(craftship_session_id);
        CREATE INDEX IF NOT EXISTS idx_contracts_phase   ON contracts(pre_work_phase_id);
        CREATE INDEX IF NOT EXISTS idx_contracts_parent  ON contracts(parent_contract_id);

        CREATE TABLE IF NOT EXISTS contract_runs (
            contract_run_id    TEXT PRIMARY KEY,
            contract_id        TEXT NOT NULL,
            attempt            INTEGER NOT NULL,
            invoked_by_actor   TEXT NOT NULL,
            invoked_via        TEXT NOT NULL,
            binary_name        TEXT,
            status             TEXT NOT NULL,
            step_count         INTEGER NOT NULL DEFAULT 0,
            diff_summary_json  TEXT,
            evidence_run_id    TEXT,
            cost_used_json     TEXT,
            error_kind         TEXT,
            error_message      TEXT,
            started_at         TEXT NOT NULL,
            finished_at        TEXT,
            FOREIGN KEY (contract_id) REFERENCES contracts(contract_id) ON DELETE CASCADE,
            FOREIGN KEY (evidence_run_id) REFERENCES runs(id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS idx_contract_runs_contract ON contract_runs(contract_id);
        CREATE INDEX IF NOT EXISTS idx_contract_runs_status   ON contract_runs(status);
        "#,
    )?;

    // Pre-Work Layer (System B) — orthogonal session-level state machine.
    if !table_has_column(conn, "craftships", "pre_work_enabled")? {
        conn.execute(
            "ALTER TABLE craftships ADD COLUMN pre_work_enabled INTEGER NOT NULL DEFAULT 1",
            [],
        )?;
    }
    if !table_has_column(conn, "craftship_sessions", "pre_work_enabled")? {
        conn.execute(
            "ALTER TABLE craftship_sessions ADD COLUMN pre_work_enabled INTEGER",
            [],
        )?;
    }

    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS craftship_pre_work_phases (
            phase_id              TEXT PRIMARY KEY,
            craftship_session_id  TEXT NOT NULL,
            phase                 TEXT NOT NULL,
            ordinal               INTEGER NOT NULL,
            status                TEXT NOT NULL,
            current_contract_id   TEXT,
            desired_contract_id   TEXT,
            resumable_token       TEXT,
            prerequisites_json    TEXT NOT NULL,
            decision_summary      TEXT,
            started_at            TEXT,
            satisfied_at          TEXT,
            updated_at            TEXT NOT NULL,
            FOREIGN KEY (craftship_session_id) REFERENCES craftship_sessions(craftship_session_id) ON DELETE CASCADE,
            FOREIGN KEY (current_contract_id) REFERENCES contracts(contract_id) ON DELETE SET NULL,
            FOREIGN KEY (desired_contract_id) REFERENCES contracts(contract_id) ON DELETE SET NULL,
            UNIQUE (craftship_session_id, phase)
        );
        CREATE INDEX IF NOT EXISTS idx_cpwp_session ON craftship_pre_work_phases(craftship_session_id);
        CREATE INDEX IF NOT EXISTS idx_cpwp_status  ON craftship_pre_work_phases(status);

        CREATE TABLE IF NOT EXISTS craftship_decision_records (
            decision_id        TEXT PRIMARY KEY,
            phase_id           TEXT NOT NULL,
            decision           TEXT NOT NULL,
            rationale          TEXT,
            alternatives_json  TEXT,
            evidence_run_id    TEXT,
            recorded_by_actor  TEXT NOT NULL,
            recorded_at        TEXT NOT NULL,
            FOREIGN KEY (phase_id) REFERENCES craftship_pre_work_phases(phase_id) ON DELETE CASCADE,
            FOREIGN KEY (evidence_run_id) REFERENCES runs(id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cpwp_decisions_phase ON craftship_decision_records(phase_id);

        CREATE TABLE IF NOT EXISTS craftship_findings (
            finding_id      TEXT PRIMARY KEY,
            phase_id        TEXT NOT NULL,
            source          TEXT NOT NULL,
            body            TEXT NOT NULL,
            citations_json  TEXT,
            recorded_at     TEXT NOT NULL,
            FOREIGN KEY (phase_id) REFERENCES craftship_pre_work_phases(phase_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_cpwp_findings_phase ON craftship_findings(phase_id);

        CREATE TABLE IF NOT EXISTS craftship_implementation_plans (
            plan_id      TEXT PRIMARY KEY,
            phase_id     TEXT NOT NULL,
            body_md      TEXT NOT NULL,
            steps_json   TEXT NOT NULL,
            approved     INTEGER NOT NULL DEFAULT 0,
            recorded_at  TEXT NOT NULL,
            FOREIGN KEY (phase_id) REFERENCES craftship_pre_work_phases(phase_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_cpwp_plans_phase ON craftship_implementation_plans(phase_id);

        CREATE TABLE IF NOT EXISTS craftship_orchestration_plans (
            orch_id      TEXT PRIMARY KEY,
            phase_id     TEXT NOT NULL,
            plan_json    TEXT NOT NULL,
            recorded_at  TEXT NOT NULL,
            FOREIGN KEY (phase_id) REFERENCES craftship_pre_work_phases(phase_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_cpwp_orch_phase ON craftship_orchestration_plans(phase_id);

        CREATE TABLE IF NOT EXISTS craftship_dispatch_batches (
            batch_id            TEXT PRIMARY KEY,
            phase_id            TEXT NOT NULL,
            parallelism_target  INTEGER NOT NULL,
            status              TEXT NOT NULL,
            dispatched_at       TEXT,
            completed_at        TEXT,
            FOREIGN KEY (phase_id) REFERENCES craftship_pre_work_phases(phase_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_cpwp_batches_phase ON craftship_dispatch_batches(phase_id);

        CREATE TABLE IF NOT EXISTS craftship_synthesis (
            synthesis_id              TEXT PRIMARY KEY,
            phase_id                  TEXT NOT NULL,
            body_md                   TEXT NOT NULL,
            contributing_run_ids_json TEXT NOT NULL,
            recorded_at               TEXT NOT NULL,
            FOREIGN KEY (phase_id) REFERENCES craftship_pre_work_phases(phase_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_cpwp_synthesis_phase ON craftship_synthesis(phase_id);
        "#,
    )?;

    Ok(())
}

fn migration_16(conn: &Connection) -> Result<(), BtError> {
    // Required-Steps Agent: a mandatory (toggleable) agent per craftship that
    // receives the required_steps payload first and hands the synthesized
    // plan off to the main agent via acpx. Stored as two scalar flags on the
    // `craftships` table so the template tree stays pristine.
    //
    // Default ON for all existing craftships (user quote: "ALL OF THEM NEED
    // TO HAVE A required agent"). Default brand: codex.
    if !table_has_column(conn, "craftships", "required_agent_enabled")? {
        conn.execute(
            "ALTER TABLE craftships ADD COLUMN required_agent_enabled INTEGER NOT NULL DEFAULT 1",
            [],
        )?;
    }
    if !table_has_column(conn, "craftships", "required_agent_brand")? {
        conn.execute(
            "ALTER TABLE craftships ADD COLUMN required_agent_brand TEXT NOT NULL DEFAULT 'codex'",
            [],
        )?;
    }
    Ok(())
}

fn migration_17(conn: &Connection) -> Result<(), BtError> {
    // ── Dedup guard: prevent duplicate live craftship sessions ──────────
    //
    // Race condition: when a user saves a note, both the handoff event and
    // the polling path can fire `craftship_session_launch` concurrently.
    // The existing check-then-create in service.rs is not atomic, so both
    // threads see "no live session" and each creates one — duplicating
    // every terminal card in the canvas.
    //
    // Fix: a partial unique index so the second INSERT fails cleanly.
    // The service layer catches the UNIQUE violation and falls through to
    // the existing reuse path.

    // Clean up any existing duplicates first (keep most recently updated).
    conn.execute_batch(
        r#"
        UPDATE craftship_sessions
        SET status = 'ended', updated_at = datetime('now')
        WHERE status = 'live'
          AND source_doc_id IS NOT NULL
          AND craftship_session_id NOT IN (
              SELECT craftship_session_id
              FROM (
                  SELECT craftship_session_id,
                         ROW_NUMBER() OVER (
                             PARTITION BY craftship_id, source_doc_id
                             ORDER BY updated_at DESC
                         ) AS rn
                  FROM craftship_sessions
                  WHERE status = 'live' AND source_doc_id IS NOT NULL
              )
              WHERE rn = 1
          );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_craftship_sessions_live_dedup
            ON craftship_sessions(craftship_id, source_doc_id)
            WHERE status = 'live' AND source_doc_id IS NOT NULL;
        "#,
    )?;

    // ── Peer summaries table for agent-to-agent awareness ──────────────
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS peer_summaries (
            session_node_id      TEXT PRIMARY KEY,
            craftship_session_id TEXT NOT NULL,
            summary              TEXT NOT NULL,
            status               TEXT NOT NULL DEFAULT 'active',
            updated_at           TEXT NOT NULL,
            FOREIGN KEY (craftship_session_id)
                REFERENCES craftship_sessions(craftship_session_id) ON DELETE CASCADE
        );
        "#,
    )?;

    Ok(())
}

fn migration_18(conn: &Connection) -> Result<(), BtError> {
    // ── Note chunks + embeddings for hybrid semantic search ────────────
    //
    // See `notes::chunker` for the chunking algorithm. Each row stores
    // one chunk of a note plus its embedding as raw little-endian f32
    // bytes. We deliberately don't add the `sqlite-vec` virtual table
    // yet — at note-taking scale (~10k chunks) brute-force cosine in
    // Rust is fast enough, and keeping the schema simple lets every
    // existing dome upgrade without installing an extension.
    //
    // The (doc_id, scope, chunk_index) composite primary key means
    // `reindex_note` can cheaply DELETE + INSERT inside a transaction
    // without touching other docs' rows.
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS note_chunks (
            doc_id        TEXT NOT NULL,
            scope         TEXT NOT NULL,
            chunk_index   INTEGER NOT NULL,
            text          TEXT NOT NULL,
            heading_path  TEXT NOT NULL DEFAULT '',
            byte_start    INTEGER NOT NULL,
            byte_end      INTEGER NOT NULL,
            embedding     BLOB NOT NULL,
            created_at    TEXT NOT NULL DEFAULT (datetime('now')),
            PRIMARY KEY (doc_id, scope, chunk_index)
        );

        CREATE INDEX IF NOT EXISTS idx_note_chunks_scope
            ON note_chunks(scope);

        CREATE INDEX IF NOT EXISTS idx_note_chunks_doc
            ON note_chunks(doc_id);
        "#,
    )?;
    Ok(())
}

/// Migration 19 — record which embedder produced each chunk's vector.
///
/// Foundation-v2 fusion: Dome's default embedder changes from the
/// hash-based `NoopEmbedder` to bge-small-en-v1.5 (candle). When a
/// user upgrades, all existing chunks have vectors that the new
/// embedder doesn't match. Stamping each row with the embedder
/// identifier lets `reindex_note` detect mismatch and re-embed lazily
/// on the next write, rather than rebuilding the whole index on
/// first launch.
///
/// Format: `<embedder_id>@<version>`. For the current implementations:
/// - `noop@1` — NoopEmbedder
/// - `bge-small-en-v1.5@1` — canonical production embedder
///
/// Existing rows default to `noop@1` so they trigger re-embed on
/// first encounter with the new embedder.
fn migration_19(conn: &Connection) -> Result<(), BtError> {
    if !table_has_column(conn, "note_chunks", "embedding_model_version")? {
        conn.execute_batch(
            r#"
            ALTER TABLE note_chunks
                ADD COLUMN embedding_model_version TEXT NOT NULL DEFAULT 'noop@1';

            CREATE INDEX IF NOT EXISTS idx_note_chunks_model_version
                ON note_chunks(embedding_model_version);
            "#,
        )?;
    }
    Ok(())
}

/// Migration 20 — variable-dimension embeddings, graph ontology, and
/// Claude agent observability.
fn migration_20(conn: &Connection) -> Result<(), BtError> {
    if !table_has_column(conn, "note_chunks", "embedding_model_id")? {
        conn.execute_batch(
            r#"
            ALTER TABLE note_chunks
                ADD COLUMN embedding_model_id TEXT NOT NULL DEFAULT 'noop';
            "#,
        )?;
    }
    if !table_has_column(conn, "note_chunks", "embedding_dimension")? {
        conn.execute_batch(
            r#"
            ALTER TABLE note_chunks
                ADD COLUMN embedding_dimension INTEGER NOT NULL DEFAULT 384;
            "#,
        )?;
    }
    if !table_has_column(conn, "note_chunks", "embedding_pooling")? {
        conn.execute_batch(
            r#"
            ALTER TABLE note_chunks
                ADD COLUMN embedding_pooling TEXT NOT NULL DEFAULT 'hash-bucket';
            "#,
        )?;
    }
    if !table_has_column(conn, "note_chunks", "embedding_instruction")? {
        conn.execute_batch(
            r#"
            ALTER TABLE note_chunks
                ADD COLUMN embedding_instruction TEXT NOT NULL DEFAULT '';
            "#,
        )?;
    }
    if !table_has_column(conn, "note_chunks", "embedding_source_hash")? {
        conn.execute_batch(
            r#"
            ALTER TABLE note_chunks
                ADD COLUMN embedding_source_hash TEXT NOT NULL DEFAULT 'legacy-noop';
            "#,
        )?;
    }

    conn.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_note_chunks_embedding_model
            ON note_chunks(embedding_model_id, embedding_model_version, embedding_dimension);

        CREATE TABLE IF NOT EXISTS graph_node_kinds (
            kind TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            layer TEXT NOT NULL DEFAULT 'DETERMINISTIC',
            description TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS graph_edge_kinds (
            kind TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            layer TEXT NOT NULL DEFAULT 'DETERMINISTIC',
            description TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS agent_context_events (
            event_id TEXT PRIMARY KEY,
            agent_name TEXT,
            session_id TEXT,
            project_id TEXT,
            event_kind TEXT NOT NULL,
            context_id TEXT,
            node_id TEXT,
            reason TEXT,
            payload_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_agent_context_events_agent_created
            ON agent_context_events(agent_name, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_agent_context_events_session_created
            ON agent_context_events(session_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_agent_context_events_kind_created
            ON agent_context_events(event_kind, created_at DESC);

        CREATE TABLE IF NOT EXISTS agent_status_snapshots (
            snapshot_id TEXT PRIMARY KEY,
            claude_session_id TEXT,
            tado_session_id TEXT,
            agent_name TEXT,
            project_name TEXT,
            project_id TEXT,
            model_id TEXT,
            model_display_name TEXT,
            context_used_percent REAL,
            context_window_size INTEGER,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cost_usd REAL,
            transcript_path TEXT,
            cwd TEXT,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_agent_status_created
            ON agent_status_snapshots(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_agent_status_tado_session
            ON agent_status_snapshots(tado_session_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_agent_status_claude_session
            ON agent_status_snapshots(claude_session_id, created_at DESC);
        "#,
    )?;

    for (kind, label, description) in [
        (
            "agent_used_context",
            "Agent used context",
            "An agent consumed a Dome context pack or graph source.",
        ),
        (
            "agent_skipped_context",
            "Agent skipped context",
            "An agent proceeded without required Dome retrieval.",
        ),
        (
            "context_pack_contains",
            "Context pack contains",
            "A context pack includes a cited source.",
        ),
        (
            "note_mentions_file",
            "Note mentions file",
            "A note body mentions a project file path.",
        ),
        (
            "task_verified_by_run",
            "Task verified by run",
            "A task completion was verified by a run.",
        ),
        (
            "event_emitted_by_agent",
            "Event emitted by agent",
            "An agent emitted an event, run, or status update.",
        ),
        (
            "decision_supported_by_source",
            "Decision supported by source",
            "A decision is backed by a cited source.",
        ),
    ] {
        conn.execute(
            r#"
            INSERT INTO graph_edge_kinds(kind, label, layer, description)
            VALUES(?1, ?2, 'DETERMINISTIC', ?3)
            ON CONFLICT(kind) DO UPDATE SET
                label=excluded.label,
                description=excluded.description
            "#,
            rusqlite::params![kind, label, description],
        )?;
    }

    Ok(())
}

/// Migration 21 — scoped Dome knowledge ownership.
fn migration_21(conn: &Connection) -> Result<(), BtError> {
    if !table_has_column(conn, "docs", "owner_scope")? {
        conn.execute_batch(
            r#"
            ALTER TABLE docs
                ADD COLUMN owner_scope TEXT NOT NULL DEFAULT 'global';
            "#,
        )?;
    }
    if !table_has_column(conn, "docs", "project_id")? {
        conn.execute_batch(
            r#"
            ALTER TABLE docs
                ADD COLUMN project_id TEXT;
            "#,
        )?;
    }
    if !table_has_column(conn, "docs", "project_root")? {
        conn.execute_batch(
            r#"
            ALTER TABLE docs
                ADD COLUMN project_root TEXT;
            "#,
        )?;
    }
    if !table_has_column(conn, "docs", "knowledge_kind")? {
        conn.execute_batch(
            r#"
            ALTER TABLE docs
                ADD COLUMN knowledge_kind TEXT NOT NULL DEFAULT 'knowledge';
            "#,
        )?;
    }

    conn.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_docs_owner_scope_project
            ON docs(owner_scope, project_id, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_docs_knowledge_kind
            ON docs(knowledge_kind);
        "#,
    )?;

    Ok(())
}

/// Migration 22 — codebase indexing tables.
///
/// Adds the four tables that back Phase 2's project source-code
/// indexer: `code_projects` (one row per indexed project),
/// `code_files` (one row per source file the indexer touched, keyed by
/// `(project_id, repo_path)`), `code_chunks` (one row per AST/window
/// chunk with its embedding BLOB), and `code_index_jobs` (durable job
/// queue so a full rebuild that the user kicked off survives an app
/// restart). Also creates `fts_code` for the FTS5 lexical lane in
/// hybrid retrieval and `code_chunks_vec` (a `vec0` virtual table)
/// when sqlite-vec is loaded — Phase 3 wires the dual-write.
///
/// Why a separate `code_chunks` table instead of extending
/// `note_chunks`: code is two orders of magnitude more rows, has a
/// different unique key (file-path + chunk_index, not doc_id +
/// scope + chunk_index), and needs project-scoped queries that would
/// pollute every note query if mixed in.
fn migration_22(conn: &Connection) -> Result<(), BtError> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS code_projects (
            project_id              TEXT PRIMARY KEY,
            name                    TEXT NOT NULL,
            root_path               TEXT NOT NULL,
            enabled                 INTEGER NOT NULL DEFAULT 1,
            last_full_index_at      TEXT,
            embedding_model_id      TEXT,
            embedding_model_version TEXT,
            created_at              TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at              TEXT NOT NULL DEFAULT (datetime('now'))
        );

        CREATE TABLE IF NOT EXISTS code_files (
            project_id      TEXT NOT NULL,
            repo_path       TEXT NOT NULL,
            language        TEXT NOT NULL,
            content_sha256  TEXT NOT NULL,
            file_mtime_ns   INTEGER NOT NULL,
            byte_size       INTEGER NOT NULL,
            line_count      INTEGER NOT NULL,
            last_indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
            PRIMARY KEY (project_id, repo_path),
            FOREIGN KEY (project_id) REFERENCES code_projects(project_id)
                ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS code_chunks (
            project_id              TEXT NOT NULL,
            repo_path               TEXT NOT NULL,
            chunk_index             INTEGER NOT NULL,
            text                    TEXT NOT NULL,
            language                TEXT NOT NULL,
            node_kind               TEXT,
            qualified_name          TEXT,
            start_line              INTEGER NOT NULL,
            end_line                INTEGER NOT NULL,
            byte_start              INTEGER NOT NULL,
            byte_end                INTEGER NOT NULL,
            content_sha256          TEXT NOT NULL,
            embedding               BLOB NOT NULL,
            embedding_quant         TEXT NOT NULL DEFAULT 'i8',
            embedding_model_id      TEXT NOT NULL,
            embedding_model_version TEXT NOT NULL,
            embedding_dimension     INTEGER NOT NULL,
            embedding_pooling       TEXT NOT NULL,
            embedding_instruction   TEXT NOT NULL,
            embedding_source_hash   TEXT NOT NULL,
            created_at              TEXT NOT NULL DEFAULT (datetime('now')),
            PRIMARY KEY (project_id, repo_path, chunk_index),
            FOREIGN KEY (project_id, repo_path)
                REFERENCES code_files(project_id, repo_path)
                ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS code_index_jobs (
            job_id        TEXT PRIMARY KEY,
            project_id    TEXT NOT NULL,
            kind          TEXT NOT NULL,
            status        TEXT NOT NULL DEFAULT 'queued',
            queued_at     TEXT NOT NULL DEFAULT (datetime('now')),
            started_at    TEXT,
            finished_at   TEXT,
            files_total   INTEGER,
            files_done    INTEGER NOT NULL DEFAULT 0,
            chunks_done   INTEGER NOT NULL DEFAULT 0,
            error_message TEXT,
            FOREIGN KEY (project_id) REFERENCES code_projects(project_id)
                ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_code_chunks_project_path
            ON code_chunks(project_id, repo_path);
        CREATE INDEX IF NOT EXISTS idx_code_chunks_lang
            ON code_chunks(language);
        CREATE INDEX IF NOT EXISTS idx_code_chunks_model
            ON code_chunks(embedding_model_id, embedding_model_version);
        CREATE INDEX IF NOT EXISTS idx_code_files_sha
            ON code_files(content_sha256);
        CREATE INDEX IF NOT EXISTS idx_code_index_jobs_status
            ON code_index_jobs(status, queued_at);

        CREATE VIRTUAL TABLE IF NOT EXISTS fts_code USING fts5(
            project_id UNINDEXED,
            repo_path UNINDEXED,
            language UNINDEXED,
            text,
            tokenize='unicode61'
        );
        "#,
    )?;

    Ok(())
}

/// Migration 23 — Knowledge Catalog foundation.
///
/// Adds the lifecycle + provenance + measurement layer that turns the
/// Dome vault from a flat note store into a queryable knowledge
/// catalog. Purely additive: every new column has a constant default
/// and every new table uses `IF NOT EXISTS`.
///
/// Three groups of changes:
///
/// 1. **`graph_nodes` lifecycle columns** — confidence, supersede
///    chain, soft-delete, dedup hash, last-referenced timestamp,
///    entity version. Lets entities outlive their first write — they
///    can be confirmed, disputed, archived, or replaced without losing
///    history.
///
/// 2. **`graph_edges` provenance columns** — source signal (which
///    enricher claimed this edge), per-signal confidence, evidence id
///    pointing back to the originating doc/run/event. Multiple
///    signals can claim the same conceptual edge; aggregation happens
///    at query time.
///
/// 3. **Three new tables** —
///    - `retrieval_log` records every search/graph/recipe call so we
///      can replay queries against future Dome state and measure
///      regression. Every `dome_search` writes one row.
///    - `pending_enrichment` is the queue Phase 3's tokio workers
///      drain (extractor → linker → deduper → decayer). Backfill
///      enqueues here, doesn't run inline.
///    - `retrieval_recipes` is the registry of intent-keyed retrieval
///      policies (Tado's analog of Knowledge Catalog "verified
///      queries"). Phase 5 ships the templates; this migration just
///      reserves the table so writers don't race the schema.
fn migration_23(conn: &Connection) -> Result<(), BtError> {
    // graph_nodes lifecycle columns.
    if !table_has_column(conn, "graph_nodes", "confidence")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_nodes
                ADD COLUMN confidence REAL NOT NULL DEFAULT 0.7;
            "#,
        )?;
    }
    if !table_has_column(conn, "graph_nodes", "superseded_by")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_nodes
                ADD COLUMN superseded_by TEXT;
            "#,
        )?;
    }
    if !table_has_column(conn, "graph_nodes", "supersedes")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_nodes
                ADD COLUMN supersedes TEXT;
            "#,
        )?;
    }
    if !table_has_column(conn, "graph_nodes", "expires_at")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_nodes
                ADD COLUMN expires_at TEXT;
            "#,
        )?;
    }
    if !table_has_column(conn, "graph_nodes", "archived_at")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_nodes
                ADD COLUMN archived_at TEXT;
            "#,
        )?;
    }
    if !table_has_column(conn, "graph_nodes", "content_hash")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_nodes
                ADD COLUMN content_hash TEXT;
            "#,
        )?;
    }
    if !table_has_column(conn, "graph_nodes", "last_referenced_at")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_nodes
                ADD COLUMN last_referenced_at TEXT;
            "#,
        )?;
    }
    if !table_has_column(conn, "graph_nodes", "entity_version")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_nodes
                ADD COLUMN entity_version INTEGER NOT NULL DEFAULT 1;
            "#,
        )?;
    }

    // graph_edges provenance columns.
    if !table_has_column(conn, "graph_edges", "source_signal")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_edges
                ADD COLUMN source_signal TEXT NOT NULL DEFAULT 'manual';
            "#,
        )?;
    }
    if !table_has_column(conn, "graph_edges", "signal_confidence")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_edges
                ADD COLUMN signal_confidence REAL NOT NULL DEFAULT 0.7;
            "#,
        )?;
    }
    if !table_has_column(conn, "graph_edges", "evidence_id")? {
        conn.execute_batch(
            r#"
            ALTER TABLE graph_edges
                ADD COLUMN evidence_id TEXT;
            "#,
        )?;
    }

    // Indexes + new tables in one batch.
    conn.execute_batch(
        r#"
        CREATE INDEX IF NOT EXISTS idx_graph_nodes_superseded_by
            ON graph_nodes(superseded_by);
        CREATE INDEX IF NOT EXISTS idx_graph_nodes_archived_at
            ON graph_nodes(archived_at);
        CREATE INDEX IF NOT EXISTS idx_graph_nodes_content_hash
            ON graph_nodes(content_hash);
        CREATE INDEX IF NOT EXISTS idx_graph_nodes_expires_at
            ON graph_nodes(expires_at);
        CREATE INDEX IF NOT EXISTS idx_graph_nodes_last_referenced_at
            ON graph_nodes(last_referenced_at DESC);

        CREATE INDEX IF NOT EXISTS idx_graph_edges_source_signal
            ON graph_edges(source_signal);
        CREATE INDEX IF NOT EXISTS idx_graph_edges_evidence_id
            ON graph_edges(evidence_id);

        -- retrieval_log: one row per dome_search / dome_graph_query /
        -- dome_context_resolve / dome_recipe_apply call. Append-only;
        -- pruned by `dome-eval prune` once it ships.
        CREATE TABLE IF NOT EXISTS retrieval_log (
            log_id              TEXT PRIMARY KEY,
            created_at          TEXT NOT NULL DEFAULT (datetime('now')),
            actor_kind          TEXT NOT NULL,
            actor_id            TEXT,
            project_id          TEXT,
            knowledge_scope     TEXT NOT NULL,
            tool                TEXT NOT NULL,
            query               TEXT,
            result_ids_json     TEXT NOT NULL DEFAULT '[]',
            result_scopes_json  TEXT NOT NULL DEFAULT '[]',
            latency_ms          INTEGER NOT NULL DEFAULT 0,
            pack_id             TEXT,
            was_consumed        INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_retrieval_log_created_at
            ON retrieval_log(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_retrieval_log_actor
            ON retrieval_log(actor_kind, actor_id);
        CREATE INDEX IF NOT EXISTS idx_retrieval_log_project
            ON retrieval_log(project_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_retrieval_log_tool
            ON retrieval_log(tool, created_at DESC);

        -- pending_enrichment: durable queue drained by Phase 3
        -- enrichment workers. Mirrors `code_index_jobs` shape so
        -- crash recovery is identical.
        CREATE TABLE IF NOT EXISTS pending_enrichment (
            job_id           TEXT PRIMARY KEY,
            target_kind      TEXT NOT NULL,
            target_id        TEXT NOT NULL,
            enrichment_kind  TEXT NOT NULL,
            project_id       TEXT,
            enqueued_at      TEXT NOT NULL DEFAULT (datetime('now')),
            started_at       TEXT,
            finished_at      TEXT,
            status           TEXT NOT NULL DEFAULT 'queued',
            attempts         INTEGER NOT NULL DEFAULT 0,
            last_error       TEXT,
            payload_json     TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS idx_pending_enrichment_status_queue
            ON pending_enrichment(status, enrichment_kind, enqueued_at);
        CREATE INDEX IF NOT EXISTS idx_pending_enrichment_target
            ON pending_enrichment(target_kind, target_id);

        -- retrieval_recipes: registry of intent-keyed retrieval
        -- policies (Tado's analog of Knowledge Catalog "verified
        -- queries"). Phase 5 fills this; Phase 1 just reserves the
        -- shape.
        CREATE TABLE IF NOT EXISTS retrieval_recipes (
            recipe_id              TEXT PRIMARY KEY,
            intent_key             TEXT NOT NULL,
            scope                  TEXT NOT NULL DEFAULT 'project',
            project_id             TEXT,
            title                  TEXT NOT NULL,
            description            TEXT NOT NULL DEFAULT '',
            template_path          TEXT NOT NULL,
            retrieval_policy_json  TEXT NOT NULL DEFAULT '{}',
            enabled                INTEGER NOT NULL DEFAULT 1,
            last_verified_at       TEXT,
            created_at             TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at             TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_retrieval_recipes_intent_scope_project
            ON retrieval_recipes(intent_key, scope, COALESCE(project_id, ''));
        CREATE INDEX IF NOT EXISTS idx_retrieval_recipes_enabled
            ON retrieval_recipes(enabled, intent_key);
        "#,
    )?;

    Ok(())
}

/// Migration 24 — Knowledge Catalog activation marker (Phase 5).
///
/// No DDL of its own. Stamps `pragma user_version = 24` so callers
/// that need the "v0.10 stack is fully wired" state — recipes
/// table populated, enrichment workers booted, spawn-pack engine
/// available — can probe a single sentinel. Future migrations can
/// add hard requirements gated on `>= 24`; for now it's a
/// no-op that pins the schema version.
fn migration_24(conn: &Connection) -> Result<(), BtError> {
    // Idempotent stamp: write a row to a tiny activation log so
    // downstream tooling (like dome-eval) can audit when the
    // upgrade landed without parsing pragma values.
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS schema_activation_log (
            schema_version INTEGER PRIMARY KEY,
            activated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        INSERT OR IGNORE INTO schema_activation_log (schema_version)
            VALUES (24);
        "#,
    )?;
    Ok(())
}

fn table_has_column(conn: &Connection, table: &str, column: &str) -> Result<bool, BtError> {
    let pragma = format!("PRAGMA table_info({})", table);
    let mut stmt = conn.prepare(&pragma)?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let name: String = row.get(1)?;
        if name == column {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Helper to detect whether a table exists (used by future migrations).
#[allow(dead_code)]
fn table_exists(conn: &Connection, table: &str) -> Result<bool, BtError> {
    let mut stmt =
        conn.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1")?;
    let found: Option<String> = stmt.query_row([table], |row| row.get(0)).optional()?;
    Ok(found.is_some())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_adds_scoped_dome_doc_metadata() {
        let conn = Connection::open_in_memory().unwrap();
        let version = migrate(&conn).unwrap();
        assert_eq!(version, LATEST_SCHEMA_VERSION);
        for column in ["owner_scope", "project_id", "project_root", "knowledge_kind"] {
            assert!(table_has_column(&conn, "docs", column).unwrap(), "missing {column}");
        }
    }

    #[test]
    fn migration_22_creates_code_tables() {
        let conn = Connection::open_in_memory().unwrap();
        let version = migrate(&conn).unwrap();
        assert_eq!(version, LATEST_SCHEMA_VERSION);
        for table in ["code_projects", "code_files", "code_chunks", "code_index_jobs", "fts_code"] {
            let exists: i64 = conn
                .query_row(
                    "SELECT count(*) FROM sqlite_master WHERE name = ?1",
                    [table],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(exists >= 1, "missing table {table}");
        }
        for column in [
            "embedding",
            "embedding_quant",
            "embedding_model_id",
            "embedding_model_version",
            "embedding_dimension",
            "embedding_pooling",
            "embedding_instruction",
            "embedding_source_hash",
        ] {
            assert!(
                table_has_column(&conn, "code_chunks", column).unwrap(),
                "code_chunks missing column {column}"
            );
        }
    }

    #[test]
    fn migration_23_adds_lifecycle_columns_and_log_tables() {
        let conn = Connection::open_in_memory().unwrap();
        let version = migrate(&conn).unwrap();
        assert_eq!(version, LATEST_SCHEMA_VERSION);

        // graph_nodes lifecycle columns
        for column in [
            "confidence",
            "superseded_by",
            "supersedes",
            "expires_at",
            "archived_at",
            "content_hash",
            "last_referenced_at",
            "entity_version",
        ] {
            assert!(
                table_has_column(&conn, "graph_nodes", column).unwrap(),
                "graph_nodes missing column {column}"
            );
        }

        // graph_edges provenance columns
        for column in ["source_signal", "signal_confidence", "evidence_id"] {
            assert!(
                table_has_column(&conn, "graph_edges", column).unwrap(),
                "graph_edges missing column {column}"
            );
        }

        // New tables
        for table in ["retrieval_log", "pending_enrichment", "retrieval_recipes"] {
            let exists: i64 = conn
                .query_row(
                    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name = ?1",
                    [table],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(exists, 1, "missing table {table}");
        }

        // retrieval_log INSERT round-trip.
        conn.execute(
            r#"INSERT INTO retrieval_log (
                log_id, actor_kind, knowledge_scope, tool,
                query, result_ids_json, result_scopes_json, latency_ms
            ) VALUES (?1, 'agent', 'project', 'dome_search', ?2, '["a","b"]', '["project","global"]', 12)"#,
            ["log-test-1", "hello world"],
        )
        .unwrap();
        let cnt: i64 = conn
            .query_row("SELECT count(*) FROM retrieval_log", [], |row| row.get(0))
            .unwrap();
        assert_eq!(cnt, 1, "retrieval_log insert failed");

        // pending_enrichment INSERT round-trip.
        conn.execute(
            r#"INSERT INTO pending_enrichment (
                job_id, target_kind, target_id, enrichment_kind, project_id
            ) VALUES (?1, 'doc', ?2, 'extract', NULL)"#,
            ["job-test-1", "doc-1"],
        )
        .unwrap();
        let cnt: i64 = conn
            .query_row(
                "SELECT count(*) FROM pending_enrichment WHERE status='queued'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(cnt, 1, "pending_enrichment default status not 'queued'");

        // retrieval_recipes uniqueness on (intent_key, scope, project_id) with NULL project.
        conn.execute(
            r#"INSERT INTO retrieval_recipes (
                recipe_id, intent_key, scope, project_id, title, template_path
            ) VALUES (?1, 'architecture-review', 'global', NULL, 'Architecture review', '.tado/verified-prompts/arch.md')"#,
            ["rec-test-1"],
        )
        .unwrap();
        let dup = conn.execute(
            r#"INSERT INTO retrieval_recipes (
                recipe_id, intent_key, scope, project_id, title, template_path
            ) VALUES (?1, 'architecture-review', 'global', NULL, 'dup', '.tado/verified-prompts/arch.md')"#,
            ["rec-test-2"],
        );
        assert!(dup.is_err(), "duplicate intent_key/scope/project_id should be rejected");

        // Re-running migrate is idempotent (no duplicate-column errors).
        let version_again = migrate(&conn).unwrap();
        assert_eq!(version_again, LATEST_SCHEMA_VERSION);
    }

    #[test]
    fn migration_24_stamps_activation_log() {
        let conn = Connection::open_in_memory().unwrap();
        let version = migrate(&conn).unwrap();
        assert_eq!(version, LATEST_SCHEMA_VERSION);
        assert!(version >= 24, "schema must reach v24 for Phase 5");

        let activated_count: i64 = conn
            .query_row(
                "SELECT count(*) FROM schema_activation_log WHERE schema_version = 24",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(activated_count, 1, "v24 activation row missing");

        // Idempotent re-run keeps row count at 1 (INSERT OR IGNORE).
        let version_again = migrate(&conn).unwrap();
        assert_eq!(version_again, LATEST_SCHEMA_VERSION);
        let still_one: i64 = conn
            .query_row(
                "SELECT count(*) FROM schema_activation_log WHERE schema_version = 24",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(still_one, 1);
    }
}
