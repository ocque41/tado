// Foundation-v2 fusion notice: bt-core retains ~3000 LOC of
// craftship/openclaw/runtime-branding scaffolding reachable from RPC
// handlers kept alive for compatibility with migrations that wrote
// those tables. Proper deletion is a dedicated surgical slice (H1-deep
// in the next-wave plan). Until then, a file-level allow keeps the
// cargo output clean without masking real issues in code we actually
// edit — lint-on-touch still catches mistakes because `#[allow]` is
// scoped to this file, not applied crate-wide.
#![allow(dead_code)]

use crate::automation::{
    completion_class, expand_schedule, next_retry_at, parse_retry_policy, parse_schedule,
    ScheduleDefinition,
};
use crate::config;
use crate::db;
use crate::error::BtError;
use crate::fs_guard;
use crate::model::{
    Actor, AdapterRecord, AgentContextEventRecord, AgentRecord, AuditEntry, AutomationOccurrence,
    AutomationRecord, BrandRecord, BudgetOverrideRecord, BudgetUsageEntry, ChainOfKnowledgeConfig,
    ChainOfThoughtConfig, CompanyRecord, ConfigRevision, ContextPackRecord,
    ContextPackSourceRecord, CraftingFramework, Craftship, CraftshipNode, CraftshipSession,
    CraftshipSessionNode, CraftshipTeamInboxEntry, CraftshipTeamMessage,
    CraftshipTeamMessageReceipt, CraftshipTeamWorkItem, DocMeta, DocPlanHandoff, DocRecord,
    GoalRecord, GovernanceApproval, GraphEdgeRecord, GraphNodeRecord, PairPaths, PlanRecord,
    PlanRevisionRecord, RunArtifact, RunEvaluation, RunRecord, SharedContextRecord, Suggestion,
    Task, TaskEditHandoff, TicketDecision, TicketRecord, TicketThreadMessage, TicketToolTrace,
    TokenRecord, WorkerCursor,
};
use crate::notes::Embedder;
use chrono::{DateTime, Duration, Utc};
use diffy::{apply, Patch};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration as StdDuration, Instant};
use uuid::Uuid;

// Dome shipped with compile-time baked-in markdown templates for
// openclaw/crafting/research surfaces that Tado's fusion explicitly
// drops. The constants are stubbed to empty strings so bt-core
// compiles inside tado-core without carrying the entire Dome docs/
// tree. See the file-level allow at the top for context.
const OPENCLAW_RUNTIME_AGENTS_TEMPLATE: &str = "";
const OPENCLAW_RUNTIME_SKILL_TEMPLATE: &str = "";
const OPERATIONS_ROOT_TEMPLATE: &str = "";
const OPERATIONS_FACILITY_TEMPLATE: &str = "";
const OPERATIONS_RUNTIME_TEMPLATE: &str = "";
const OPERATIONS_CONTEXT_TEMPLATE: &str = "";
const TOOLS_RESEARCH_TEMPLATE: &str = "";
const TOOLS_PROMPT_CALC_TEMPLATE: &str = "";
const OPENCLAW_RUNTIME_SKILL_CANONICAL_REL: &str = "skills/dome/SKILL.md";
const OPENCLAW_RUNTIME_SKILL_LEGACY_REL: &str = "skills/terminal/SKILL.md";
const RUNTIME_MANIFEST_REL: &str = ".bt/runtime/manifest.json";
const RUNTIME_FACILITY_REL: &str = ".bt/runtime/facility.json";
const RUNTIME_TOOLS_DIR_REL: &str = ".bt/runtime/tools";
const CONTEXT_PACKS_DIR_REL: &str = ".bt/context/packs";
const RUNTIME_ANATOMY_VERSION: &str = "dome-anatomy-v1.1";
const RUNTIME_MANIFEST_SCHEMA_VERSION: &str = "runtime-manifest-v1";
const RUNTIME_FACILITY_SCHEMA_VERSION: &str = "runtime-facility-v1";
const CONTEXT_PACK_SCHEMA_VERSION: &str = "context-pack-v1";
const CRAFTING_ENHANCER_VERSION: &str = "crafting-v2";
const DEFAULT_COMPANY_ID: &str = "company_default";
const DEFAULT_BOARD_ACTOR: &str = "board";
const DOME_TASK_PLAN_BLOCK: &str = "dome-task-plan";
const DOME_CRAFTSHIP_PLAN_BLOCK: &str = "dome-craftship-plan";
const TEAM_MESSAGE_KIND_DEFAULT: &str = "direct";
const TEAM_RECEIPT_PENDING: &str = "pending";
const TEAM_RECEIPT_DELIVERED: &str = "delivered";
const TEAM_RECEIPT_ACKNOWLEDGED: &str = "acknowledged";
const SUPPORTED_RUNTIME_BRANDS: &[(&str, &str)] =
    &[("claude_code", "Claude Code"), ("codex", "Codex")];
/// Brands the Required-Steps agent may run as. Narrower than
/// `SUPPORTED_RUNTIME_BRANDS` because the required-steps agent must be able
/// to execute `acpx` as a subprocess to hand off to the Lead agent, which
/// only works for LLM brands that have an acpx mapping.
const REQUIRED_AGENT_SUPPORTED_BRANDS: &[&str] = &["codex", "claude_code"];
const COMPATIBILITY_INSTRUCTION_FILES: &[(&str, &str)] = &[("claude_code", "CLAUDE.md")];
const FORBIDDEN_LEGACY_BRAND_FILES: &[&str] = &[
    "OPENCLAW.md",
    "NEMOCLAW.md",
    "CODEX.md",
    "CURSOR.md",
    "ANTIGRAVITY.md",
    "BASH.md",
    "HTTP.md",
    "AGENT.md",
];
const FORBIDDEN_LEGACY_RUNTIME_PATHS: &[&str] = &[".bt/runtime/adapters"];
const OPERATIONS_REQUIRED_RELS: &[&str] = &[
    "operations/README.md",
    "operations/facility/README.md",
    "operations/runtime/README.md",
    "operations/context/README.md",
];
const GRAPH_DEFAULT_INCLUDE_TYPES: &[&str] = &[
    "doc",
    "topic",
    "tag",
    "task",
    "automation",
    "run",
    "shared_context",
    "context_pack",
    "context_event",
    "framework",
    "agent",
    "craftship",
    "craftship_session",
    "craftship_session_node",
    "goal",
    "ticket",
    "plan",
];
const GRAPH_ALL_NODE_TYPES: &[&str] = &[
    "doc",
    "topic",
    "tag",
    "task",
    "automation",
    "run",
    "shared_context",
    "context_pack",
    "context_event",
    "framework",
    "artifact",
    "event",
    "agent",
    "craftship",
    "craftship_session",
    "craftship_session_node",
    "company",
    "goal",
    "ticket",
    "plan",
    "brand",
    "adapter",
];

#[derive(Debug, Clone)]
pub struct CoreService {
    vault_root: Arc<RwLock<Option<PathBuf>>>,
    // A long-lived "keepalive" SQLite connection. Held only to prevent
    // SQLite from running its truncating checkpoint and deleting the
    // `.bt/index.sqlite-wal` and `.bt/index.sqlite-shm` sidecar files
    // between RPC calls. Without this, every RPC opens the only
    // connection in existence, drops it on scope exit, and SQLite
    // dutifully cleans up the WAL — producing the visible "blink every
    // second" file churn the user reported. (Bug I)
    //
    // This connection is NEVER used for queries. The existing per-RPC
    // `open_conn()` path is left untouched so the change is minimal-diff
    // and zero-risk for query correctness. The keepalive lives for the
    // lifetime of the `CoreService` and is initialized lazily on the
    // first call to `open_conn()` once a vault has been opened.
    wal_keepalive: Arc<Mutex<Option<rusqlite::Connection>>>,
    // Debounce timestamp for `refresh_graph_projection` on the audit hot
    // path. The projection rebuild reads every row from every graph-
    // relevant table (docs, tasks, runs, automations, craftships,
    // contexts, etc.) and writes a full replacement back. On every
    // `audit()` that is O(vault_total_rows) of SQLite work, which is the
    // secondary amplifier of the craftship-launch RPC timeout bug. The
    // read path (`load_graph_records`) already falls back to rebuilding
    // on demand if the projection is empty, so a bounded-staleness
    // refresh is safe. `maybe_refresh_graph_projection()` skips the
    // refresh if a previous one happened within the throttle window.
    last_graph_refresh: Arc<Mutex<Option<Instant>>>,
}

/// Role selector for `build_craftship_system_prompt`. Governs the prompt's
/// opening sentences, whether the Pre-Work ledger is included, and whether
/// the Dispatch-protocol checklist or the acpx Dispatch block is emitted.
#[derive(Debug, Clone, Copy)]
enum PromptRole<'a> {
    /// Classic Lead-agent prompt. When `analyze_first_path` is `Some`, a
    /// "First analyze `<path>`" preamble is prepended — used in the OFF
    /// branch where the Lead agent receives the required-steps payload
    /// directly instead of going through the Required-Steps agent.
    LeadAgent { analyze_first_path: Option<&'a str> },
    /// Required-Steps agent prompt. Contains the Lead agent's
    /// `session_node_id` and brand so the agent can hand off the
    /// orchestration plan via `acpx prompt`, as well as the
    /// `REQUIRED_AGENT_UNAVAILABLE:` sentinel contract.
    RequiredAgent {
        /// Dome brand id of the Lead agent (e.g. `"claude_code"`).
        lead_brand: &'a str,
        /// The Lead agent's session-scoped node id (e.g.
        /// `"cssn_ba2878…"`). Used to derive the acpx session name.
        lead_session_node_id: &'a str,
        /// Human-readable label of the Lead agent (from the CraftshipNode).
        lead_label: &'a str,
        /// Absolute filesystem path to the source `user.md`. Must be
        /// absolute so the Required-Steps agent can read it regardless of
        /// its own working directory.
        user_md_absolute_path: &'a str,
    },
}

#[derive(Debug, Clone)]
pub enum WriteOperation {
    CreateDocument,
    CreateTopic,
    UpdateAgentNote,
    UpdateUserNote,
    UpdateMeta { fields: Vec<String> },
    RenameDocument { title_only: bool },
    DeleteDocument,
    DeleteAgentContent,
    UpdateTasksMirror,

    // Observability / automation ledger
    CreateRun,
    UpdateRun,
    AttachRunArtifact,
    BootstrapRuntime,
    ManageAutomation,
    ManageCrafting,
    ManageRegistry,
    ManageOrg,
    ManageGoal,
    ManageTicket,
    ManageBudget,
    ManagePlan,
    ManageGovernance,
    ManageRuntime,
    ManageContext,
    ManageWorker,
    ViewMonitor,

    // Contracts service (System A). Operator-only for create/complete/archive.
    // `ManageContractsReport` is allowed for agents so binaries can push
    // evidence back through the trusted daemon.
    ManageContracts,
    ManageContractsReport,

    InternalBt,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct DomeTaskPlan {
    version: String,
    mode: String,
    tasks: Vec<DomeTaskPlanEntry>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct DomeTaskPlanEntry {
    order: i64,
    title: String,
    #[serde(default)]
    priority: Option<String>,
    #[serde(default)]
    success_criteria: Vec<String>,
    #[serde(default)]
    verification_hint: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct DomeCraftshipPlan {
    version: String,
    mode: String,
    craftship_id: String,
    steps: Vec<DomeCraftshipPlanStep>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct DomeCraftshipPlanStep {
    task_order: i64,
    task_title: String,
    #[serde(default)]
    assignments: Vec<DomeCraftshipPlanAssignment>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
struct DomeCraftshipPlanAssignment {
    template_node_id: String,
    title: String,
    description_md: String,
    #[serde(default)]
    success_criteria: Vec<String>,
    #[serde(default)]
    verification_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ImportPreviewItem {
    source_path: String,
    relative_path: String,
    topic: String,
    title: String,
    slug: String,
    mode: String,
}

#[derive(Debug, Clone, Serialize)]
struct ContextStatement {
    text: String,
    citations: Vec<String>,
}

#[derive(Debug, Clone)]
struct ContextSourceItem {
    source_kind: String,
    source_ref: String,
    source_path: Option<String>,
    title: String,
    body: String,
    hash: String,
    rank: i64,
    locator_json: Value,
}

#[derive(Debug, Clone)]
struct CraftshipNodeContextBudget {
    max_sources: usize,
    max_chars: usize,
    max_chars_per_source: usize,
    max_items_per_section: usize,
}

#[derive(Debug, Clone)]
struct CraftshipNodeContextCandidate {
    source: ContextSourceItem,
    knowledge_labels: Vec<String>,
    priority_group: usize,
    mandatory: bool,
}

#[derive(Debug, Clone)]
struct CraftshipNodeSelectedSource {
    candidate: CraftshipNodeContextCandidate,
    inclusion_reason: String,
}

#[derive(Debug, Clone)]
struct CraftshipNodeContextSelection {
    selected: Vec<CraftshipNodeSelectedSource>,
    dropped: Vec<Value>,
    selected_chars: usize,
}

#[derive(Debug, Clone, Deserialize)]
struct CraftshipNodeInput {
    #[serde(default)]
    node_id: Option<String>,
    #[serde(default)]
    parent_node_id: Option<String>,
    label: String,
    #[serde(default)]
    node_kind: Option<String>,
    #[serde(default)]
    framework_id: Option<String>,
    #[serde(default)]
    brand_id: Option<String>,
    #[serde(default)]
    sort_order: Option<i64>,
}

// How long to skip a subsequent `refresh_graph_projection` call on the
// audit hot path. 500 ms is short enough that graph queries never see
// more than half a second of staleness, and long enough that a burst of
// audit writes (e.g., the craftship launch handoff chain) collapses to a
// single rebuild instead of N rebuilds.
// Throttle for debounced graph rebuilds on the audit hot path. 2 seconds
// is long enough that the entire craftship launch chain (doc_create +
// meta_update + session_launch + pre_work phases) collapses to at most
// one rebuild instead of 4-6 rebuilds, while still short enough that
// graph queries see no more than ~2s of staleness.
const GRAPH_REFRESH_THROTTLE: StdDuration = StdDuration::from_millis(2000);

#[derive(Debug, Clone)]
struct KnowledgeScopeFilter {
    mode: String,
    project_id: Option<String>,
    include_global: bool,
}

impl KnowledgeScopeFilter {
    fn from_parts(
        knowledge_scope: Option<&str>,
        project_id: Option<&str>,
        include_global: Option<bool>,
    ) -> Self {
        let mode = knowledge_scope.unwrap_or("all").trim().to_lowercase();
        let project_id = project_id
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        let include_global = include_global.unwrap_or(matches!(
            mode.as_str(),
            "auto" | "merged" | "project-merged"
        ));
        let mode = match mode.as_str() {
            "global" | "project" | "merged" | "auto" | "all" => mode,
            "project-merged" => "merged".to_string(),
            _ => "all".to_string(),
        };
        Self {
            mode,
            project_id,
            include_global,
        }
    }

    fn matches_doc(&self, doc: &DocRecord) -> bool {
        Self::matches_parts(
            &self.mode,
            self.project_id.as_deref(),
            self.include_global,
            &doc.owner_scope,
            doc.project_id.as_deref(),
        )
    }

    fn matches_parts(
        mode: &str,
        filter_project_id: Option<&str>,
        include_global: bool,
        owner_scope: &str,
        owner_project_id: Option<&str>,
    ) -> bool {
        match mode {
            "global" => owner_scope == "global",
            "project" => {
                filter_project_id.is_some()
                    && owner_scope == "project"
                    && owner_project_id == filter_project_id
            }
            "merged" | "auto" => {
                if let Some(project_id) = filter_project_id {
                    (include_global && owner_scope == "global")
                        || (owner_scope == "project" && owner_project_id == Some(project_id))
                } else {
                    owner_scope == "global"
                }
            }
            _ => true,
        }
    }
}

fn normalize_owner_scope(value: Option<&str>, project_id: Option<&str>) -> String {
    match value.unwrap_or("global").trim().to_lowercase().as_str() {
        "project" if project_id.map(|v| !v.trim().is_empty()).unwrap_or(false) => {
            "project".to_string()
        }
        _ => "global".to_string(),
    }
}

fn normalize_knowledge_kind(value: Option<&str>) -> String {
    match value.unwrap_or("knowledge").trim().to_lowercase().as_str() {
        "workflow" => "workflow".to_string(),
        "decision" => "decision".to_string(),
        "system" => "system".to_string(),
        _ => "knowledge".to_string(),
    }
}

impl CoreService {
    pub fn new() -> Self {
        Self {
            vault_root: Arc::new(RwLock::new(None)),
            wal_keepalive: Arc::new(Mutex::new(None)),
            last_graph_refresh: Arc::new(Mutex::new(None)),
        }
    }

    /// Ensure the WAL keepalive connection is alive for the current vault.
    /// Called from `open_conn()` so every RPC path benefits without any
    /// per-callsite changes. Idempotent: only opens once per service lifetime.
    fn ensure_wal_keepalive(&self) -> Result<(), BtError> {
        let mut guard = self
            .wal_keepalive
            .lock()
            .map_err(|_| BtError::Validation("wal keepalive lock poisoned".to_string()))?;
        if guard.is_some() {
            return Ok(());
        }
        let path = self.db_path()?;
        let conn = db::open_db(&path)?;
        *guard = Some(conn);
        Ok(())
    }

    pub fn with_vault(vault_path: &Path) -> Result<Self, BtError> {
        let service = Self::new();
        service.open_vault(vault_path)?;
        Ok(service)
    }

    pub fn init_vault(&self, path: &Path) -> Result<Value, BtError> {
        let canonical = fs_guard::canonicalize_vault(path)?;
        fs_guard::ensure_vault_layout(&canonical)?;

        let db_path = fs_guard::safe_join(&canonical, Path::new(".bt/index.sqlite"))?;
        let conn = db::open_db(&db_path)?;

        let cfg = config::load_config(&canonical)?;
        config::save_config(&canonical, &cfg)?;
        self.ensure_default_orchestration_records(&conn)?;

        let _ = fs_guard::safe_join(&canonical, Path::new(".bt/audit.log"))?;
        *self.vault_root.write().expect("vault lock poisoned") = Some(canonical.clone());

        Ok(json!({
            "vault_path": canonical,
            "initialized": true
        }))
    }

    pub fn open_vault(&self, path: &Path) -> Result<Value, BtError> {
        let canonical = fs_guard::canonicalize_vault(path)?;
        let is_new_vault = !canonical.join(".bt/index.sqlite").exists();
        fs_guard::ensure_vault_layout(&canonical)?;
        let db_path = fs_guard::safe_join(&canonical, Path::new(".bt/index.sqlite"))?;
        let conn = db::open_db(&db_path)?;
        let docs = db::list_docs(&conn, None)?;
        let _cfg = config::load_config(&canonical)?;
        self.ensure_default_orchestration_records(&conn)?;
        let topics_count = self.count_topic_dirs(&canonical)?;

        *self.vault_root.write().expect("vault lock poisoned") = Some(canonical.clone());

        Ok(json!({
            "vault_path": canonical,
            "opened": true,
            "docs_count": docs.len(),
            "topics_count": topics_count,
            "is_new_vault": is_new_vault,
        }))
    }

    pub fn status(&self) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        let docs = db::list_docs(&conn, None)?;
        let topics_count = self.count_topic_dirs(&root)?;
        Ok(json!({
            "vault_path": root,
            "doc_count": docs.len(),
            "topics_count": topics_count,
            "socket_path": self.socket_path()?,
            "tasks_file": root.join("tasks.md"),
        }))
    }

    pub fn system_health(&self) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let db_path = self.db_path()?;
        let socket_path = self.socket_path()?;
        let mut checks = Vec::new();

        checks.push(json!({
            "name": "vault_root",
            "ok": root.exists() && root.is_dir(),
            "detail": root,
        }));
        checks.push(json!({
            "name": "topics_dir",
            "ok": root.join("topics").exists(),
            "detail": root.join("topics"),
        }));
        checks.push(json!({
            "name": "bt_dir",
            "ok": root.join(".bt").exists(),
            "detail": root.join(".bt"),
        }));
        checks.push(json!({
            "name": "sqlite_file",
            "ok": db_path.exists(),
            "detail": db_path,
        }));
        checks.push(json!({
            "name": "audit_log_file",
            "ok": root.join(".bt/audit.log").exists(),
            "detail": root.join(".bt/audit.log"),
        }));

        let config_ok = config::load_config(&root).is_ok();
        checks.push(json!({
            "name": "config_toml",
            "ok": config_ok,
            "detail": root.join(".bt/config.toml"),
        }));

        let db_ok = db::open_db(&self.db_path()?).is_ok();
        checks.push(json!({
            "name": "sqlite_open",
            "ok": db_ok,
            "detail": self.db_path()?,
        }));

        checks.push(json!({
            "name": "daemon_socket_present",
            "ok": socket_path.exists(),
            "detail": socket_path,
        }));

        let runtime_status = self.system_runtime_status(None)?;
        let runtime_checks = runtime_status
            .get("checks")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        checks.extend(runtime_checks);

        let ok = checks
            .iter()
            .all(|check| check.get("ok").and_then(Value::as_bool).unwrap_or(false));

        Ok(json!({
            "ok": ok,
            "checks": checks,
            "runtime_status": runtime_status,
        }))
    }

    pub fn system_connector_status(&self) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let socket_path = self.socket_path()?;
        let methods = vec![
            "vault.open",
            "vault.open_or_create",
            "vault.bootstrap_starter",
            "vault.bootstrap_agent_runtime",
            "vault.status",
            "vault.reindex",
            "import.preview",
            "import.execute",
            "system.health",
            "system.connector_status",
            "system.runtime_status",
            "system.openclaw_status",
            "system.automation_status",
            "topic.list",
            "topic.create",
            "doc.create",
            "doc.create_scoped",
            "doc.list",
            "doc.get",
            "doc.meta.update",
            "doc.update_agent",
            "doc.update_user",
            "doc.plan_handoff.list",
            "doc.plan_handoff.claim",
            "doc.plan_handoff.complete",
            "doc.plan_handoff.release",
            "knowledge.register",
            "doc.rename",
            "doc.delete_agent_content",
            "doc.delete",
            "search.query",
            "run.create",
            "run.update_status",
            "run.attach_artifact",
            "run.get",
            "run.list",
            "automation.create",
            "automation.update",
            "automation.get",
            "automation.list",
            "automation.pause",
            "automation.resume",
            "automation.delete",
            "automation.enqueue_now",
            "automation.retry_occurrence",
            "automation.occurrence_list",
            "automation.occurrence_get",
            "brand.list",
            "brand.upsert",
            "adapter.list",
            "adapter.upsert",
            "company.list",
            "company.get",
            "company.upsert",
            "agent.list",
            "agent.get",
            "agent.upsert",
            "goal.list",
            "goal.get",
            "goal.upsert",
            "ticket.upsert",
            "ticket.get",
            "ticket.list",
            "ticket.thread.message",
            "ticket.thread.decision",
            "ticket.thread.trace",
            "ticket.thread.get",
            "budget.get_status",
            "budget.override",
            "plan.submit",
            "plan.get",
            "plan.list",
            "plan.review",
            "plan.request_changes",
            "runtime.mode.get",
            "runtime.mode.set",
            "governance.approval.create",
            "governance.approval.review",
            "governance.approval.list",
            "config.revision.list",
            "config.revision.rollback",
            "crafting.framework.list",
            "crafting.framework.get",
            "crafting.framework.create",
            "crafting.framework.update",
            "crafting.framework.archive",
            "crafting.framework.render_payload",
            "crafting.craftship.list",
            "crafting.craftship.get",
            "crafting.craftship.default.get",
            "crafting.craftship.default.set",
            "crafting.craftship.create",
            "crafting.craftship.update",
            "crafting.craftship.duplicate",
            "crafting.craftship.archive",
            "crafting.craftship.session.list",
            "crafting.craftship.session.get",
            "crafting.craftship.session.launch",
            "crafting.craftship.session.rename",
            "crafting.craftship.session.delete",
            "crafting.craftship.session.digest",
            "crafting.craftship.session.set_status",
            "crafting.craftship.session.bind_node_runtime",
            "crafting.craftship.session.node_runtime.update",
            "crafting.craftship.session.message.send",
            "crafting.craftship.session.message.ack",
            "crafting.craftship.session.message.inbox",
            "crafting.craftship.session.work_item.create",
            "crafting.craftship.session.work_item.list",
            "crafting.craftship.session.work_item.assign",
            "crafting.craftship.session.work_item.claim",
            "crafting.craftship.session.work_item.update",
            "crafting.craftship.session.work_item.complete",
            "crafting.craftship.session.work_item.cancel",
            "crafting.craftship.session.orchestration.sync_from_doc",
            "context.compact",
            "context.resolve",
            "context.get",
            "context.list",
            "task.create",
            "task.complete",
            "task.plan.sync_from_doc",
            "task.list",
            "task.remove",
            "task.steer_into_active",
            "task.verify_and_archive",
            "task.edit_handoff.create",
            "task.edit_handoff.list",
            "task.edit_handoff.claim",
            "task.edit_handoff.complete",
            "suggestion.create",
            "suggestion.list",
            "suggestion.apply",
            "graph.links",
            "graph.refresh",
            "graph.snapshot",
            "graph.node_get",
            "agent.status",
            "agent.context_event.record",
            "audit.tail",
            "events.tail",
            "events.latest",
            "events.subscribe",
            "tools.list",
        ];

        let mut smoke = Vec::new();
        smoke.push(("topic.list", self.topic_list().is_ok()));
        smoke.push(("doc.list", self.doc_list(None, false).is_ok()));
        smoke.push(("import.preview", self.import_preview(None).is_ok()));
        smoke.push((
            "task.list",
            self.task_list(None, None, None, None, false, 10).is_ok(),
        ));
        smoke.push(("run.list", self.run_list(None, 5).is_ok()));
        smoke.push(("suggestion.list", self.suggestion_list(None, None).is_ok()));
        smoke.push(("audit.tail", self.audit_tail(None, 10).is_ok()));
        smoke.push(("events.tail", self.events_tail(None, 5).is_ok()));
        smoke.push(("events.latest", self.events_latest(5).is_ok()));
        smoke.push((
            "automation.list",
            self.automation_list(None, None, 10).is_ok(),
        ));
        smoke.push((
            "system.runtime_status",
            self.system_runtime_status(None).is_ok(),
        ));
        smoke.push((
            "system.automation_status",
            self.system_automation_status().is_ok(),
        ));
        smoke.push(("brand.list", self.brand_list().is_ok()));
        smoke.push(("adapter.list", self.adapter_list().is_ok()));
        smoke.push((
            "context.list",
            self.context_list(None, None, None, 5).is_ok(),
        ));
        smoke.push(("company.list", self.company_list().is_ok()));
        smoke.push(("agent.list", self.agent_list(None).is_ok()));
        smoke.push(("goal.list", self.goal_list(None, None).is_ok()));
        smoke.push(("ticket.list", self.ticket_list(None, None).is_ok()));
        smoke.push(("plan.list", self.plan_list(None, None, None, 5).is_ok()));
        smoke.push((
            "crafting.framework.list",
            self.crafting_framework_list(false).is_ok(),
        ));
        smoke.push((
            "crafting.craftship.list",
            self.craftship_list(false).is_ok(),
        ));
        smoke.push((
            "crafting.craftship.default.get",
            self.craftship_default_get().is_ok(),
        ));

        let openclaw = self.system_openclaw_status()?;

        let smoke_results = smoke
            .into_iter()
            .map(|(name, ok)| json!({ "name": name, "ok": ok }))
            .collect::<Vec<_>>();

        Ok(json!({
            "ok": smoke_results.iter().all(|v| v.get("ok").and_then(Value::as_bool).unwrap_or(false)),
            "vault_path": root,
            "transport": {
                "kind": if cfg!(unix) { "unix_socket" } else { "named_pipe" },
                "endpoint": socket_path,
            },
            "methods": methods,
            "smoke_checks": smoke_results,
            "generic_mcp": {
                "ok": true,
                "server": "bt-mcp",
            },
            "openclaw": openclaw, // deprecated stub
        }))
    }

    fn read_optional_json_file(&self, root: &Path, rel: &str) -> Result<Option<Value>, BtError> {
        let path = fs_guard::safe_join(root, Path::new(rel))?;
        if !path.exists() {
            return Ok(None);
        }
        let raw = fs::read_to_string(path)?;
        let parsed =
            serde_json::from_str::<Value>(&raw).map_err(|e| BtError::Validation(e.to_string()))?;
        Ok(Some(parsed))
    }

    pub fn system_runtime_status(&self, brand: Option<&str>) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        let normalized_brand = brand.map(Self::normalize_brand_id);
        let manifest_value = self.read_optional_json_file(&root, RUNTIME_MANIFEST_REL)?;
        let facility_value = self.read_optional_json_file(&root, RUNTIME_FACILITY_REL)?;
        let freshness_warn_hours = facility_value
            .as_ref()
            .and_then(|row| row.get("context"))
            .and_then(|row| row.get("freshness_warn_hours"))
            .and_then(Value::as_i64)
            .unwrap_or(168);

        let mut checks = Vec::new();
        let operations_present = OPERATIONS_REQUIRED_RELS
            .iter()
            .all(|rel| root.join(rel).exists());
        checks.push(json!({
            "name": "operations_layer_present",
            "ok": operations_present,
            "detail": OPERATIONS_REQUIRED_RELS,
        }));

        let manifest_ok = manifest_value
            .as_ref()
            .and_then(|row| row.get("schema_version"))
            .and_then(Value::as_str)
            == Some(RUNTIME_MANIFEST_SCHEMA_VERSION)
            && manifest_value
                .as_ref()
                .and_then(|row| row.get("anatomy_version"))
                .and_then(Value::as_str)
                == Some(RUNTIME_ANATOMY_VERSION);
        checks.push(json!({
            "name": "runtime_manifest_valid",
            "ok": manifest_ok,
            "detail": root.join(RUNTIME_MANIFEST_REL),
        }));

        let facility_ok = facility_value
            .as_ref()
            .and_then(|row| row.get("schema_version"))
            .and_then(Value::as_str)
            == Some(RUNTIME_FACILITY_SCHEMA_VERSION)
            && facility_value
                .as_ref()
                .and_then(|row| row.get("anatomy_version"))
                .and_then(Value::as_str)
                == Some(RUNTIME_ANATOMY_VERSION);
        checks.push(json!({
            "name": "facility_manifest_valid",
            "ok": facility_ok,
            "detail": root.join(RUNTIME_FACILITY_REL),
        }));

        let compatibility_checks = COMPATIBILITY_INSTRUCTION_FILES
            .iter()
            .filter(|(brand_id, _)| {
                normalized_brand
                    .as_deref()
                    .map(|row| row == *brand_id)
                    .unwrap_or(true)
            })
            .map(|(brand_id, rel_path)| {
                let path = root.join(rel_path);
                let ok = path.exists();
                json!({
                    "brand_id": brand_id,
                    "path": path,
                    "ok": ok,
                })
            })
            .collect::<Vec<_>>();
        checks.push(json!({
            "name": "compatibility_instruction_files_valid",
            "ok": compatibility_checks.iter().all(|row| row.get("ok").and_then(Value::as_bool).unwrap_or(false)),
            "detail": compatibility_checks.iter().map(|row| row.get("path").cloned().unwrap_or(Value::Null)).collect::<Vec<_>>(),
        }));

        let forbidden_legacy_files = FORBIDDEN_LEGACY_BRAND_FILES
            .iter()
            .chain(FORBIDDEN_LEGACY_RUNTIME_PATHS.iter())
            .map(|rel_path| {
                let path = root.join(rel_path);
                json!({
                    "path": path,
                    "ok": !path.exists(),
                })
            })
            .collect::<Vec<_>>();
        checks.push(json!({
            "name": "forbidden_legacy_instruction_files_absent",
            "ok": forbidden_legacy_files
                .iter()
                .all(|row| row.get("ok").and_then(Value::as_bool).unwrap_or(false)),
            "detail": forbidden_legacy_files
                .iter()
                .map(|row| row.get("path").cloned().unwrap_or(Value::Null))
                .collect::<Vec<_>>(),
        }));

        let packs_dir = root.join(CONTEXT_PACKS_DIR_REL);
        let compaction_store_ok = packs_dir.exists() && packs_dir.is_dir();
        checks.push(json!({
            "name": "compaction_store_reachable",
            "ok": compaction_store_ok,
            "detail": packs_dir,
        }));

        let latest_pack =
            db::get_latest_context_pack(&conn, normalized_brand.as_deref(), None, None)?;
        let latest_pack_freshness_ok = latest_pack
            .as_ref()
            .map(|row| Utc::now() - row.created_at <= Duration::hours(freshness_warn_hours))
            .unwrap_or(true);
        checks.push(json!({
            "name": "latest_pack_freshness",
            "ok": latest_pack_freshness_ok,
            "detail": {
                "context_id": latest_pack.as_ref().map(|row| row.context_id.clone()),
                "freshness_warn_hours": freshness_warn_hours,
            },
        }));
        let latest_pack_citation_ok = latest_pack
            .as_ref()
            .map(|row| row.unresolved_citation_count == 0)
            .unwrap_or(true);
        checks.push(json!({
            "name": "latest_pack_citation_coverage",
            "ok": latest_pack_citation_ok,
            "detail": latest_pack.as_ref().map(|row| row.context_id.clone()).unwrap_or_else(|| "none".to_string()),
        }));

        Ok(json!({
            "ok": checks.iter().all(|row| row.get("ok").and_then(Value::as_bool).unwrap_or(false)),
            "brand": normalized_brand,
            "operations": {
                "index_path": root.join("operations/README.md"),
                "required_files": OPERATIONS_REQUIRED_RELS,
            },
            "manifest": {
                "path": root.join(RUNTIME_MANIFEST_REL),
                "value": manifest_value,
            },
            "facility": {
                "path": root.join(RUNTIME_FACILITY_REL),
                "value": facility_value,
            },
            "compatibility_docs": compatibility_checks,
            "forbidden_legacy_files": forbidden_legacy_files,
            "context": {
                "packs_dir": packs_dir,
                "latest_pack": latest_pack,
            },
            "checks": checks,
        }))
    }

    pub fn system_openclaw_status(&self) -> Result<Value, BtError> {
        // Legacy endpoint kept for backwards compatibility. OpenClaw brand has
        // been removed; only claude_code and codex are supported.
        Ok(json!({
            "ok": false,
            "deprecated": true,
            "message": "OpenClaw brand removed. Use claude_code or codex.",
        }))
    }

    fn require_vault(&self) -> Result<PathBuf, BtError> {
        self.vault_root
            .read()
            .expect("vault lock poisoned")
            .clone()
            .ok_or_else(|| BtError::InvalidVaultPath("vault is not open".to_string()))
    }

    pub fn socket_path(&self) -> Result<PathBuf, BtError> {
        let root = self.require_vault()?;

        if let Ok(dir) = std::env::var("BT_CORE_SOCKET_DIR") {
            let dir = PathBuf::from(dir);
            std::fs::create_dir_all(&dir)?;
            return Ok(dir.join("bt-core.sock"));
        }

        fs_guard::safe_join(&root, Path::new(".bt/bt-core.sock"))
    }

    fn db_path(&self) -> Result<PathBuf, BtError> {
        let root = self.require_vault()?;
        fs_guard::safe_join(&root, Path::new(".bt/index.sqlite"))
    }

    fn open_conn(&self) -> Result<rusqlite::Connection, BtError> {
        // Lazily open a long-lived keepalive connection on the first RPC
        // after the vault is opened. This is the entire fix for Bug I:
        // SQLite only deletes the WAL/SHM sidecars when the LAST connection
        // closes; the keepalive guarantees there is always at least one open
        // connection so the sidecars stay on disk and stop blinking. The
        // per-RPC short-lived connection pattern is otherwise untouched.
        if let Err(err) = self.ensure_wal_keepalive() {
            // Failure to open the keepalive must not block the actual RPC.
            // Log and proceed; in the worst case we just lose the Bug I fix
            // and fall back to the legacy blink behavior.
            eprintln!("[bt-core] wal keepalive open failed: {}", err);
        }
        db::open_db(&self.db_path()?)
    }

    fn now() -> DateTime<Utc> {
        Utc::now()
    }

    fn sha(content: &str) -> String {
        let mut h = Sha256::new();
        h.update(content.as_bytes());
        hex::encode(h.finalize())
    }

    fn count_topic_dirs(&self, root: &Path) -> Result<usize, BtError> {
        let topics_root = fs_guard::safe_join(root, Path::new("topics"))?;
        if !topics_root.exists() {
            return Ok(0);
        }

        let mut count = 0usize;
        for entry in fs::read_dir(topics_root)? {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                count += 1;
            }
        }
        Ok(count)
    }

    fn sanitize_import_topic(root_rel: &Path) -> Result<String, BtError> {
        let first = root_rel
            .components()
            .next()
            .and_then(|c| c.as_os_str().to_str())
            .unwrap_or("imported");
        fs_guard::sanitize_segment(first)
    }

    fn suggest_title_from_path(path: &Path) -> String {
        path.file_stem()
            .and_then(|s| s.to_str())
            .map(|s| s.replace(['_', '-'], " "))
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "Imported Document".to_string())
    }

    fn in_reserved_vault_zone(rel: &Path) -> bool {
        let mut parts = rel.components();
        let first = parts
            .next()
            .and_then(|c| c.as_os_str().to_str())
            .unwrap_or("");
        first == "topics" || first == ".bt" || rel == Path::new("tasks.md")
    }

    fn ensure_inside_vault(&self, candidate: &Path) -> Result<PathBuf, BtError> {
        let root = self.require_vault()?;
        let root_canon = fs::canonicalize(&root)?;
        let abs = if candidate.is_absolute() {
            candidate.to_path_buf()
        } else {
            root.join(candidate)
        };
        let can = fs::canonicalize(&abs)
            .map_err(|_| BtError::Validation(format!("path does not exist: {}", abs.display())))?;
        if !can.starts_with(&root_canon) {
            return Err(BtError::PathEscape(format!(
                "{} escapes vault",
                can.display()
            )));
        }
        Ok(can)
    }

    /// Pick a slug that is free against BOTH the on-disk topic directory
    /// and the SQLite `docs` table. Filesystem-only checks are not safe:
    /// the `docs` table has a `UNIQUE INDEX (topic, slug)` and rows can
    /// outlive their directories (orphaned by failed cascades, manual
    /// deletes, or — historically — craftship-session deletes that did
    /// not clean up their linked session doc). Returning a slug that
    /// only the filesystem agreed was free trips
    /// `ERR_DB: UNIQUE constraint failed: docs.topic, docs.slug` later
    /// inside `doc_create`.
    fn unique_slug(&self, topic_slug: &str, preferred: &str) -> Result<String, BtError> {
        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        let base = fs_guard::sanitize_segment(preferred)?;
        let mut idx = 1usize;
        let mut slug = base.clone();

        loop {
            let rel = format!("topics/{}/{}", topic_slug, slug);
            let path = fs_guard::safe_join(&root, Path::new(&rel))?;
            let dir_taken = path.exists();
            let row_taken = db::doc_exists_with_topic_slug(&conn, topic_slug, &slug)?;
            if !dir_taken && !row_taken {
                return Ok(slug);
            }
            idx += 1;
            slug = format!("{}-{}", base, idx);
        }
    }

    fn workspace_root_path() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."))
    }

    fn plugin_root_path() -> PathBuf {
        Self::workspace_root_path().join("extensions/dome-openclaw")
    }

    fn legacy_plugin_root_path() -> PathBuf {
        Self::workspace_root_path().join("extensions/terminal-openclaw")
    }

    fn runtime_skill_template_for_root(&self, root: &Path) -> Result<String, BtError> {
        let canonical_skill_path =
            fs_guard::safe_join(root, Path::new(OPENCLAW_RUNTIME_SKILL_CANONICAL_REL))?;
        let legacy_skill_path =
            fs_guard::safe_join(root, Path::new(OPENCLAW_RUNTIME_SKILL_LEGACY_REL))?;

        if !canonical_skill_path.exists() && legacy_skill_path.exists() {
            return Ok(fs::read_to_string(legacy_skill_path)?);
        }

        Ok(OPENCLAW_RUNTIME_SKILL_TEMPLATE.to_string())
    }

    fn runtime_brand_exists(brand_id: &str) -> bool {
        SUPPORTED_RUNTIME_BRANDS
            .iter()
            .any(|(supported_id, _)| *supported_id == brand_id)
    }

    fn brand_compatibility_instruction_file(brand_id: &str) -> Option<&'static str> {
        COMPATIBILITY_INSTRUCTION_FILES
            .iter()
            .find_map(|(id, file)| if *id == brand_id { Some(*file) } else { None })
    }

    fn brand_instruction_file(brand_id: &str) -> &'static str {
        Self::brand_compatibility_instruction_file(brand_id).unwrap_or("AGENTS.md")
    }

    fn brand_display_name(brand_id: &str) -> String {
        SUPPORTED_RUNTIME_BRANDS
            .iter()
            .find_map(|(id, label)| {
                if *id == brand_id {
                    Some((*label).to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| brand_id.replace('_', " "))
    }

    fn preferred_tool_surface(brand_id: &str) -> &'static str {
        match brand_id {
            "openclaw" | "nemoclaw" => "dome-openclaw-plugin",
            _ => "bt-mcp",
        }
    }

    fn operations_runtime_files() -> Vec<(&'static str, &'static str)> {
        vec![
            ("operations/README.md", OPERATIONS_ROOT_TEMPLATE),
            (
                "operations/facility/README.md",
                OPERATIONS_FACILITY_TEMPLATE,
            ),
            ("operations/runtime/README.md", OPERATIONS_RUNTIME_TEMPLATE),
            ("operations/context/README.md", OPERATIONS_CONTEXT_TEMPLATE),
        ]
    }

    /// Canonical tool doc templates that get materialized into each dome under
    /// `.bt/runtime/tools/<binary>.md` by `vault.bootstrap_agent_runtime`. The
    /// files live in every vault so operators can add, edit, or remove tool
    /// docs per-dome. These constants are the baseline shipped with the
    /// daemon.
    fn tool_doc_runtime_files() -> Vec<(&'static str, &'static str)> {
        vec![
            ("research.md", TOOLS_RESEARCH_TEMPLATE),
            ("prompt-calc.md", TOOLS_PROMPT_CALC_TEMPLATE),
        ]
    }

    /// Read every `*.md` file in `<vault>/.bt/runtime/tools/` (alphabetical
    /// order) and return `{ id, filename, body_md }` entries for the craftship
    /// launch payload. A missing directory or missing vault returns an empty
    /// vec — craftship launch must not fail just because bootstrap has not
    /// been run yet.
    fn load_tool_docs(&self) -> Vec<Value> {
        let Ok(root) = self.require_vault() else {
            return Vec::new();
        };
        let Ok(dir) = fs_guard::safe_join(&root, Path::new(RUNTIME_TOOLS_DIR_REL)) else {
            return Vec::new();
        };
        if !dir.exists() {
            return Vec::new();
        }
        let Ok(entries) = fs::read_dir(&dir) else {
            return Vec::new();
        };
        let mut paths: Vec<PathBuf> = entries
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.is_file()
                    && path
                        .extension()
                        .and_then(|ext| ext.to_str())
                        .map(|ext| ext.eq_ignore_ascii_case("md"))
                        .unwrap_or(false)
            })
            .collect();
        paths.sort();
        paths
            .into_iter()
            .filter_map(|path| {
                let filename = path.file_name()?.to_str()?.to_string();
                let id = path.file_stem()?.to_str()?.to_string();
                let body = fs::read_to_string(&path).ok()?;
                Some(json!({
                    "id": id,
                    "filename": filename,
                    "body_md": body,
                }))
            })
            .collect()
    }

    fn runtime_manifest_value() -> Value {
        let brands = SUPPORTED_RUNTIME_BRANDS
            .iter()
            .map(|(brand_id, display_name)| {
                json!({
                    "brand_id": brand_id,
                    "display_name": display_name,
                    "instruction_file": Self::brand_instruction_file(brand_id),
                    "compatibility_instruction_file": Self::brand_compatibility_instruction_file(brand_id),
                    "preferred_tool_surface": Self::preferred_tool_surface(brand_id),
                })
            })
            .collect::<Vec<_>>();

        json!({
            "schema_version": RUNTIME_MANIFEST_SCHEMA_VERSION,
            "anatomy_version": RUNTIME_ANATOMY_VERSION,
            "trusted_mutator": "bt-core",
            "canonical_instruction_file": "AGENTS.md",
            "skill_entrypoint": OPENCLAW_RUNTIME_SKILL_CANONICAL_REL,
            "operations_index": "operations/README.md",
            "runtime_facility": RUNTIME_FACILITY_REL,
            "context_entrypoints": {
                "packs_dir": CONTEXT_PACKS_DIR_REL,
                "resolve_api": "context.resolve",
                "compact_api": "context.compact",
                "get_api": "context.get",
                "list_api": "context.list",
            },
            "supported_brands": brands,
            "trust_model": {
                "trusted_boundary": "bt-core",
                "untrusted_clients": [
                    "bt-cli",
                    "bt-mcp",
                    "bt-desktop",
                    "bt-desktop-macos",
                    "dome-openclaw-plugin"
                ],
                "agent_write_barrier": "apply_write"
            }
        })
    }

    fn runtime_facility_value() -> Value {
        let compatibility_instruction_files = COMPATIBILITY_INSTRUCTION_FILES
            .iter()
            .map(|(_, rel)| (*rel).to_string())
            .collect::<Vec<_>>();

        json!({
            "schema_version": RUNTIME_FACILITY_SCHEMA_VERSION,
            "anatomy_version": RUNTIME_ANATOMY_VERSION,
            "required_operations_files": OPERATIONS_REQUIRED_RELS,
            "required_runtime_files": [
                "AGENTS.md",
                OPENCLAW_RUNTIME_SKILL_CANONICAL_REL,
                RUNTIME_MANIFEST_REL,
                RUNTIME_FACILITY_REL,
            ],
            "compatibility_instruction_files": compatibility_instruction_files,
            "forbidden_legacy_instruction_files": FORBIDDEN_LEGACY_BRAND_FILES,
            "forbidden_legacy_runtime_paths": FORBIDDEN_LEGACY_RUNTIME_PATHS,
            "context": {
                "packs_dir": CONTEXT_PACKS_DIR_REL,
                "citation_coverage_required": true,
                "unresolved_citation_budget": 0,
                "freshness_warn_hours": 168,
            },
            "health_checks": [
                "operations_layer_present",
                "runtime_manifest_valid",
                "facility_manifest_valid",
                "compatibility_instruction_files_valid",
                "forbidden_legacy_instruction_files_absent",
                "compaction_store_reachable",
                "latest_pack_freshness",
                "latest_pack_citation_coverage"
            ],
        })
    }

    fn ensure_default_orchestration_records(
        &self,
        conn: &rusqlite::Connection,
    ) -> Result<(), BtError> {
        if db::get_company(conn, DEFAULT_COMPANY_ID)?.is_none() {
            let now = Utc::now();
            db::upsert_company(
                conn,
                &CompanyRecord {
                    company_id: DEFAULT_COMPANY_ID.to_string(),
                    name: "Default Company".to_string(),
                    mission: String::new(),
                    active: true,
                    created_at: now,
                    updated_at: now,
                },
            )?;
        }
        Ok(())
    }

    fn render_compatibility_instruction_file(brand_id: &str) -> String {
        let label = Self::brand_display_name(brand_id);
        format!(
            "# {label}\n\nThis file exists only for tool compatibility.\n\nRead `AGENTS.md` first and treat it as the full, canonical runtime contract.\n"
        )
    }

    fn upsert_runtime_file(
        &self,
        root: &Path,
        rel: &str,
        content: &str,
    ) -> Result<&'static str, BtError> {
        let path = fs_guard::safe_join(root, Path::new(rel))?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        if path.exists() {
            let existing = fs::read_to_string(&path)?;
            if existing == content {
                return Ok("unchanged");
            }
            fs_guard::atomic_write(root, &path, content)?;
            Ok("updated")
        } else {
            fs_guard::atomic_write(root, &path, content)?;
            Ok("created")
        }
    }

    fn remove_runtime_path(&self, root: &Path, rel: &str) -> Result<&'static str, BtError> {
        let path = fs_guard::safe_join(root, Path::new(rel))?;
        if !path.exists() {
            return Ok("absent");
        }
        if path.is_dir() {
            fs::remove_dir_all(path)?;
        } else {
            fs::remove_file(path)?;
        }
        Ok("deleted")
    }

    fn upsert_runtime_json_file(
        &self,
        root: &Path,
        rel: &str,
        value: &Value,
    ) -> Result<&'static str, BtError> {
        let content =
            serde_json::to_string_pretty(value).map_err(|e| BtError::Validation(e.to_string()))?;
        self.upsert_runtime_file(root, rel, &content)
    }

    pub fn reindex(&self) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let conn = self.open_conn()?;

        let topics_root = fs_guard::safe_join(&root, Path::new("topics"))?;
        if topics_root.exists() {
            for topic in fs::read_dir(&topics_root)? {
                let topic = topic?;
                if !topic.file_type()?.is_dir() {
                    continue;
                }
                for doc in fs::read_dir(topic.path())? {
                    let doc = doc?;
                    if !doc.file_type()?.is_dir() {
                        continue;
                    }
                    let meta_path = doc.path().join("meta.json");
                    let user_path = doc.path().join("user.md");
                    let agent_path = doc.path().join("agent.md");
                    if !meta_path.exists() || !user_path.exists() || !agent_path.exists() {
                        continue;
                    }
                    let meta_raw = fs::read_to_string(&meta_path)?;
                    let meta: DocMeta = serde_json::from_str(&meta_raw).map_err(|e| {
                        BtError::Validation(format!("invalid meta {}: {}", meta_path.display(), e))
                    })?;

                    let user = fs::read_to_string(&user_path)?;
                    let agent = fs::read_to_string(&agent_path)?;

                    let rel_user = user_path
                        .strip_prefix(&root)
                        .map_err(|_| BtError::PathEscape(user_path.display().to_string()))?
                        .to_string_lossy()
                        .replace('\\', "/");
                    let rel_agent = agent_path
                        .strip_prefix(&root)
                        .map_err(|_| BtError::PathEscape(agent_path.display().to_string()))?
                        .to_string_lossy()
                        .replace('\\', "/");

                    let slug = doc.file_name().to_string_lossy().to_string();

                    db::upsert_doc(
                        &conn,
                        &DocRecord {
                            id: meta.id.to_string(),
                            topic: meta.topic.clone(),
                            slug,
                            title: meta.title.clone(),
                            user_path: rel_user,
                            agent_path: rel_agent,
                            created_at: meta.created_at,
                            updated_at: meta.updated_at,
                            owner_scope: "global".to_string(),
                            project_id: None,
                            project_root: None,
                            knowledge_kind: "knowledge".to_string(),
                        },
                        &Self::sha(&user),
                        &Self::sha(&agent),
                    )?;
                    db::upsert_doc_meta(
                        &conn,
                        &meta.id.to_string(),
                        &meta.tags,
                        &meta.links_out,
                        meta.status.as_deref(),
                        meta.updated_at,
                    )?;
                    db::upsert_links(&conn, &meta.id.to_string(), &meta.links_out)?;
                    db::refresh_fts(&conn, &meta.id.to_string(), &user, &agent)?;
                    self.reindex_doc_embeddings(&conn, &meta.id.to_string(), &user, &agent)?;
                }
            }
        }

        self.refresh_graph_projection()?;

        Ok(json!({ "ok": true }))
    }

    pub fn vault_bootstrap_starter(&self, actor: &Actor) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::CreateDocument)?;
        let conn = self.open_conn()?;
        let docs = db::list_docs(&conn, None)?;
        if !docs.is_empty() {
            return Ok(json!({
                "created": false,
                "reason": "vault already has documents",
            }));
        }

        let created = self.doc_create(actor, "inbox", "Welcome", Some("welcome"))?;
        let id = created
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| BtError::Validation("missing id in created doc".to_string()))?;

        let user_welcome = concat!(
            "# Welcome to Dome\n\n",
            "This dome is ready.\n\n",
            "## Next Steps\n",
            "- Create a topic\n",
            "- Create a document\n",
            "- Write in Source mode\n",
            "- Use suggestions for user note edits\n",
        );
        let agent_welcome = concat!(
            "# Agent Notes\n\n",
            "Use this paired note for planning, summaries, and automation context.\n",
        );

        self.doc_update_user(actor, id, user_welcome, "replace")?;
        self.doc_update_agent(actor, id, agent_welcome, "replace", false)?;

        self.audit(
            actor,
            "vault.bootstrap_starter",
            &json!({}),
            Some(id),
            None,
            "ok",
            json!({ "doc_id": id, "topic": "inbox", "slug": "welcome" }),
        )?;

        Ok(json!({
            "created": true,
            "doc_id": id,
            "topic": "inbox",
            "slug": "welcome",
        }))
    }

    pub fn vault_bootstrap_agent_runtime(
        &self,
        actor: &Actor,
        target: &str,
    ) -> Result<Value, BtError> {
        let normalized_target = Self::normalize_brand_id(target);
        if !matches!(target, "all" | "multi_brand" | "brand_agnostic")
            && !Self::runtime_brand_exists(&normalized_target)
        {
            return Err(BtError::Validation(
                "target must be a supported brand id or one of: all, multi_brand, brand_agnostic"
                    .to_string(),
            ));
        }

        self.apply_write(actor, WriteOperation::BootstrapRuntime)?;
        let root = self.require_vault()?;
        let agents_status =
            self.upsert_runtime_file(&root, "AGENTS.md", OPENCLAW_RUNTIME_AGENTS_TEMPLATE)?;
        let skill_template = self.runtime_skill_template_for_root(&root)?;
        let skill_status =
            self.upsert_runtime_file(&root, OPENCLAW_RUNTIME_SKILL_CANONICAL_REL, &skill_template)?;
        let mut operations_statuses = serde_json::Map::new();
        for (rel_path, template) in Self::operations_runtime_files() {
            let status = self.upsert_runtime_file(&root, rel_path, template)?;
            operations_statuses.insert(rel_path.to_string(), json!(status));
        }
        let mut tool_doc_statuses = serde_json::Map::new();
        for (filename, template) in Self::tool_doc_runtime_files() {
            let rel_path = format!("{}/{}", RUNTIME_TOOLS_DIR_REL, filename);
            let status = self.upsert_runtime_file(&root, &rel_path, template)?;
            tool_doc_statuses.insert(rel_path, json!(status));
        }
        let runtime_manifest_status = self.upsert_runtime_json_file(
            &root,
            RUNTIME_MANIFEST_REL,
            &Self::runtime_manifest_value(),
        )?;
        let facility_status = self.upsert_runtime_json_file(
            &root,
            RUNTIME_FACILITY_REL,
            &Self::runtime_facility_value(),
        )?;

        let mut compatibility_statuses = serde_json::Map::new();
        for (brand_id, rel_path) in COMPATIBILITY_INSTRUCTION_FILES {
            let status = self.upsert_runtime_file(
                &root,
                rel_path,
                &Self::render_compatibility_instruction_file(brand_id),
            )?;
            compatibility_statuses.insert((*rel_path).to_string(), json!(status));
        }
        let mut cleanup_statuses = serde_json::Map::new();
        for rel_path in FORBIDDEN_LEGACY_BRAND_FILES
            .iter()
            .chain(FORBIDDEN_LEGACY_RUNTIME_PATHS.iter())
        {
            let status = self.remove_runtime_path(&root, rel_path)?;
            cleanup_statuses.insert((*rel_path).to_string(), json!(status));
        }

        self.audit(
            actor,
            "vault.bootstrap_agent_runtime",
            &json!({ "target": target }),
            None,
            None,
            "ok",
            json!({
                "agents_status": agents_status,
                "skill_status": skill_status,
                "operations": operations_statuses,
                "tool_docs": tool_doc_statuses,
                "runtime_manifest_status": runtime_manifest_status,
                "facility_status": facility_status,
                "compatibility_files": compatibility_statuses,
                "legacy_cleanup": cleanup_statuses,
            }),
        )?;

        Ok(json!({
            "ok": true,
            "target": target,
            "normalized_target": normalized_target,
            "agents_path": root.join("AGENTS.md"),
            "agents_status": agents_status,
            "skill_path": root.join(OPENCLAW_RUNTIME_SKILL_CANONICAL_REL),
            "skill_status": skill_status,
            "operations": operations_statuses,
            "tool_docs": tool_doc_statuses,
            "tool_docs_dir": root.join(RUNTIME_TOOLS_DIR_REL),
            "runtime_manifest_path": root.join(RUNTIME_MANIFEST_REL),
            "runtime_manifest_status": runtime_manifest_status,
            "facility_path": root.join(RUNTIME_FACILITY_REL),
            "facility_status": facility_status,
            "compatibility_files": compatibility_statuses,
            "legacy_cleanup": cleanup_statuses,
        }))
    }

    pub fn import_preview(&self, root_path: Option<&str>) -> Result<Value, BtError> {
        let vault_root = self.require_vault()?;
        let scan_root = if let Some(path) = root_path {
            self.ensure_inside_vault(Path::new(path))?
        } else {
            vault_root.clone()
        };

        let scan_rel = scan_root
            .strip_prefix(&vault_root)
            .unwrap_or(Path::new(""))
            .to_path_buf();
        if !scan_rel.as_os_str().is_empty() && Self::in_reserved_vault_zone(&scan_rel) {
            return Err(BtError::Validation(
                "import root cannot be inside topics/.bt/tasks.md".to_string(),
            ));
        }

        let mut stack = vec![scan_root.clone()];
        let mut items: Vec<ImportPreviewItem> = Vec::new();
        let mut skipped: Vec<Value> = Vec::new();

        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir)? {
                let entry = entry?;
                let path = entry.path();
                let rel = path
                    .strip_prefix(&vault_root)
                    .map_err(|_| BtError::PathEscape(path.display().to_string()))?
                    .to_path_buf();

                if Self::in_reserved_vault_zone(&rel) {
                    continue;
                }

                if entry.file_type()?.is_dir() {
                    stack.push(path);
                    continue;
                }

                let ext = path
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase();
                let mode = if ext == "md" || ext == "txt" {
                    "note_text"
                } else {
                    "attachment"
                };
                let topic = Self::sanitize_import_topic(
                    rel.parent().unwrap_or_else(|| Path::new("imported")),
                )?;
                let title = Self::suggest_title_from_path(&path);
                let slug = fs_guard::sanitize_segment(
                    path.file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or("imported"),
                )?;

                if path.file_name().and_then(|n| n.to_str()) == Some(".DS_Store") {
                    skipped.push(json!({
                        "path": rel,
                        "reason": "ignored system file",
                    }));
                    continue;
                }

                items.push(ImportPreviewItem {
                    source_path: path.to_string_lossy().to_string(),
                    relative_path: rel.to_string_lossy().replace('\\', "/"),
                    topic,
                    title,
                    slug,
                    mode: mode.to_string(),
                });
            }
        }

        items.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));

        Ok(json!({
            "root_path": scan_root,
            "items": items,
            "count": items.len(),
            "skipped": skipped,
        }))
    }

    fn import_execute(&self, actor: &Actor, items: &[ImportPreviewItem]) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::CreateDocument)?;
        let vault_root = self.require_vault()?;

        let mut imported = Vec::new();
        let mut failures = Vec::new();

        for item in items {
            let source_path = match self.ensure_inside_vault(Path::new(&item.source_path)) {
                Ok(path) => path,
                Err(err) => {
                    failures.push(json!({
                        "source_path": item.source_path,
                        "error": err.to_string(),
                    }));
                    continue;
                }
            };

            if !source_path.is_file() {
                failures.push(json!({
                    "source_path": item.source_path,
                    "error": "source is not a file",
                }));
                continue;
            }

            let topic_slug = match fs_guard::sanitize_segment(&item.topic) {
                Ok(v) => v,
                Err(err) => {
                    failures.push(json!({
                        "source_path": item.source_path,
                        "error": err.to_string(),
                    }));
                    continue;
                }
            };
            let slug = match self.unique_slug(&topic_slug, &item.slug) {
                Ok(v) => v,
                Err(err) => {
                    failures.push(json!({
                        "source_path": item.source_path,
                        "error": err.to_string(),
                    }));
                    continue;
                }
            };

            let created = match self.doc_create(actor, &topic_slug, &item.title, Some(&slug)) {
                Ok(v) => v,
                Err(err) => {
                    failures.push(json!({
                        "source_path": item.source_path,
                        "error": err.to_string(),
                    }));
                    continue;
                }
            };

            let Some(doc_id) = created.get("id").and_then(Value::as_str) else {
                failures.push(json!({
                    "source_path": item.source_path,
                    "error": "doc.create returned missing id",
                }));
                continue;
            };

            let ingest_result = if item.mode == "note_text" {
                let text = fs::read_to_string(&source_path).unwrap_or_default();
                self.doc_update_user(actor, doc_id, &text, "replace")
            } else {
                let doc = self
                    .doc_get(Some(doc_id), None, false, false, false)
                    .and_then(|value| {
                        let topic = value
                            .get("topic")
                            .and_then(Value::as_str)
                            .ok_or_else(|| BtError::Validation("missing topic".to_string()))?;
                        let slug = value
                            .get("slug")
                            .and_then(Value::as_str)
                            .ok_or_else(|| BtError::Validation("missing slug".to_string()))?;
                        Ok((topic.to_string(), slug.to_string()))
                    });

                match doc {
                    Ok((topic, slug)) => {
                        let filename = source_path
                            .file_name()
                            .and_then(|n| n.to_str())
                            .unwrap_or("attachment.bin");
                        let safe_name = filename.replace('/', "_");
                        let rel_attachment =
                            format!("topics/{}/{}/attachments/{}", topic, slug, safe_name);
                        let dest = fs_guard::safe_join(&vault_root, Path::new(&rel_attachment))?;
                        fs::copy(&source_path, &dest)?;
                        let body = format!(
                            "# {}\n\nImported file attached:\n\n- [{}](attachments/{})\n",
                            item.title, safe_name, safe_name
                        );
                        self.doc_update_user(actor, doc_id, &body, "replace")
                    }
                    Err(err) => Err(err),
                }
            };

            if let Err(err) = ingest_result {
                failures.push(json!({
                    "source_path": item.source_path,
                    "doc_id": doc_id,
                    "error": err.to_string(),
                }));
                continue;
            }

            imported.push(json!({
                "doc_id": doc_id,
                "source_path": item.source_path,
                "topic": topic_slug,
                "slug": slug,
                "mode": item.mode,
            }));
        }

        self.audit(
            actor,
            "import.execute",
            &json!({ "item_count": items.len() }),
            None,
            None,
            if failures.is_empty() { "ok" } else { "partial" },
            json!({ "imported_count": imported.len(), "failed_count": failures.len() }),
        )?;

        Ok(json!({
            "ok": failures.is_empty(),
            "imported": imported,
            "failures": failures,
        }))
    }

    pub fn handle_rpc(&self, method: &str, params: Value) -> Result<Value, BtError> {
        match method {
            "vault.init" => {
                let path = params
                    .get("path")
                    .and_then(Value::as_str)
                    .ok_or_else(|| BtError::Validation("path is required".to_string()))?;
                self.init_vault(Path::new(path))
            }
            "vault.open" => {
                let path = params
                    .get("path")
                    .and_then(Value::as_str)
                    .ok_or_else(|| BtError::Validation("path is required".to_string()))?;
                self.open_vault(Path::new(path))
            }
            "vault.open_or_create" => {
                let path = params
                    .get("path")
                    .and_then(Value::as_str)
                    .ok_or_else(|| BtError::Validation("path is required".to_string()))?;
                self.open_vault(Path::new(path))
            }
            "vault.bootstrap_starter" => {
                let actor = parse_actor(&params)?;
                self.vault_bootstrap_starter(&actor)
            }
            "vault.bootstrap_agent_runtime" => {
                let actor = parse_actor(&params)?;
                self.vault_bootstrap_agent_runtime(&actor, required_str(&params, "target")?)
            }
            "vault.status" => self.status(),
            "vault.reindex" => self.reindex(),
            "import.preview" => self.import_preview(optional_str(&params, "root_path")),
            "import.execute" => {
                let actor = parse_actor(&params)?;
                let items = params
                    .get("items")
                    .and_then(Value::as_array)
                    .ok_or_else(|| BtError::Validation("items is required".to_string()))?;
                let parsed = items
                    .iter()
                    .map(|item| {
                        serde_json::from_value::<ImportPreviewItem>(item.clone())
                            .map_err(|e| BtError::Validation(format!("invalid import item: {}", e)))
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                self.import_execute(&actor, &parsed)
            }
            "system.health" => self.system_health(),
            "system.connector_status" => self.system_connector_status(),
            "system.runtime_status" => self.system_runtime_status(
                optional_str(&params, "brand").or_else(|| optional_str(&params, "brand_id")),
            ),
            "system.openclaw_status" => self.system_openclaw_status(),
            "system.automation_status" => self.system_automation_status(),
            "topic.list" => self.topic_list(),
            "topic.create" => {
                let actor = parse_actor(&params)?;
                let topic = params
                    .get("topic")
                    .and_then(Value::as_str)
                    .ok_or_else(|| BtError::Validation("topic is required".to_string()))?;
                self.topic_create(&actor, topic)
            }
            "doc.create" => {
                let actor = parse_actor(&params)?;
                let topic = required_str(&params, "topic")?;
                let title = required_str(&params, "title")?;
                let slug = optional_str(&params, "slug");
                self.doc_create(&actor, topic, title, slug)
            }
            "doc.create_scoped" => {
                let actor = parse_actor(&params)?;
                self.doc_create_scoped(
                    &actor,
                    required_str(&params, "topic")?,
                    required_str(&params, "title")?,
                    optional_str(&params, "slug"),
                    optional_str(&params, "owner_scope")
                        .or_else(|| optional_str(&params, "ownerScope"))
                        .unwrap_or("global"),
                    optional_str(&params, "project_id")
                        .or_else(|| optional_str(&params, "projectId")),
                    optional_str(&params, "project_root")
                        .or_else(|| optional_str(&params, "projectRoot")),
                    optional_str(&params, "knowledge_kind")
                        .or_else(|| optional_str(&params, "knowledgeKind"))
                        .unwrap_or("knowledge"),
                )
            }
            "doc.list" => {
                let topic = optional_str(&params, "topic");
                let include_meta = params
                    .get("includeMeta")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if params.get("knowledge_scope").is_some()
                    || params.get("knowledgeScope").is_some()
                    || params.get("project_id").is_some()
                    || params.get("projectId").is_some()
                {
                    self.doc_list_scoped(
                        topic,
                        include_meta,
                        optional_str(&params, "knowledge_scope")
                            .or_else(|| optional_str(&params, "knowledgeScope")),
                        optional_str(&params, "project_id")
                            .or_else(|| optional_str(&params, "projectId")),
                        params
                            .get("include_global")
                            .or_else(|| params.get("includeGlobal"))
                            .and_then(Value::as_bool),
                    )
                } else {
                    self.doc_list(topic, include_meta)
                }
            }
            "doc.list_scoped" => {
                self.doc_list_scoped(
                    optional_str(&params, "topic"),
                    params
                        .get("includeMeta")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    optional_str(&params, "knowledge_scope")
                        .or_else(|| optional_str(&params, "knowledgeScope")),
                    optional_str(&params, "project_id")
                        .or_else(|| optional_str(&params, "projectId")),
                    params
                        .get("include_global")
                        .or_else(|| params.get("includeGlobal"))
                        .and_then(Value::as_bool),
                )
            }
            "knowledge.register" => {
                let actor = parse_actor(&params)?;
                self.knowledge_register(
                    &actor,
                    required_str(&params, "title")?,
                    required_str(&params, "body")?,
                    optional_str(&params, "owner_scope")
                        .or_else(|| optional_str(&params, "ownerScope"))
                        .or_else(|| optional_str(&params, "scope"))
                        .unwrap_or("global"),
                    optional_str(&params, "project_id")
                        .or_else(|| optional_str(&params, "projectId")),
                    optional_str(&params, "project_root")
                        .or_else(|| optional_str(&params, "projectRoot")),
                    optional_str(&params, "topic"),
                    optional_str(&params, "knowledge_kind")
                        .or_else(|| optional_str(&params, "knowledgeKind"))
                        .or_else(|| optional_str(&params, "kind")),
                    optional_str(&params, "note_scope").or_else(|| optional_str(&params, "noteScope")),
                )
            }
            "doc.get" => {
                let include_user = params
                    .get("includeUser")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                let include_agent = params
                    .get("includeAgent")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                let include_meta = params
                    .get("includeMeta")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                self.doc_get(
                    optional_str(&params, "id"),
                    optional_str(&params, "path"),
                    include_user,
                    include_agent,
                    include_meta,
                )
            }
            "doc.meta.update" => {
                let actor = parse_actor(&params)?;
                self.doc_meta_update(&actor, required_str(&params, "id")?, &params)
            }
            "doc.update_agent" => {
                let actor = parse_actor(&params)?;
                let id = required_str(&params, "id")?;
                let content = required_str(&params, "content")?;
                let mode = required_str(&params, "mode")?;
                let ui_unsaved = params
                    .get("ui_unsaved")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                self.doc_update_agent(&actor, id, content, mode, ui_unsaved)
            }
            "doc.update_user" => {
                let actor = parse_actor(&params)?;
                let id = required_str(&params, "id")?;
                let content = required_str(&params, "content")?;
                let mode = required_str(&params, "mode")?;
                self.doc_update_user(&actor, id, content, mode)
            }
            "doc.plan_handoff.list" => self.doc_plan_handoff_list(
                optional_str(&params, "status"),
                params.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize,
            ),
            "doc.plan_handoff.claim" => {
                let actor = parse_actor(&params)?;
                self.doc_plan_handoff_claim(&actor, required_str(&params, "handoffId")?)
            }
            "doc.plan_handoff.complete" => {
                let actor = parse_actor(&params)?;
                self.doc_plan_handoff_complete(&actor, required_str(&params, "handoffId")?)
            }
            "doc.plan_handoff.release" => {
                let actor = parse_actor(&params)?;
                self.doc_plan_handoff_release(
                    &actor,
                    required_str(&params, "handoffId")?,
                    optional_str(&params, "reason"),
                    optional_str(&params, "requested_user_updated_at"),
                )
            }
            "doc.rename" => {
                let actor = parse_actor(&params)?;
                self.doc_rename(
                    &actor,
                    required_str(&params, "id")?,
                    optional_str(&params, "newTitle"),
                    optional_str(&params, "newSlug"),
                    optional_str(&params, "newTopic"),
                )
            }
            "doc.delete_agent_content" => {
                let actor = parse_actor(&params)?;
                let id = required_str(&params, "id")?;
                let confirm = params
                    .get("confirm")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if !confirm {
                    return Err(BtError::Validation("confirm must be true".to_string()));
                }
                self.doc_delete_agent_content(&actor, id)
            }
            "doc.delete" => {
                let actor = parse_actor(&params)?;
                let id = required_str(&params, "id")?;
                let confirm = params
                    .get("confirm")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if !confirm {
                    return Err(BtError::Validation("confirm must be true".to_string()));
                }
                self.doc_delete(&actor, id)
            }
            "search.query" => {
                let q = required_str(&params, "q")?;
                let scope = required_str(&params, "scope")?;
                let topic = optional_str(&params, "topic");
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
                self.search_query(
                    q,
                    scope,
                    topic,
                    limit,
                    optional_str(&params, "knowledge_scope")
                        .or_else(|| optional_str(&params, "knowledgeScope")),
                    optional_str(&params, "project_id")
                        .or_else(|| optional_str(&params, "projectId")),
                    params
                        .get("include_global")
                        .or_else(|| params.get("includeGlobal"))
                        .and_then(Value::as_bool),
                )
            }

            // Runs (observability)
            "run.create" => {
                let actor = parse_actor(&params)?;
                self.run_create(
                    &actor,
                    required_str(&params, "source")?,
                    required_str(&params, "summary")?,
                    optional_str(&params, "automationId"),
                    optional_str(&params, "occurrenceId"),
                    optional_str(&params, "taskId"),
                    optional_str(&params, "docId"),
                    optional_str(&params, "agent_brand"),
                    optional_str(&params, "agent_name"),
                    optional_str(&params, "agent_session_id"),
                    optional_str(&params, "adapter_kind"),
                    optional_str(&params, "craftship_session_id"),
                    optional_str(&params, "craftship_session_node_id"),
                    optional_str(&params, "company_id"),
                    optional_str(&params, "agent_id"),
                    optional_str(&params, "goal_id"),
                    optional_str(&params, "ticket_id"),
                    params
                        .get("requires_plan")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    params.get("task_step_count").and_then(Value::as_i64),
                    optional_str(&params, "openclaw_session_id"),
                    optional_str(&params, "openclaw_agent_name"),
                )
            }
            "run.update_status" => {
                let actor = parse_actor(&params)?;
                self.run_update_status(
                    &actor,
                    required_str(&params, "runId")?,
                    required_str(&params, "status")?,
                    optional_str(&params, "error_kind"),
                    optional_str(&params, "error_message"),
                    params.get("run_cost_usd").and_then(Value::as_f64),
                )
            }
            "run.attach_artifact" => {
                let actor = parse_actor(&params)?;
                self.run_attach_artifact(
                    &actor,
                    required_str(&params, "runId")?,
                    required_str(&params, "kind")?,
                    optional_str(&params, "filename"),
                    params.get("content").cloned(),
                    optional_str(&params, "content_inline"),
                    params.get("meta").cloned(),
                )
            }
            "run.get" => {
                let include_artifacts = params
                    .get("includeArtifacts")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                self.run_get(required_str(&params, "runId")?, include_artifacts)
            }
            "run.list" => {
                let status = optional_str(&params, "status");
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize;
                self.run_list(status, limit)
            }
            "automation.create" => {
                let actor = parse_actor(&params)?;
                self.automation_create(&actor, params)
            }
            "automation.update" => {
                let actor = parse_actor(&params)?;
                let automation_id = required_str(&params, "automationId")?.to_string();
                self.automation_update(&actor, &automation_id, params)
            }
            "automation.get" => self.automation_get(required_str(&params, "automationId")?),
            "automation.list" => {
                let enabled = params.get("enabled").and_then(Value::as_bool);
                let executor_kind = optional_str(&params, "executor_kind");
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize;
                self.automation_list(enabled, executor_kind, limit)
            }
            "automation.pause" => {
                let actor = parse_actor(&params)?;
                self.automation_pause(&actor, required_str(&params, "automationId")?)
            }
            "automation.resume" => {
                let actor = parse_actor(&params)?;
                self.automation_resume(&actor, required_str(&params, "automationId")?)
            }
            "automation.delete" => {
                let actor = parse_actor(&params)?;
                self.automation_delete(&actor, required_str(&params, "automationId")?)
            }
            "automation.enqueue_now" => {
                let actor = parse_actor(&params)?;
                self.automation_enqueue_now(&actor, required_str(&params, "automationId")?)
            }
            "automation.retry_occurrence" => {
                let actor = parse_actor(&params)?;
                self.automation_retry_occurrence(&actor, required_str(&params, "occurrenceId")?)
            }
            "automation.occurrence_list" => {
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize;
                self.automation_occurrence_list(
                    optional_str(&params, "automationId"),
                    optional_str(&params, "status"),
                    optional_str(&params, "from"),
                    optional_str(&params, "to"),
                    limit,
                )
            }
            "automation.occurrence_get" => {
                self.automation_occurrence_get(required_str(&params, "occurrenceId")?)
            }
            "brand.list" => self.brand_list(),
            "brand.upsert" => {
                let actor = parse_actor(&params)?;
                self.brand_upsert(&actor, params)
            }
            "adapter.list" => self.adapter_list(),
            "adapter.upsert" => {
                let actor = parse_actor(&params)?;
                self.adapter_upsert(&actor, params)
            }
            "company.list" => self.company_list(),
            "company.get" => self.company_get(required_str(&params, "company_id")?),
            "company.upsert" => {
                let actor = parse_actor(&params)?;
                self.company_upsert(&actor, params)
            }
            "agent.list" => self.agent_list(optional_str(&params, "company_id")),
            "agent.get" => self.agent_get(required_str(&params, "agent_id")?),
            "agent.upsert" => {
                let actor = parse_actor(&params)?;
                self.agent_upsert(&actor, params)
            }
            "goal.list" => self.goal_list(
                optional_str(&params, "company_id"),
                optional_str(&params, "parent_goal_id"),
            ),
            "goal.get" => self.goal_get(required_str(&params, "goal_id")?),
            "goal.upsert" => {
                let actor = parse_actor(&params)?;
                self.goal_upsert(&actor, params)
            }
            "ticket.list" => self.ticket_list(
                optional_str(&params, "company_id"),
                optional_str(&params, "status"),
            ),
            "ticket.get" => self.ticket_get(required_str(&params, "ticket_id")?),
            "ticket.upsert" => {
                let actor = parse_actor(&params)?;
                self.ticket_upsert(&actor, params)
            }
            "ticket.thread.message" => {
                let actor = parse_actor(&params)?;
                self.ticket_thread_message(&actor, params)
            }
            "ticket.thread.decision" => {
                let actor = parse_actor(&params)?;
                self.ticket_thread_decision(&actor, params)
            }
            "ticket.thread.trace" => {
                let actor = parse_actor(&params)?;
                self.ticket_thread_trace(&actor, params)
            }
            "ticket.thread.get" => self.ticket_thread_get(
                required_str(&params, "ticket_id")?,
                params.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize,
            ),
            "budget.get_status" => self.budget_get_status(
                optional_str(&params, "company_id").unwrap_or(DEFAULT_COMPANY_ID),
                required_str(&params, "agent_id")?,
            ),
            "budget.override" => {
                let actor = parse_actor(&params)?;
                self.budget_override(&actor, params)
            }
            "plan.submit" => {
                let actor = parse_actor(&params)?;
                self.plan_submit(&actor, params)
            }
            "plan.get" => self.plan_get(required_str(&params, "plan_id")?),
            "plan.list" => self.plan_list(
                optional_str(&params, "ticket_id"),
                optional_str(&params, "task_id"),
                optional_str(&params, "status"),
                params.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize,
            ),
            "plan.review" => {
                let actor = parse_actor(&params)?;
                self.plan_review(&actor, params)
            }
            "plan.request_changes" => {
                let actor = parse_actor(&params)?;
                self.plan_request_changes(&actor, params)
            }
            "runtime.mode.get" => self.runtime_mode_get(required_str(&params, "agent_id")?),
            "runtime.mode.set" => {
                let actor = parse_actor(&params)?;
                self.runtime_mode_set(&actor, params)
            }
            "governance.approval.create" => {
                let actor = parse_actor(&params)?;
                self.governance_approval_create(&actor, params)
            }
            "governance.approval.review" => {
                let actor = parse_actor(&params)?;
                self.governance_approval_review(&actor, params)
            }
            "governance.approval.list" => self.governance_approval_list(
                optional_str(&params, "company_id"),
                optional_str(&params, "status"),
                params.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize,
            ),
            "config.revision.list" => self.config_revision_list(
                optional_str(&params, "company_id").unwrap_or(DEFAULT_COMPANY_ID),
                optional_str(&params, "config_scope"),
                params.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize,
            ),
            "config.revision.rollback" => {
                let actor = parse_actor(&params)?;
                self.config_revision_rollback(&actor, params)
            }
            "crafting.framework.list" => {
                let include_archived = params
                    .get("include_archived")
                    .or_else(|| params.get("includeArchived"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                self.crafting_framework_list(include_archived)
            }
            "crafting.framework.get" => {
                self.crafting_framework_get(required_str(&params, "framework_id")?)
            }
            "crafting.framework.create" => {
                let actor = parse_actor(&params)?;
                self.crafting_framework_create(&actor, params)
            }
            "crafting.framework.update" => {
                let actor = parse_actor(&params)?;
                self.crafting_framework_update(&actor, params)
            }
            "crafting.framework.archive" => {
                let actor = parse_actor(&params)?;
                self.crafting_framework_archive(
                    &actor,
                    required_str(&params, "framework_id")?,
                    params
                        .get("archived")
                        .and_then(Value::as_bool)
                        .unwrap_or(true),
                )
            }
            "crafting.framework.render_payload" => {
                self.crafting_framework_render_payload(required_str(&params, "framework_id")?)
            }
            "crafting.craftship.list" => {
                let include_archived = params
                    .get("include_archived")
                    .or_else(|| params.get("includeArchived"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                self.craftship_list(include_archived)
            }
            "crafting.craftship.get" => self.craftship_get(required_str(&params, "craftship_id")?),
            "crafting.craftship.default.get" => self.craftship_default_get(),
            "crafting.craftship.default.set" => {
                let actor = parse_actor(&params)?;
                self.craftship_default_set(&actor, optional_str(&params, "craftship_id"))
            }
            "crafting.craftship.create" => {
                let actor = parse_actor(&params)?;
                self.craftship_create(&actor, params)
            }
            "crafting.craftship.update" => {
                let actor = parse_actor(&params)?;
                self.craftship_update(&actor, params)
            }
            "crafting.craftship.duplicate" => {
                let actor = parse_actor(&params)?;
                self.craftship_duplicate(
                    &actor,
                    required_str(&params, "craftship_id")?,
                    optional_str(&params, "name"),
                )
            }
            "crafting.craftship.archive" => {
                let actor = parse_actor(&params)?;
                self.craftship_archive(
                    &actor,
                    required_str(&params, "craftship_id")?,
                    params
                        .get("archived")
                        .and_then(Value::as_bool)
                        .unwrap_or(true),
                )
            }
            "crafting.craftship.session.list" => {
                let include_archived = params
                    .get("include_archived")
                    .or_else(|| params.get("includeArchived"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                self.craftship_session_list(
                    optional_str(&params, "craftship_id"),
                    optional_str(&params, "status"),
                    include_archived,
                    params.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize,
                )
            }
            "crafting.craftship.session.get" => {
                self.craftship_session_get(required_str(&params, "craftship_session_id")?)
            }
            "crafting.craftship.session.rename" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_rename(
                    &actor,
                    required_str(&params, "craftship_session_id")?,
                    required_str(&params, "name")?,
                )
            }
            "crafting.craftship.session.delete" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_delete(
                    &actor,
                    required_str(&params, "craftship_session_id")?,
                )
            }
            "crafting.craftship.session.digest" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_digest(
                    &actor,
                    required_str(&params, "craftship_session_id")?,
                    optional_bool(&params, "force").unwrap_or(false),
                )
            }
            "crafting.craftship.session.set_status" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_set_status(
                    &actor,
                    required_str(&params, "craftship_session_id")?,
                    required_str(&params, "status")?,
                )
            }
            "crafting.craftship.session.bind_node_runtime" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_bind_node_runtime(&actor, params)
            }
            "crafting.craftship.session.node_runtime.update" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_node_runtime_update(&actor, params)
            }
            "crafting.craftship.session.message.send" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_message_send(&actor, params)
            }
            "crafting.craftship.session.message.ack" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_message_ack(&actor, params)
            }
            "crafting.craftship.session.message.inbox" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_message_inbox(&actor, params)
            }
            "crafting.craftship.session.work_item.create" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_work_item_create(&actor, params)
            }
            "crafting.craftship.session.work_item.list" => {
                self.craftship_session_work_item_list(params)
            }
            "crafting.craftship.session.work_item.assign" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_work_item_assign(&actor, params)
            }
            "crafting.craftship.session.work_item.claim" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_work_item_claim(&actor, params)
            }
            "crafting.craftship.session.work_item.update" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_work_item_update(&actor, params)
            }
            "crafting.craftship.session.work_item.complete" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_work_item_complete(&actor, params)
            }
            "crafting.craftship.session.work_item.cancel" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_work_item_cancel(&actor, params)
            }
            "crafting.craftship.session.orchestration.sync_from_doc" => {
                let actor = parse_actor(&params)?;
                self.craftship_session_orchestration_sync_from_doc(&actor, params)
            }
            // ── Peer communication ──────────────────────────────────
            "peers.list" => {
                let actor = parse_actor(&params)?;
                self.peers_list(&actor, params)
            }
            "peers.send" => {
                let actor = parse_actor(&params)?;
                self.peers_send(&actor, params)
            }
            "peers.poll" => {
                let actor = parse_actor(&params)?;
                self.peers_poll(&actor, params)
            }
            "peers.set_summary" => {
                let actor = parse_actor(&params)?;
                self.peers_set_summary(&actor, params)
            }
            "automation.claim_occurrence" => {
                let actor = parse_actor(&params)?;
                self.automation_claim_occurrence(
                    &actor,
                    required_str(&params, "occurrenceId")?,
                    required_str(&params, "leaseOwner")?,
                    params
                        .get("leaseSeconds")
                        .and_then(Value::as_i64)
                        .unwrap_or(120),
                )
            }
            "automation.heartbeat_occurrence" => {
                let actor = parse_actor(&params)?;
                self.automation_heartbeat_occurrence(
                    &actor,
                    required_str(&params, "occurrenceId")?,
                    required_str(&params, "leaseOwner")?,
                    params
                        .get("leaseSeconds")
                        .and_then(Value::as_i64)
                        .unwrap_or(120),
                )
            }
            "automation.start_occurrence" => {
                let actor = parse_actor(&params)?;
                self.automation_start_occurrence(
                    &actor,
                    required_str(&params, "occurrenceId")?,
                    required_str(&params, "leaseOwner")?,
                    optional_str(&params, "runId"),
                )
            }
            "automation.complete_occurrence" => {
                let actor = parse_actor(&params)?;
                self.automation_complete_occurrence(
                    &actor,
                    required_str(&params, "occurrenceId")?,
                    required_str(&params, "leaseOwner")?,
                    required_str(&params, "status")?,
                    optional_str(&params, "runId"),
                    optional_str(&params, "failure_kind"),
                    optional_str(&params, "failure_message"),
                    params.get("shared_context").cloned(),
                    optional_str(&params, "artifact_path"),
                )
            }
            "worker.cursor_touch" => {
                let actor = parse_actor(&params)?;
                self.worker_cursor_touch(
                    &actor,
                    required_str(&params, "workerId")?,
                    required_str(&params, "consumerGroup")?,
                    required_str(&params, "executorKind")?,
                    params
                        .get("lastEventId")
                        .and_then(Value::as_i64)
                        .unwrap_or(0),
                    required_str(&params, "status")?,
                    params
                        .get("leaseCount")
                        .and_then(Value::as_i64)
                        .unwrap_or(0),
                )
            }
            "worker.cursor_get" => self.worker_cursor_get(required_str(&params, "workerId")?),
            "calendar.range" => self.calendar_range(
                required_str(&params, "from")?,
                required_str(&params, "to")?,
                required_str(&params, "timezone")?,
                optional_str(&params, "agent"),
                optional_str(&params, "status"),
            ),
            "monitor.run_evaluation" => {
                let actor = parse_actor(&params)?;
                self.monitor_run_evaluation(&actor, required_str(&params, "runId")?)
            }
            "monitor.overnight_summary" => {
                let actor = parse_actor(&params)?;
                self.monitor_overnight_summary(
                    &actor,
                    required_str(&params, "from")?,
                    required_str(&params, "to")?,
                    required_str(&params, "timezone")?,
                )
            }
            "shared_context.get" => self.shared_context_get(required_str(&params, "contextKey")?),
            "context.compact" => {
                let actor = parse_actor(&params)?;
                self.context_compact(
                    &actor,
                    required_str(&params, "brand")?,
                    optional_str(&params, "session_id")
                        .or_else(|| optional_str(&params, "sessionId")),
                    optional_str(&params, "doc_id").or_else(|| optional_str(&params, "docId")),
                    optional_bool(&params, "force").unwrap_or(false),
                )
            }
            "context.resolve" => self.context_resolve(
                optional_str(&params, "brand"),
                optional_str(&params, "session_id").or_else(|| optional_str(&params, "sessionId")),
                optional_str(&params, "doc_id").or_else(|| optional_str(&params, "docId")),
                optional_str(&params, "mode"),
            ),
            "context.get" => self.context_get(
                optional_str(&params, "context_id")
                    .or_else(|| optional_str(&params, "contextId"))
                    .ok_or_else(|| BtError::Validation("context_id is required".to_string()))?,
            ),
            "context.list" => self.context_list(
                optional_str(&params, "brand"),
                optional_str(&params, "session_id").or_else(|| optional_str(&params, "sessionId")),
                optional_str(&params, "doc_id").or_else(|| optional_str(&params, "docId")),
                params.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize,
            ),

            "task.create" => {
                let actor = parse_actor(&params)?;
                self.task_create(
                    &actor,
                    required_str(&params, "title")?,
                    optional_str(&params, "docId"),
                    optional_str(&params, "due"),
                    optional_str(&params, "priority"),
                )
            }
            "task.complete" => {
                let actor = parse_actor(&params)?;
                self.task_complete(&actor, required_str(&params, "taskId")?)
            }
            "task.plan.sync_from_doc" => {
                let actor = parse_actor(&params)?;
                self.task_plan_sync_from_doc(&actor, required_str(&params, "docId")?)
            }
            "task.list" => {
                let status = optional_str(&params, "status");
                let topic = optional_str(&params, "topic");
                let doc_id = optional_str(&params, "docId");
                let lane = optional_str(&params, "lane");
                let include_archived = params
                    .get("include_archived")
                    .or_else(|| params.get("includeArchived"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize;
                self.task_list(status, topic, doc_id, lane, include_archived, limit)
            }
            "task.remove" => {
                let actor = parse_actor(&params)?;
                self.task_remove(&actor, required_str(&params, "taskId")?)
            }
            "task.steer_into_active" => {
                let actor = parse_actor(&params)?;
                self.task_steer_into_active(&actor, required_str(&params, "taskId")?)
            }
            "task.verify_and_archive" => {
                let actor = parse_actor(&params)?;
                self.task_verify_and_archive(
                    &actor,
                    required_str(&params, "taskId")?,
                    required_str(&params, "verification_summary")?,
                    optional_str(&params, "runId"),
                )
            }
            "task.edit_handoff.create" => {
                let actor = parse_actor(&params)?;
                self.task_edit_handoff_create(&actor, required_str(&params, "taskId")?)
            }
            "task.edit_handoff.list" => self.task_edit_handoff_list(
                optional_str(&params, "status"),
                params.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize,
            ),
            "task.edit_handoff.claim" => {
                let actor = parse_actor(&params)?;
                self.task_edit_handoff_claim(&actor, required_str(&params, "handoffId")?)
            }
            "task.edit_handoff.complete" => {
                let actor = parse_actor(&params)?;
                self.task_edit_handoff_complete(&actor, required_str(&params, "handoffId")?)
            }
            "suggestion.create" => {
                let actor = parse_actor(&params)?;
                let patch = params
                    .get("patch")
                    .ok_or_else(|| BtError::Validation("patch is required".to_string()))?
                    .clone();
                self.suggestion_create(
                    &actor,
                    required_str(&params, "docId")?,
                    patch,
                    required_str(&params, "summary")?,
                )
            }
            "suggestion.list" => self.suggestion_list(
                optional_str(&params, "docId"),
                optional_str(&params, "status"),
            ),
            "suggestion.apply" => {
                let actor = parse_actor(&params)?;
                self.suggestion_apply(&actor, required_str(&params, "suggestionId")?)
            }
            "graph.links" => self.graph_links(required_str(&params, "docId")?),
            "graph.refresh" => {
                self.refresh_graph_projection()?;
                Ok(json!({ "refreshed": true }))
            }
            "graph.snapshot" => self.graph_snapshot(
                optional_str(&params, "focusNodeId"),
                params.get("includeTypes"),
                optional_str(&params, "from"),
                optional_str(&params, "to"),
                optional_str(&params, "search"),
                params
                    .get("maxNodes")
                    .and_then(Value::as_u64)
                    .map(|value| value as usize),
                optional_str(&params, "knowledge_scope")
                    .or_else(|| optional_str(&params, "knowledgeScope")),
                optional_str(&params, "project_id")
                    .or_else(|| optional_str(&params, "projectId")),
                params
                    .get("include_global")
                    .or_else(|| params.get("includeGlobal"))
                    .and_then(Value::as_bool),
            ),
            "graph.node_get" => self.graph_node_get(required_str(&params, "nodeId")?),
            "agent.status" => self
                .agent_status(
                    params.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize,
                    optional_str(&params, "knowledge_scope")
                        .or_else(|| optional_str(&params, "knowledgeScope")),
                    optional_str(&params, "project_id")
                        .or_else(|| optional_str(&params, "projectId")),
                    params
                        .get("include_global")
                        .or_else(|| params.get("includeGlobal"))
                        .and_then(Value::as_bool),
                ),
            "agent.context_event.record" => {
                let actor = parse_actor(&params)?;
                self.agent_context_event_record(&actor, &params)
            }
            "audit.tail" => {
                let since = optional_str(&params, "since");
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize;
                self.audit_tail(since, limit)
            }
            "events.tail" => {
                let after = params
                    .get("afterEventId")
                    .or_else(|| params.get("after_event_id"))
                    .and_then(Value::as_i64);
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize;
                self.events_tail(after, limit)
            }
            "events.latest" => {
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize;
                self.events_latest(limit)
            }
            "events.subscribe" => {
                self.events_subscribe(params.get("filters").cloned().unwrap_or(Value::Null))
            }
            "auth.agent_validate" => self.auth_agent_validate(required_str(&params, "token")?),
            "token.create" => {
                let agent_name = required_str(&params, "agent_name")?;
                let caps = params
                    .get("caps")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(ToOwned::to_owned))
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                self.token_create(agent_name, caps)
            }
            "token.rotate" => self.token_rotate(required_str(&params, "token_id")?),
            "token.revoke" => self.token_revoke(required_str(&params, "token_id")?),
            "token.list" => self.token_list(),

            _ => Err(BtError::Rpc(format!("unknown method: {}", method))),
        }
    }

    pub fn topic_list(&self) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let topics_path = fs_guard::safe_join(&root, Path::new("topics"))?;
        let mut topics = Vec::new();
        if topics_path.exists() {
            for entry in fs::read_dir(topics_path)? {
                let entry = entry?;
                if entry.file_type()?.is_dir() {
                    topics.push(entry.file_name().to_string_lossy().to_string());
                }
            }
        }
        topics.sort();
        Ok(json!({ "topics": topics }))
    }

    pub fn topic_create(&self, actor: &Actor, topic: &str) -> Result<Value, BtError> {
        let topic_slug = fs_guard::sanitize_segment(topic)?;
        self.apply_write(actor, WriteOperation::CreateTopic)?;

        let root = self.require_vault()?;
        let topic_path = fs_guard::safe_join(&root, Path::new(&format!("topics/{}", topic_slug)))?;
        fs::create_dir_all(&topic_path)?;

        self.audit(
            actor,
            "topic.create",
            &json!({ "topic": topic_slug }),
            None,
            None,
            "ok",
            json!({}),
        )?;

        Ok(json!({
            "topic": topic_slug,
            "created": true,
        }))
    }

    pub fn doc_create(
        &self,
        actor: &Actor,
        topic: &str,
        title: &str,
        slug: Option<&str>,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::CreateDocument)?;

        let topic_slug = fs_guard::sanitize_segment(topic)?;
        let doc_slug = fs_guard::sanitize_segment(slug.unwrap_or(title))?;
        let id = Uuid::new_v4();
        let now = Self::now();

        let root = self.require_vault()?;
        let dir_rel = format!("topics/{}/{}", topic_slug, doc_slug);
        let dir = fs_guard::safe_join(&root, Path::new(&dir_rel))?;
        if dir.exists() {
            return Err(BtError::Conflict(format!(
                "document folder {} already exists",
                dir_rel
            )));
        }
        fs::create_dir_all(dir.join("attachments"))?;

        let user_rel = format!("{}/user.md", dir_rel);
        let agent_rel = format!("{}/agent.md", dir_rel);
        let meta_rel = format!("{}/meta.json", dir_rel);

        let user_path = fs_guard::safe_join(&root, Path::new(&user_rel))?;
        let agent_path = fs_guard::safe_join(&root, Path::new(&agent_rel))?;
        let meta_path = fs_guard::safe_join(&root, Path::new(&meta_rel))?;

        let user_content = format!("# {}\n\n", title);
        let agent_content = "# Agent Notes\n\n".to_string();

        fs_guard::atomic_write(&root, &user_path, &user_content)?;
        fs_guard::atomic_write(&root, &agent_path, &agent_content)?;

        let meta = DocMeta {
            id,
            title: title.to_string(),
            topic: topic_slug.clone(),
            created_at: now,
            updated_at: now,
            tags: Vec::new(),
            links_out: Vec::new(),
            status: None,
            pair: PairPaths {
                user_path: user_rel.clone(),
                agent_path: agent_rel.clone(),
            },
        };

        let meta_json =
            serde_json::to_string_pretty(&meta).map_err(|e| BtError::Validation(e.to_string()))?;
        fs_guard::atomic_write(&root, &meta_path, &meta_json)?;

        let conn = self.open_conn()?;
        db::upsert_doc(
            &conn,
            &DocRecord {
                id: id.to_string(),
                topic: topic_slug.clone(),
                slug: doc_slug.clone(),
                title: title.to_string(),
                user_path: user_rel.clone(),
                agent_path: agent_rel.clone(),
                created_at: now,
                updated_at: now,
                owner_scope: "global".to_string(),
                project_id: None,
                project_root: None,
                knowledge_kind: "knowledge".to_string(),
            },
            &Self::sha(&user_content),
            &Self::sha(&agent_content),
        )?;
        db::upsert_doc_meta(&conn, &id.to_string(), &[], &[], None, now)?;
        db::refresh_fts(&conn, &id.to_string(), &user_content, &agent_content)?;
        self.reindex_doc_embeddings(&conn, &id.to_string(), &user_content, &agent_content)?;

        self.audit(
            actor,
            "doc.create",
            &json!({ "topic": topic_slug, "title": title, "slug": doc_slug }),
            Some(&id.to_string()),
            None,
            "ok",
            json!({ "user_path": user_rel, "agent_path": agent_rel }),
        )?;

        Ok(json!({
            "id": id,
            "topic": topic_slug,
            "slug": doc_slug,
            "title": title,
            "user_path": user_rel,
            "agent_path": agent_rel,
        }))
    }

    pub fn doc_create_scoped(
        &self,
        actor: &Actor,
        topic: &str,
        title: &str,
        slug: Option<&str>,
        owner_scope: &str,
        project_id: Option<&str>,
        project_root: Option<&str>,
        knowledge_kind: &str,
    ) -> Result<Value, BtError> {
        let normalized_scope = normalize_owner_scope(Some(owner_scope), project_id);
        let normalized_kind = normalize_knowledge_kind(Some(knowledge_kind));
        let created = self.doc_create(actor, topic, title, slug)?;
        let id = created
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| BtError::Validation("doc.create returned no id".to_string()))?
            .to_string();
        let conn = self.open_conn()?;
        db::update_doc_scope(
            &conn,
            &id,
            &normalized_scope,
            if normalized_scope == "project" {
                project_id
            } else {
                None
            },
            if normalized_scope == "project" {
                project_root
            } else {
                None
            },
            &normalized_kind,
        )?;
        self.maybe_refresh_graph_projection()?;
        Ok(json!({
            "id": id,
            "topic": created.get("topic"),
            "slug": created.get("slug"),
            "title": created.get("title"),
            "user_path": created.get("user_path"),
            "agent_path": created.get("agent_path"),
            "owner_scope": normalized_scope,
            "project_id": if normalized_scope == "project" { project_id } else { None },
            "project_root": if normalized_scope == "project" { project_root } else { None },
            "knowledge_kind": normalized_kind,
        }))
    }

    pub fn knowledge_register(
        &self,
        actor: &Actor,
        title: &str,
        body: &str,
        owner_scope: &str,
        project_id: Option<&str>,
        project_root: Option<&str>,
        topic: Option<&str>,
        knowledge_kind: Option<&str>,
        note_scope: Option<&str>,
    ) -> Result<Value, BtError> {
        let normalized_scope = normalize_owner_scope(Some(owner_scope), project_id);
        let normalized_kind = normalize_knowledge_kind(knowledge_kind);
        let topic = topic.unwrap_or(match normalized_scope.as_str() {
            "project" => "project",
            _ => "global",
        });
        let created = self.doc_create_scoped(
            actor,
            topic,
            title,
            None,
            &normalized_scope,
            project_id,
            project_root,
            &normalized_kind,
        )?;
        let id = created
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| BtError::Validation("doc.create_scoped returned no id".to_string()))?;
        let note_scope = note_scope.unwrap_or(match actor {
            Actor::Agent { .. } => "agent",
            _ => "user",
        });
        match note_scope {
            "agent" => {
                self.doc_update_agent(actor, id, body, "replace", false)?;
            }
            _ => {
                self.doc_update_user(actor, id, body, "replace")?;
            }
        }
        Ok(json!({
            "registered": true,
            "doc": created,
            "note_scope": note_scope,
        }))
    }

    pub fn doc_list(&self, topic: Option<&str>, include_meta: bool) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let docs = db::list_docs(&conn, topic)?;
        let root = self.require_vault()?;

        let mut out = Vec::new();
        for doc in docs {
            let agent_active = db::has_recent_agent_activity(&conn, &doc.id, 180)?;
            let planning = self.planning_status_for_doc(&root, &doc)?;
            let mut obj = json!({
                "id": doc.id,
                "topic": doc.topic,
                "slug": doc.slug,
                "title": doc.title,
                "user_path": doc.user_path,
                "agent_path": doc.agent_path,
                "created_at": doc.created_at,
                "updated_at": doc.updated_at,
                "agent_active": agent_active,
                "planning": planning,
                "owner_scope": doc.owner_scope,
                "project_id": doc.project_id,
                "project_root": doc.project_root,
                "knowledge_kind": doc.knowledge_kind,
            });

            if include_meta {
                let meta = self.load_meta_by_doc(&doc.id)?;
                if let Some(meta) = meta {
                    obj["meta"] = serde_json::to_value(meta)
                        .map_err(|e| BtError::Validation(e.to_string()))?;
                }
            }
            out.push(obj);
        }

        Ok(json!({ "docs": out }))
    }

    pub fn doc_list_scoped(
        &self,
        topic: Option<&str>,
        include_meta: bool,
        knowledge_scope: Option<&str>,
        project_id: Option<&str>,
        include_global: Option<bool>,
    ) -> Result<Value, BtError> {
        let filter = KnowledgeScopeFilter::from_parts(knowledge_scope, project_id, include_global);
        let mut value = self.doc_list(topic, include_meta)?;
        if let Some(docs) = value.get_mut("docs").and_then(Value::as_array_mut) {
            docs.retain(|doc| {
                let owner_scope = doc
                    .get("owner_scope")
                    .and_then(Value::as_str)
                    .unwrap_or("global");
                let owner_project_id = doc.get("project_id").and_then(Value::as_str);
                KnowledgeScopeFilter::matches_parts(
                    &filter.mode,
                    filter.project_id.as_deref(),
                    filter.include_global,
                    owner_scope,
                    owner_project_id,
                )
            });
        }
        Ok(value)
    }

    pub fn doc_get(
        &self,
        id: Option<&str>,
        path: Option<&str>,
        include_user: bool,
        include_agent: bool,
        include_meta: bool,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let doc = if let Some(id) = id {
            db::get_doc(&conn, id)?
        } else if let Some(path) = path {
            let docs = db::list_docs(&conn, None)?;
            docs.into_iter()
                .find(|d| d.user_path == path || d.agent_path == path)
        } else {
            None
        }
        .ok_or_else(|| BtError::NotFound("document not found".to_string()))?;

        let root = self.require_vault()?;
        let user_path = fs_guard::safe_join(&root, Path::new(&doc.user_path))?;
        let agent_path = fs_guard::safe_join(&root, Path::new(&doc.agent_path))?;
        let planning = self.planning_status_for_doc(&root, &doc)?;

        let mut out = json!({
            "id": doc.id,
            "topic": doc.topic,
            "slug": doc.slug,
            "title": doc.title,
            "user_path": doc.user_path,
            "agent_path": doc.agent_path,
            "created_at": doc.created_at,
            "updated_at": doc.updated_at,
            "agent_active": db::has_recent_agent_activity(&conn, &doc.id, 180)?,
            "planning": planning,
            "owner_scope": doc.owner_scope,
            "project_id": doc.project_id,
            "project_root": doc.project_root,
            "knowledge_kind": doc.knowledge_kind,
        });

        if include_user {
            out["user_content"] = Value::String(fs::read_to_string(user_path)?);
        }
        if include_agent {
            out["agent_content"] = Value::String(fs::read_to_string(agent_path)?);
        }
        if include_meta {
            if let Some(meta) = self.load_meta_by_doc(&doc.id)? {
                out["meta"] =
                    serde_json::to_value(meta).map_err(|e| BtError::Validation(e.to_string()))?;
            }
        }

        Ok(out)
    }

    pub fn doc_update_agent(
        &self,
        actor: &Actor,
        id: &str,
        content: &str,
        mode: &str,
        ui_unsaved: bool,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::UpdateAgentNote)?;

        let conn = self.open_conn()?;
        let doc = db::get_doc(&conn, id)?
            .ok_or_else(|| BtError::NotFound(format!("doc {} not found", id)))?;
        let root = self.require_vault()?;

        let agent_path = fs_guard::safe_join(&root, Path::new(&doc.agent_path))?;
        let user_path = fs_guard::safe_join(&root, Path::new(&doc.user_path))?;
        let mut existing = fs::read_to_string(&agent_path)?;

        let _lock = fs_guard::acquire_doc_lock(&root, id, &actor.actor_id())?;

        let next = match mode {
            "replace" => content.to_string(),
            "append" => {
                existing.push_str(content);
                existing
            }
            _ => {
                return Err(BtError::Validation(
                    "mode must be replace|append".to_string(),
                ))
            }
        };

        let mut conflict_path: Option<String> = None;
        if ui_unsaved {
            let stamp = Utc::now().format("%Y%m%d%H%M%S").to_string();
            let parent = agent_path
                .parent()
                .ok_or_else(|| BtError::Io("agent path has no parent".to_string()))?;
            let conflict = parent.join(format!("agent.md.conflict-{}", stamp));
            fs_guard::atomic_write(&root, &conflict, &next)?;
            conflict_path = Some(
                conflict
                    .strip_prefix(&root)
                    .map_err(|_| BtError::PathEscape(conflict.display().to_string()))?
                    .to_string_lossy()
                    .replace('\\', "/"),
            );
        } else {
            fs_guard::atomic_write(&root, &agent_path, &next)?;
            let user_content = fs::read_to_string(user_path)?;
            db::refresh_fts(&conn, id, &user_content, &next)?;
            self.reindex_doc_embeddings(&conn, id, &user_content, &next)?;
        }

        let mut meta = self
            .load_meta_by_doc(id)?
            .ok_or_else(|| BtError::NotFound(format!("meta for {} missing", id)))?;
        meta.updated_at = Utc::now();
        self.save_meta(&meta)?;

        db::update_doc_title(&conn, id, &doc.title, meta.updated_at)?;

        if let Actor::Agent { token_id } = actor {
            db::touch_agent_activity(&conn, id, token_id, Utc::now())?;
        }

        self.audit(
            actor,
            "doc.update_agent",
            &json!({ "id": id, "mode": mode, "ui_unsaved": ui_unsaved }),
            Some(id),
            None,
            "ok",
            json!({ "conflict_path": conflict_path }),
        )?;

        if !ui_unsaved {
            if parse_dome_task_plan(&next).ok().flatten().is_some() {
                let _ = self.task_plan_sync_from_doc(actor, id);
            }
        }

        let planning = self.planning_status_for_doc(&root, &doc)?;

        Ok(json!({
            "id": id,
            "updated": true,
            "conflict_path": conflict_path,
            "planning": planning,
        }))
    }

    pub fn doc_update_user(
        &self,
        actor: &Actor,
        id: &str,
        content: &str,
        mode: &str,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::UpdateUserNote)?;

        let conn = self.open_conn()?;
        let doc = db::get_doc(&conn, id)?
            .ok_or_else(|| BtError::NotFound(format!("doc {} not found", id)))?;
        let root = self.require_vault()?;

        let user_path = fs_guard::safe_join(&root, Path::new(&doc.user_path))?;
        let agent_path = fs_guard::safe_join(&root, Path::new(&doc.agent_path))?;
        let mut existing = fs::read_to_string(&user_path)?;

        let _lock = fs_guard::acquire_doc_lock(&root, id, &actor.actor_id())?;

        let next = match mode {
            "replace" => content.to_string(),
            "append" => {
                existing.push_str(content);
                existing
            }
            _ => {
                return Err(BtError::Validation(
                    "mode must be replace|append".to_string(),
                ))
            }
        };

        fs_guard::atomic_write(&root, &user_path, &next)?;

        let agent_content = fs::read_to_string(agent_path)?;
        db::refresh_fts(&conn, id, &next, &agent_content)?;
        self.reindex_doc_embeddings(&conn, id, &next, &agent_content)?;

        let mut meta = self
            .load_meta_by_doc(id)?
            .ok_or_else(|| BtError::NotFound(format!("meta for {} missing", id)))?;
        meta.updated_at = Utc::now();
        self.save_meta(&meta)?;

        db::update_doc_title(&conn, id, &doc.title, meta.updated_at)?;

        // audit_no_refresh: doc_update_user is the first handler in the
        // handoff chain. Using audit() here triggered refresh_graph_projection
        // which holds the WAL write lock for the entire O(vault) scan. The
        // extension's craftship_session_launch fires shortly after and its
        // BEGIN IMMEDIATE blocks on that lock, burning through the timeout.
        // The graph catches up on the next throttled cycle.
        self.audit_no_refresh(
            actor,
            "doc.update_user",
            &json!({ "id": id, "mode": mode }),
            Some(id),
            None,
            "ok",
            json!({}),
        )?;

        let planning = self.planning_status_for_doc(&root, &doc)?;
        let planning_state = planning
            .get("state")
            .and_then(Value::as_str)
            .map(str::to_string);
        let mut plan_handoff = Value::Null;
        // (Bug H) Always populate `planning_reason` so the macOS shell can
        // distinguish "saved, plan handoff dispatched" from "saved, plan
        // already up to date". Previously the response only signalled the
        // first case via `plan_handoff`; the second case looked identical
        // to a no-op success.
        let planning_reason = match planning_state.as_deref() {
            Some("needs_plan") => "plan_handoff_dispatched",
            Some(state) => match state {
                "up_to_date" => "already_in_plan",
                "has_plan" => "already_in_plan",
                other if !other.is_empty() => other,
                _ => "saved",
            },
            None => "saved",
        };
        if planning_state.as_deref() == Some("needs_plan") {
            let handoff = self.upsert_doc_plan_handoff_for_doc(actor, &conn, id, &planning)?;
            plan_handoff =
                serde_json::to_value(handoff).map_err(|e| BtError::Validation(e.to_string()))?;
            // Use _no_refresh: the audit() call above already covers the
            // throttled graph rebuild. Doubling up here was adding a second
            // O(vault) rebuild to every note save that triggers a handoff.
            self.emit_event_no_refresh(
                actor,
                "doc.plan_needs_refresh",
                Some(id),
                None,
                json!({
                    "doc_id": id,
                    "reason": planning.get("reason").cloned().unwrap_or(Value::Null),
                }),
                None,
            )?;
        }

        Ok(json!({
            "id": id,
            "updated": true,
            "planning": planning,
            "plan_handoff": plan_handoff,
            "planning_reason": planning_reason,
        }))
    }

    fn upsert_doc_plan_handoff_for_doc(
        &self,
        actor: &Actor,
        conn: &rusqlite::Connection,
        doc_id: &str,
        planning: &Value,
    ) -> Result<DocPlanHandoff, BtError> {
        let reason = planning
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("missing_agent_plan")
            .to_string();
        let requested_user_updated_at = planning
            .get("user_updated_at")
            .and_then(Value::as_str)
            .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
            .map(|value| value.with_timezone(&Utc))
            .unwrap_or_else(Utc::now);
        let now = Utc::now();

        if let Some(mut existing) = db::get_active_doc_plan_handoff_for_doc(conn, doc_id)? {
            let should_requeue_claim = existing.status == "claimed"
                && existing.requested_user_updated_at != requested_user_updated_at;
            existing.reason = reason;
            existing.requested_user_updated_at = requested_user_updated_at;
            existing.updated_at = now;
            existing.completed_at = None;
            existing.completed_by = None;
            if should_requeue_claim {
                existing.status = "pending".to_string();
                existing.claimed_at = None;
                existing.claimed_by = None;
            }
            db::update_doc_plan_handoff(conn, &existing)?;
            return db::get_doc_plan_handoff(conn, &existing.handoff_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "doc plan handoff {} disappeared after update",
                    existing.handoff_id
                ))
            });
        }

        let handoff = DocPlanHandoff {
            handoff_id: format!("dph_{}", Uuid::new_v4().simple()),
            doc_id: doc_id.to_string(),
            status: "pending".to_string(),
            reason,
            requested_user_updated_at,
            created_by: actor.actor_id(),
            created_at: now,
            updated_at: now,
            claimed_at: None,
            claimed_by: None,
            completed_at: None,
            completed_by: None,
        };
        db::insert_doc_plan_handoff(conn, &handoff)?;
        Ok(handoff)
    }

    pub fn doc_plan_handoff_list(
        &self,
        status: Option<&str>,
        limit: usize,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let handoffs = db::list_doc_plan_handoffs(&conn, status, limit)?;
        Ok(json!({ "handoffs": handoffs }))
    }

    pub fn doc_plan_handoff_claim(
        &self,
        actor: &Actor,
        handoff_id: &str,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let mut handoff = db::get_doc_plan_handoff(&conn, handoff_id)?.ok_or_else(|| {
            BtError::NotFound(format!("doc plan handoff {} not found", handoff_id))
        })?;
        // Idempotent: if the same actor already claimed this handoff
        // (e.g. the previous attempt succeeded server-side but the
        // response timed out before reaching the client), return the
        // existing record instead of erroring.
        if handoff.status == "claimed" {
            if handoff.claimed_by.as_deref() == Some(&actor.actor_id()) {
                return Ok(json!({ "handoff": handoff }));
            }
            return Err(BtError::Validation(
                "handoff is already claimed by another actor".to_string(),
            ));
        }
        if handoff.status != "pending" {
            return Err(BtError::Validation(
                "only pending doc plan handoffs can be claimed".to_string(),
            ));
        }
        let now = Utc::now();
        handoff.status = "claimed".to_string();
        handoff.claimed_at = Some(now);
        handoff.claimed_by = Some(actor.actor_id());
        handoff.updated_at = now;
        db::update_doc_plan_handoff(&conn, &handoff)?;
        let claimed = db::get_doc_plan_handoff(&conn, handoff_id)?.ok_or_else(|| {
            BtError::NotFound(format!("doc plan handoff {} not found", handoff_id))
        })?;
        // No-refresh variants: the claim is a status flip on a handoff
        // record and does not alter graph topology. The O(vault)-cost
        // `refresh_graph_projection` inside the normal `emit_event` /
        // `audit` was the primary cause of the `doc.plan_handoff.claim`
        // RPC timeout on busy vaults.
        // See operations/quality/2026-04-08-rpc-latency-hardening.md.
        self.emit_event_no_refresh(
            actor,
            "doc.plan_handoff_claimed",
            Some(&claimed.doc_id),
            None,
            json!({
                "handoff_id": claimed.handoff_id,
                "doc_id": claimed.doc_id,
                "reason": claimed.reason,
                "claimed_by": claimed.claimed_by,
            }),
            None,
        )?;
        self.audit_no_refresh(
            actor,
            "doc.plan_handoff.claim",
            &json!({ "handoff_id": handoff_id }),
            Some(&claimed.doc_id),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "handoff": claimed }))
    }

    pub fn doc_plan_handoff_complete(
        &self,
        actor: &Actor,
        handoff_id: &str,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let mut handoff = db::get_doc_plan_handoff(&conn, handoff_id)?.ok_or_else(|| {
            BtError::NotFound(format!("doc plan handoff {} not found", handoff_id))
        })?;
        if handoff.status == "completed" {
            return Ok(json!({ "handoff": handoff }));
        }
        if handoff.status == "canceled" {
            return Err(BtError::Validation(
                "canceled doc plan handoffs cannot be completed".to_string(),
            ));
        }
        let now = Utc::now();
        handoff.status = "completed".to_string();
        handoff.completed_at = Some(now);
        handoff.completed_by = Some(actor.actor_id());
        handoff.updated_at = now;
        db::update_doc_plan_handoff(&conn, &handoff)?;
        let completed = db::get_doc_plan_handoff(&conn, handoff_id)?.ok_or_else(|| {
            BtError::NotFound(format!("doc plan handoff {} not found", handoff_id))
        })?;
        // No-refresh: status flip only, no graph topology change.
        self.emit_event_no_refresh(
            actor,
            "doc.plan_handoff_completed",
            Some(&completed.doc_id),
            None,
            json!({
                "handoff_id": completed.handoff_id,
                "doc_id": completed.doc_id,
                "reason": completed.reason,
            }),
            None,
        )?;
        self.audit_no_refresh(
            actor,
            "doc.plan_handoff.complete",
            &json!({ "handoff_id": handoff_id }),
            Some(&completed.doc_id),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "handoff": completed }))
    }

    pub fn doc_plan_handoff_release(
        &self,
        actor: &Actor,
        handoff_id: &str,
        reason: Option<&str>,
        requested_user_updated_at: Option<&str>,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let mut handoff = db::get_doc_plan_handoff(&conn, handoff_id)?.ok_or_else(|| {
            BtError::NotFound(format!("doc plan handoff {} not found", handoff_id))
        })?;
        if handoff.status == "completed" {
            return Err(BtError::Validation(
                "completed doc plan handoffs cannot be released".to_string(),
            ));
        }
        if let Some(reason) = reason.map(str::trim).filter(|value| !value.is_empty()) {
            handoff.reason = reason.to_string();
        }
        if let Some(requested_at) = requested_user_updated_at {
            if let Ok(parsed) = DateTime::parse_from_rfc3339(requested_at) {
                handoff.requested_user_updated_at = parsed.with_timezone(&Utc);
            }
        }
        let now = Utc::now();
        handoff.status = "pending".to_string();
        handoff.claimed_at = None;
        handoff.claimed_by = None;
        handoff.completed_at = None;
        handoff.completed_by = None;
        handoff.updated_at = now;
        db::update_doc_plan_handoff(&conn, &handoff)?;
        let released = db::get_doc_plan_handoff(&conn, handoff_id)?.ok_or_else(|| {
            BtError::NotFound(format!("doc plan handoff {} not found", handoff_id))
        })?;
        // No-refresh: status flip only, no graph topology change.
        self.emit_event_no_refresh(
            actor,
            "doc.plan_handoff_released",
            Some(&released.doc_id),
            None,
            json!({
                "handoff_id": released.handoff_id,
                "doc_id": released.doc_id,
                "reason": released.reason,
                "requested_user_updated_at": released.requested_user_updated_at,
            }),
            None,
        )?;
        self.audit_no_refresh(
            actor,
            "doc.plan_handoff.release",
            &json!({
                "handoff_id": handoff_id,
                "reason": released.reason,
                "requested_user_updated_at": released.requested_user_updated_at,
            }),
            Some(&released.doc_id),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "handoff": released }))
    }

    pub fn doc_delete_agent_content(&self, actor: &Actor, id: &str) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::DeleteAgentContent)?;
        self.doc_update_agent(actor, id, "", "replace", false)
    }

    pub fn doc_delete(&self, actor: &Actor, id: &str) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::DeleteDocument)?;

        let conn = self.open_conn()?;
        let doc = db::get_doc(&conn, id)?
            .ok_or_else(|| BtError::NotFound(format!("doc {} not found", id)))?;
        let root = self.require_vault()?;
        let doc_dir = root.join("topics").join(&doc.topic).join(&doc.slug);
        let topic_dir = root.join("topics").join(&doc.topic);

        let _lock = fs_guard::acquire_doc_lock(&root, id, &actor.actor_id())?;

        crate::notes::store::purge_note(&conn, id)?;
        let deleted = db::delete_doc_row(&conn, id)?;
        if !deleted {
            return Err(BtError::NotFound(format!("doc {} not found", id)));
        }

        if doc_dir.exists() {
            fs::remove_dir_all(&doc_dir)?;
        }
        if topic_dir.exists() && topic_dir.read_dir()?.next().is_none() {
            let _ = fs::remove_dir(&topic_dir);
        }

        let mut warnings = Vec::new();
        if let Err(err) = self.emit_event_no_refresh(
            actor,
            "doc.deleted",
            Some(id),
            None,
            json!({
                "id": id,
                "topic": doc.topic,
                "slug": doc.slug,
                "title": doc.title,
            }),
            None,
        ) {
            warnings.push(format!("event emission failed: {}", err));
        }
        if let Err(err) = self.audit_no_refresh(
            actor,
            "doc.delete",
            &json!({ "id": id }),
            Some(id),
            None,
            "ok",
            json!({
                "topic": doc.topic,
                "slug": doc.slug,
                "title": doc.title,
            }),
        ) {
            warnings.push(format!("audit failed: {}", err));
        }
        if let Err(err) = self.maybe_refresh_graph_projection() {
            warnings.push(format!("graph refresh failed: {}", err));
        }

        Ok(json!({
            "id": id,
            "deleted": true,
            "warnings": warnings,
        }))
    }

    pub fn doc_meta_update(
        &self,
        actor: &Actor,
        id: &str,
        input: &Value,
    ) -> Result<Value, BtError> {
        let mut changed_fields = Vec::new();
        if input.get("tags").is_some() {
            changed_fields.push("tags".to_string());
        }
        if input.get("links_out").is_some() {
            changed_fields.push("links_out".to_string());
        }
        if input.get("status").is_some() {
            changed_fields.push("status".to_string());
        }
        if changed_fields.is_empty() {
            return Err(BtError::Validation(
                "at least one of tags, links_out, or status must be provided".to_string(),
            ));
        }

        self.apply_write(
            actor,
            WriteOperation::UpdateMeta {
                fields: changed_fields.clone(),
            },
        )?;

        let mut meta = self
            .load_meta_by_doc(id)?
            .ok_or_else(|| BtError::NotFound(format!("meta for {} missing", id)))?;

        if let Some(tags) = input.get("tags") {
            meta.tags = parse_string_list(tags, "tags")?;
        }
        if let Some(links_out) = input.get("links_out") {
            meta.links_out = parse_string_list(links_out, "links_out")?;
        }
        if input.get("status").is_some() {
            meta.status = input
                .get("status")
                .and_then(Value::as_str)
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty());
        }
        meta.updated_at = Utc::now();
        self.save_meta(&meta)?;

        self.audit(
            actor,
            "doc.meta.update",
            &json!({
                "id": id,
                "fields": changed_fields,
                "tags": meta.tags,
                "links_out": meta.links_out,
                "status": meta.status,
            }),
            Some(id),
            None,
            "ok",
            json!({}),
        )?;

        Ok(json!({
            "meta": meta,
        }))
    }

    pub fn doc_rename(
        &self,
        actor: &Actor,
        id: &str,
        new_title: Option<&str>,
        new_slug: Option<&str>,
        new_topic: Option<&str>,
    ) -> Result<Value, BtError> {
        let title_only = new_slug.is_none() && new_topic.is_none();
        self.apply_write(actor, WriteOperation::RenameDocument { title_only })?;

        let conn = self.open_conn()?;
        let doc = db::get_doc(&conn, id)?
            .ok_or_else(|| BtError::NotFound(format!("doc {} not found", id)))?;
        let mut meta = self
            .load_meta_by_doc(id)?
            .ok_or_else(|| BtError::NotFound(format!("meta for {} missing", id)))?;

        let root = self.require_vault()?;

        let final_title = new_title.unwrap_or(&doc.title).to_string();
        let final_topic = if let Some(next) = new_topic {
            fs_guard::sanitize_segment(next)?
        } else {
            doc.topic.clone()
        };
        let final_slug = if let Some(next) = new_slug {
            fs_guard::sanitize_segment(next)?
        } else {
            doc.slug.clone()
        };

        if title_only {
            meta.title = final_title.clone();
            meta.updated_at = Utc::now();
            self.save_meta(&meta)?;
            db::update_doc_title(&conn, id, &final_title, meta.updated_at)?;
            self.audit(
                actor,
                "doc.rename",
                &json!({ "id": id, "newTitle": new_title }),
                Some(id),
                None,
                "ok",
                json!({ "title_only": true }),
            )?;
            return Ok(
                json!({ "id": id, "title": final_title, "topic": final_topic, "slug": final_slug }),
            );
        }

        let old_user = fs_guard::safe_join(&root, Path::new(&doc.user_path))?;
        let old_dir = old_user
            .parent()
            .ok_or_else(|| BtError::Io("doc path has no parent".to_string()))?
            .to_path_buf();

        let new_rel_dir = format!("topics/{}/{}", final_topic, final_slug);
        let new_dir = fs_guard::safe_join(&root, Path::new(&new_rel_dir))?;
        if new_dir.exists() {
            return Err(BtError::Conflict(format!("target {} exists", new_rel_dir)));
        }
        let parent = new_dir
            .parent()
            .ok_or_else(|| BtError::Io("new dir has no parent".to_string()))?
            .to_path_buf();
        fs::create_dir_all(parent)?;

        fs::rename(&old_dir, &new_dir)?;

        let final_user_rel = format!("{}/user.md", new_rel_dir);
        let final_agent_rel = format!("{}/agent.md", new_rel_dir);

        meta.title = final_title.clone();
        meta.topic = final_topic.clone();
        meta.updated_at = Utc::now();
        meta.pair.user_path = final_user_rel.clone();
        meta.pair.agent_path = final_agent_rel.clone();
        self.save_meta(&meta)?;

        db::update_doc_identifiers(
            &conn,
            id,
            &final_topic,
            &final_slug,
            &final_title,
            &final_user_rel,
            &final_agent_rel,
            meta.updated_at,
        )?;

        self.audit(
            actor,
            "doc.rename",
            &json!({ "id": id, "newTitle": new_title, "newSlug": new_slug, "newTopic": new_topic }),
            Some(id),
            None,
            "ok",
            json!({ "title_only": false }),
        )?;

        Ok(json!({
            "id": id,
            "title": final_title,
            "topic": final_topic,
            "slug": final_slug,
            "user_path": final_user_rel,
            "agent_path": final_agent_rel,
        }))
    }

    pub fn search_query(
        &self,
        q: &str,
        scope: &str,
        topic: Option<&str>,
        limit: usize,
        knowledge_scope: Option<&str>,
        project_id: Option<&str>,
        include_global: Option<bool>,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let provider = crate::notes::Qwen3EmbeddingProvider::default();
        let filter = KnowledgeScopeFilter::from_parts(knowledge_scope, project_id, include_global);
        let mut query = crate::notes::HybridQuery::new(q, scope);
        query.topic = topic;
        query.limit = limit.saturating_mul(3).max(limit);
        match crate::notes::hybrid_search(&conn, &query, &provider) {
            Ok(rows) if !rows.is_empty() => {
                let mut results = serde_json::to_value(rows)
                    .map_err(|e| BtError::Validation(e.to_string()))?;
                self.filter_search_results_value(&conn, &mut results, &filter, limit)?;
                Ok(json!({
                    "results": results,
                    "retrieval": {
                        "mode": "hybrid",
                        "embedding_model": provider.metadata(),
                        "knowledge_scope": filter.mode,
                        "project_id": filter.project_id,
                        "include_global": filter.include_global,
                    }
                }))
            }
            Ok(_) | Err(_) => {
                let rows = db::search(&conn, q, scope, topic, limit.saturating_mul(3).max(limit))?;
                let mut results = serde_json::to_value(rows)
                    .map_err(|e| BtError::Validation(e.to_string()))?;
                self.filter_search_results_value(&conn, &mut results, &filter, limit)?;
                Ok(json!({
                    "results": results,
                    "retrieval": {
                        "mode": "lexical",
                        "embedding_model": provider.metadata(),
                        "knowledge_scope": filter.mode,
                        "project_id": filter.project_id,
                        "include_global": filter.include_global,
                    }
                }))
            }
        }
    }

    fn filter_search_results_value(
        &self,
        conn: &rusqlite::Connection,
        results: &mut Value,
        filter: &KnowledgeScopeFilter,
        limit: usize,
    ) -> Result<(), BtError> {
        if filter.mode == "all" {
            if let Some(rows) = results.as_array_mut() {
                rows.truncate(limit);
            }
            return Ok(());
        }
        if let Some(rows) = results.as_array_mut() {
            rows.retain(|row| {
                let Some(doc_id) = row.get("doc_id").and_then(Value::as_str) else {
                    return false;
                };
                match db::get_doc(conn, doc_id) {
                    Ok(Some(doc)) => filter.matches_doc(&doc),
                    _ => false,
                }
            });
            rows.truncate(limit);
        }
        Ok(())
    }

    fn reindex_doc_embeddings(
        &self,
        conn: &rusqlite::Connection,
        doc_id: &str,
        user_content: &str,
        agent_content: &str,
    ) -> Result<(), BtError> {
        let provider = crate::notes::Qwen3EmbeddingProvider::default();
        crate::notes::store::reindex_note(conn, doc_id, "user", user_content, &provider)?;
        crate::notes::store::reindex_note(conn, doc_id, "agent", agent_content, &provider)?;
        Ok(())
    }

    //
    // Runs (automation/execution ledger)
    //

    fn ensure_run_artifacts_dir(&self, run_id: &str) -> Result<PathBuf, BtError> {
        let root = self.require_vault()?;
        let dir = fs_guard::safe_join(&root, Path::new(&format!(".bt/artifacts/runs/{}", run_id)))?;
        fs::create_dir_all(&dir)?;
        Ok(dir)
    }

    fn validate_artifact_filename(name: &str) -> Result<&str, BtError> {
        if name.trim().is_empty() {
            return Err(BtError::Validation("filename cannot be empty".to_string()));
        }
        let p = Path::new(name);
        let mut comps = p.components();
        let first = comps.next();
        if first.is_none() || comps.next().is_some() {
            return Err(BtError::Validation(
                "filename must be a single path segment".to_string(),
            ));
        }
        Ok(name)
    }

    fn write_run_artifact_text(
        &self,
        run_id: &str,
        filename: &str,
        content: &str,
    ) -> Result<(String, String), BtError> {
        let root = self.require_vault()?;
        let _dir = self.ensure_run_artifacts_dir(run_id)?;
        let filename = Self::validate_artifact_filename(filename)?;
        let abs = fs_guard::safe_join(
            &root,
            Path::new(&format!(".bt/artifacts/runs/{}/{}", run_id, filename)),
        )?;
        fs_guard::atomic_write(&root, &abs, content)?;
        let rel = abs
            .strip_prefix(&root)
            .map_err(|_| BtError::PathEscape(abs.display().to_string()))?
            .to_string_lossy()
            .replace('\\', "/");
        Ok((rel, Self::sha(content)))
    }

    fn budget_month_key(now: DateTime<Utc>) -> String {
        now.format("%Y-%m").to_string()
    }

    fn enforce_budget_gate(
        &self,
        conn: &rusqlite::Connection,
        company_id: &str,
        agent_id: &str,
    ) -> Result<(), BtError> {
        let agent = db::get_agent(conn, agent_id)?
            .ok_or_else(|| BtError::NotFound(format!("agent {} not found", agent_id)))?;
        if agent.company_id != company_id {
            return Err(BtError::Conflict(format!(
                "agent {} does not belong to company {}",
                agent_id, company_id
            )));
        }

        let now = Utc::now();
        let month_key = Self::budget_month_key(now);
        let usage = db::sum_budget_usage_for_month(conn, company_id, agent_id, &month_key)?;
        let has_override = db::get_active_budget_override(conn, agent_id, now)?.is_some();

        if agent.state == "paused" && !has_override {
            return Err(BtError::Conflict(format!(
                "agent {} is paused (budget cap reached)",
                agent_id
            )));
        }

        if agent.budget_monthly_cap_usd > 0.0
            && usage >= agent.budget_monthly_cap_usd
            && !has_override
        {
            db::set_agent_state(conn, agent_id, "paused", Some(now), now)?;
            return Err(BtError::Conflict(format!(
                "budget cap reached for agent {}: {:.2}/{:.2}",
                agent_id, usage, agent.budget_monthly_cap_usd
            )));
        }
        Ok(())
    }

    fn record_budget_usage(
        &self,
        conn: &rusqlite::Connection,
        company_id: &str,
        agent_id: &str,
        run_id: &str,
        usd_cost: f64,
        source: &str,
    ) -> Result<(), BtError> {
        if usd_cost <= 0.0 {
            return Ok(());
        }
        let now = Utc::now();
        let month_key = Self::budget_month_key(now);
        let usage = BudgetUsageEntry {
            usage_id: format!("busg_{}", Uuid::new_v4().simple()),
            company_id: company_id.to_string(),
            agent_id: agent_id.to_string(),
            run_id: Some(run_id.to_string()),
            month_key: month_key.clone(),
            usd_cost,
            source: source.to_string(),
            created_at: now,
        };
        db::insert_budget_usage(conn, &usage)?;

        let agent = match db::get_agent(conn, agent_id)? {
            Some(agent) => agent,
            None => return Ok(()),
        };
        let total = db::sum_budget_usage_for_month(conn, company_id, agent_id, &month_key)?;
        let has_override = db::get_active_budget_override(conn, agent_id, now)?.is_some();
        if agent.budget_monthly_cap_usd > 0.0
            && total >= agent.budget_monthly_cap_usd
            && !has_override
        {
            db::set_agent_state(conn, agent_id, "paused", Some(now), now)?;
        }
        Ok(())
    }

    pub fn run_create(
        &self,
        actor: &Actor,
        source: &str,
        summary: &str,
        automation_id: Option<&str>,
        occurrence_id: Option<&str>,
        task_id: Option<&str>,
        doc_id: Option<&str>,
        agent_brand: Option<&str>,
        agent_name: Option<&str>,
        agent_session_id: Option<&str>,
        adapter_kind: Option<&str>,
        craftship_session_id: Option<&str>,
        craftship_session_node_id: Option<&str>,
        company_id: Option<&str>,
        agent_id: Option<&str>,
        goal_id: Option<&str>,
        ticket_id: Option<&str>,
        requires_plan: bool,
        task_step_count: Option<i64>,
        openclaw_session_id: Option<&str>,
        openclaw_agent_name: Option<&str>,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::CreateRun)?;
        let conn = self.open_conn()?;

        // If referenced entities exist, validate early for clearer errors.
        if let Some(doc_id) = doc_id {
            let _ = db::get_doc(&conn, doc_id)?
                .ok_or_else(|| BtError::NotFound(format!("doc {} not found", doc_id)))?;
        }

        let resolved_company_id = company_id.unwrap_or(DEFAULT_COMPANY_ID);
        let ticket = if let Some(ticket_id) = ticket_id {
            Some(
                db::get_ticket(&conn, ticket_id)?
                    .ok_or_else(|| BtError::NotFound(format!("ticket {} not found", ticket_id)))?,
            )
        } else {
            None
        };

        let mut plan_required = requires_plan || task_step_count.unwrap_or(0) >= 3;
        if let Some(ticket) = &ticket {
            plan_required |= ticket.plan_required;
        }
        if plan_required {
            let approved = db::latest_approved_plan_for_ticket_or_task(&conn, ticket_id, task_id)?;
            if approved.is_none() {
                return Err(BtError::Conflict(
                    "plan gate blocked execution: approved plan is required before run.create"
                        .to_string(),
                ));
            }
        }

        if let Some(agent_id) = agent_id {
            self.enforce_budget_gate(&conn, resolved_company_id, agent_id)?;
        }

        let canonical_agent_name = agent_name.or(openclaw_agent_name);
        let canonical_session_id = agent_session_id.or(openclaw_session_id);
        let canonical_brand = agent_brand.or_else(|| {
            if openclaw_agent_name.is_some()
                || openclaw_session_id.is_some()
                || source.to_ascii_lowercase().contains("openclaw")
            {
                Some("openclaw")
            } else {
                None
            }
        });
        let canonical_adapter_kind = adapter_kind.or(Some(source));
        let legacy_openclaw_name = if openclaw_agent_name.is_some() {
            openclaw_agent_name
        } else if canonical_brand == Some("openclaw") {
            canonical_agent_name
        } else {
            None
        };
        let legacy_openclaw_session = if openclaw_session_id.is_some() {
            openclaw_session_id
        } else if canonical_brand == Some("openclaw") {
            canonical_session_id
        } else {
            None
        };

        let run_id = format!("run_{}", Uuid::new_v4().simple());
        let run = RunRecord {
            id: run_id.clone(),
            source: source.to_string(),
            status: "queued".to_string(),
            summary: summary.to_string(),
            automation_id: automation_id.map(ToOwned::to_owned),
            occurrence_id: occurrence_id.map(ToOwned::to_owned),
            task_id: task_id.map(ToOwned::to_owned),
            doc_id: doc_id.map(ToOwned::to_owned),
            created_at: Utc::now(),
            started_at: None,
            ended_at: None,
            error_kind: None,
            error_message: None,
            agent_brand: canonical_brand.map(ToOwned::to_owned),
            agent_name: canonical_agent_name.map(ToOwned::to_owned),
            agent_session_id: canonical_session_id.map(ToOwned::to_owned),
            adapter_kind: canonical_adapter_kind.map(ToOwned::to_owned),
            craftship_session_id: craftship_session_id.map(ToOwned::to_owned),
            craftship_session_node_id: craftship_session_node_id.map(ToOwned::to_owned),
            company_id: Some(resolved_company_id.to_string()),
            agent_id: agent_id.map(ToOwned::to_owned),
            goal_id: goal_id.map(ToOwned::to_owned),
            ticket_id: ticket_id.map(ToOwned::to_owned),
            openclaw_session_id: legacy_openclaw_session.map(ToOwned::to_owned),
            openclaw_agent_name: legacy_openclaw_name.map(ToOwned::to_owned),
        };

        db::insert_run(&conn, &run)?;
        let _ = self.ensure_run_artifacts_dir(&run.id)?;

        // No-refresh: the run is persisted in SQLite; the graph projection
        // catches up on the next throttled refresh. This keeps run.create
        // fast on the craftship launch hot path.
        self.audit_no_refresh(
            actor,
            "run.create",
            &json!({
                "id": run.id,
                "source": source,
                "summary": summary,
                "automation_id": automation_id,
                "occurrence_id": occurrence_id,
                "task_id": task_id,
                "doc_id": doc_id,
                "agent_brand": canonical_brand,
                "agent_name": canonical_agent_name,
                "agent_session_id": canonical_session_id,
                "adapter_kind": canonical_adapter_kind,
                "craftship_session_id": craftship_session_id,
                "craftship_session_node_id": craftship_session_node_id,
                "company_id": resolved_company_id,
                "agent_id": agent_id,
                "goal_id": goal_id,
                "ticket_id": ticket_id,
                "requires_plan": plan_required,
            }),
            doc_id,
            Some(&run.id),
            "ok",
            json!({ "run_id": run.id }),
        )?;

        Ok(json!({ "run": run }))
    }

    pub fn run_update_status(
        &self,
        actor: &Actor,
        run_id: &str,
        status: &str,
        error_kind: Option<&str>,
        error_message: Option<&str>,
        run_cost_usd: Option<f64>,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::UpdateRun)?;
        let conn = self.open_conn()?;
        let existing = db::get_run(&conn, run_id)?
            .ok_or_else(|| BtError::NotFound(format!("run {} not found", run_id)))?;

        let now = Utc::now();
        let started_at = if status == "running" && existing.started_at.is_none() {
            Some(now)
        } else {
            None
        };
        let ended_at = if matches!(status, "succeeded" | "failed" | "canceled" | "aborted") {
            Some(now)
        } else {
            None
        };

        if status == "succeeded" {
            let gated_plan = db::latest_approved_plan_for_ticket_or_task(
                &conn,
                existing.ticket_id.as_deref(),
                existing.task_id.as_deref(),
            )?;
            if gated_plan.is_some() {
                let artifacts = db::list_run_artifacts(&conn, run_id)?;
                if artifacts.is_empty() {
                    return Err(BtError::Conflict(
                        "evidence-before-done blocked completion: attach at least one run artifact"
                            .to_string(),
                    ));
                }
            }
        }

        db::update_run_status(
            &conn,
            run_id,
            status,
            started_at,
            ended_at,
            error_kind,
            error_message,
        )?;
        let run = db::get_run(&conn, run_id)?
            .ok_or_else(|| BtError::NotFound(format!("run {} not found", run_id)))?;

        if let (Some(cost), Some(agent_id), Some(company_id)) = (
            run_cost_usd,
            run.agent_id.as_deref(),
            run.company_id.as_deref(),
        ) {
            self.record_budget_usage(
                &conn,
                company_id,
                agent_id,
                &run.id,
                cost,
                "run_update_status",
            )?;
        }

        self.audit(
            actor,
            "run.update_status",
            &json!({
                "run_id": run_id,
                "status": status,
                "error_kind": error_kind,
                "error_message": error_message,
                "run_cost_usd": run_cost_usd
            }),
            run.doc_id.as_deref(),
            Some(run_id),
            "ok",
            json!({}),
        )?;

        Ok(json!({ "run": run }))
    }

    pub fn run_attach_artifact(
        &self,
        actor: &Actor,
        run_id: &str,
        kind: &str,
        filename: Option<&str>,
        content: Option<Value>,
        content_inline: Option<&str>,
        meta: Option<Value>,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::AttachRunArtifact)?;
        let conn = self.open_conn()?;
        let run = db::get_run(&conn, run_id)?
            .ok_or_else(|| BtError::NotFound(format!("run {} not found", run_id)))?;

        // Normalize content sources.
        let normalized_text: Option<String> = if let Some(v) = content {
            if v.is_string() {
                v.as_str().map(|s| s.to_string())
            } else {
                serde_json::to_string_pretty(&v).ok()
            }
        } else {
            content_inline.map(|s| s.to_string())
        };

        let text = normalized_text.ok_or_else(|| {
            BtError::Validation(
                "either content (json) or content_inline (string) is required".to_string(),
            )
        })?;

        // Default to file-backed artifacts when filename is provided OR content is large.
        let force_file = filename.is_some() || text.len() > 8 * 1024;
        let (path, content_inline, sha256) = if force_file {
            let fname = filename.unwrap_or("artifact.txt");
            let (rel, digest) = self.write_run_artifact_text(run_id, fname, &text)?;
            (Some(rel), None, Some(digest))
        } else {
            (None, Some(text.clone()), Some(Self::sha(&text)))
        };

        let artifact = RunArtifact {
            id: format!("art_{}", Uuid::new_v4().simple()),
            run_id: run_id.to_string(),
            kind: kind.to_string(),
            path,
            content_inline,
            sha256,
            meta_json: meta,
            created_at: Utc::now(),
        };
        db::insert_run_artifact(&conn, &artifact)?;

        self.audit(
            actor,
            "run.attach_artifact",
            &json!({ "run_id": run_id, "kind": kind, "filename": filename }),
            run.doc_id.as_deref(),
            Some(run_id),
            "ok",
            json!({ "artifact_id": artifact.id }),
        )?;

        Ok(json!({ "artifact": artifact }))
    }

    pub fn run_get(&self, run_id: &str, include_artifacts: bool) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let run = db::get_run(&conn, run_id)?
            .ok_or_else(|| BtError::NotFound(format!("run {} not found", run_id)))?;
        if include_artifacts {
            let artifacts = db::list_run_artifacts(&conn, run_id)?;
            Ok(json!({ "run": run, "artifacts": artifacts }))
        } else {
            Ok(json!({ "run": run }))
        }
    }

    pub fn run_list(&self, status: Option<&str>, limit: usize) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let runs = db::list_runs(&conn, status, limit)?;
        Ok(json!({ "runs": runs }))
    }

    fn require_operator_actor(&self, actor: &Actor, action: &str) -> Result<(), BtError> {
        if matches!(actor, Actor::Agent { .. }) {
            return Err(BtError::Forbidden(format!(
                "ERR_AGENT_FORBIDDEN_OPERATOR_SURFACE: {}",
                action
            )));
        }
        Ok(())
    }

    fn emit_event(
        &self,
        actor: &Actor,
        event_type: &str,
        doc_id: Option<&str>,
        run_id: Option<&str>,
        payload: Value,
        dedupe_key: Option<&str>,
    ) -> Result<i64, BtError> {
        let event_id =
            self.emit_event_no_refresh(actor, event_type, doc_id, run_id, payload, dedupe_key)?;
        // Use the throttled variant — same fix class as audit(). The
        // unconditional `refresh_graph_projection` was the remaining
        // latent quadratic on the write hot path: every `emit_event`
        // call rebuilt the entire graph projection (all graph-relevant
        // tables, up to 10 k rows each). On a vault with history, two
        // calls per RPC (emit_event + audit) doubled the cost, and
        // `doc.plan_handoff.claim` was timing out before the craftship
        // even got a chance to launch. Read-path callers that need a
        // fresh projection call the unconditional variant directly.
        self.maybe_refresh_graph_projection()?;
        Ok(event_id)
    }

    /// Insert a durable event without triggering a graph projection
    /// rebuild. Use this on write-hot-path handlers whose mutations do
    /// not alter the graph structure (e.g. handoff status flips). The
    /// graph will catch up on the next throttled refresh or on-demand
    /// read via `load_graph_records` self-heal.
    fn emit_event_no_refresh(
        &self,
        actor: &Actor,
        event_type: &str,
        doc_id: Option<&str>,
        run_id: Option<&str>,
        payload: Value,
        dedupe_key: Option<&str>,
    ) -> Result<i64, BtError> {
        let conn = self.open_conn()?;
        db::insert_event(
            &conn,
            event_type,
            actor.actor_type(),
            &actor.actor_id(),
            doc_id,
            run_id,
            &payload,
            dedupe_key,
        )
    }

    fn load_token_by_id(&self, token_id: &str) -> Result<Option<TokenRecord>, BtError> {
        let root = self.require_vault()?;
        let cfg = config::load_config(&root)?;
        Ok(cfg
            .tokens
            .into_iter()
            .find(|token| token.token_id == token_id && !token.revoked))
    }

    fn resolve_team_actor_node(
        &self,
        conn: &rusqlite::Connection,
        actor: &Actor,
        craftship_session_id: &str,
    ) -> Result<Option<CraftshipSessionNode>, BtError> {
        match actor {
            Actor::Agent { token_id } => {
                db::get_craftship_session_node_by_agent_token(conn, craftship_session_id, token_id)
            }
            _ => Ok(None),
        }
    }

    fn require_team_actor_node(
        &self,
        conn: &rusqlite::Connection,
        actor: &Actor,
        craftship_session_id: &str,
    ) -> Result<CraftshipSessionNode, BtError> {
        self.resolve_team_actor_node(conn, actor, craftship_session_id)?
            .ok_or_else(|| {
                BtError::Forbidden(format!(
                    "actor {} is not bound to craftship session {}",
                    actor.actor_id(),
                    craftship_session_id
                ))
            })
    }

    fn require_team_lead_or_operator(
        &self,
        conn: &rusqlite::Connection,
        actor: &Actor,
        craftship_session_id: &str,
        action: &str,
    ) -> Result<Option<CraftshipSessionNode>, BtError> {
        if !matches!(actor, Actor::Agent { .. }) {
            return Ok(None);
        }
        let node = self.require_team_actor_node(conn, actor, craftship_session_id)?;
        if node.parent_session_node_id.is_some() {
            return Err(BtError::Forbidden(format!(
                "lead authority required for {}",
                action
            )));
        }
        Ok(Some(node))
    }

    fn require_session_node_belongs_to_session(
        conn: &rusqlite::Connection,
        craftship_session_id: &str,
        session_node_id: &str,
    ) -> Result<CraftshipSessionNode, BtError> {
        let node = db::get_craftship_session_node(conn, session_node_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship session node {} not found",
                session_node_id
            ))
        })?;
        if node.craftship_session_id != craftship_session_id {
            return Err(BtError::Validation(format!(
                "craftship session node {} does not belong to session {}",
                session_node_id, craftship_session_id
            )));
        }
        Ok(node)
    }

    fn validate_team_work_item_status(status: &str) -> Result<String, BtError> {
        let normalized = status.trim().to_lowercase();
        if matches!(
            normalized.as_str(),
            "proposed"
                | "ready"
                | "assigned"
                | "claimed"
                | "in_progress"
                | "blocked"
                | "completed"
                | "canceled"
        ) {
            Ok(normalized)
        } else {
            Err(BtError::Validation(format!(
                "invalid craftship team work item status {}",
                status
            )))
        }
    }

    fn team_work_item_is_closed(status: &str) -> bool {
        matches!(
            status.trim().to_lowercase().as_str(),
            "completed" | "canceled"
        )
    }

    fn craftship_sync_work_item_id(
        craftship_session_id: &str,
        source_task_id: &str,
        template_node_id: &str,
        title: &str,
    ) -> String {
        let digest = Self::sha(&format!(
            "{}|{}|{}|{}",
            craftship_session_id,
            source_task_id,
            template_node_id,
            normalize_task_title(title)
        ));
        format!("cswi_sync_{}", &digest[..24])
    }

    fn validate_team_message_receipt_state(state: &str) -> Result<String, BtError> {
        let normalized = state.trim().to_lowercase();
        if matches!(
            normalized.as_str(),
            TEAM_RECEIPT_PENDING | TEAM_RECEIPT_DELIVERED | TEAM_RECEIPT_ACKNOWLEDGED
        ) {
            Ok(normalized)
        } else {
            Err(BtError::Validation(format!(
                "invalid craftship team message receipt state {}",
                state
            )))
        }
    }

    fn validate_node_presence(value: &str) -> Result<String, BtError> {
        let normalized = value.trim().to_lowercase();
        if matches!(
            normalized.as_str(),
            "offline" | "online" | "active" | "idle" | "busy"
        ) {
            Ok(normalized)
        } else {
            Err(BtError::Validation(format!(
                "invalid craftship node presence {}",
                value
            )))
        }
    }

    fn build_team_state_payload(
        &self,
        conn: &rusqlite::Connection,
        session: &CraftshipSession,
        nodes: &[CraftshipSessionNode],
    ) -> Result<Value, BtError> {
        let work_items = db::list_craftship_team_work_items(
            conn,
            &session.craftship_session_id,
            None,
            None,
            false,
            200,
        )?;
        let pending_message_counts =
            db::count_pending_craftship_team_message_receipts(conn, &session.craftship_session_id)?
                .into_iter()
                .map(|(session_node_id, count)| {
                    json!({
                        "session_node_id": session_node_id,
                        "count": count,
                    })
                })
                .collect::<Vec<_>>();

        Ok(json!({
            "node_runtime": nodes,
            "work_items": work_items,
            "pending_message_counts": pending_message_counts,
        }))
    }

    fn build_team_inbox_payload(entries: &[CraftshipTeamInboxEntry]) -> Value {
        json!({
            "entries": entries.iter().map(|entry| json!({
                "message": entry.message,
                "receipt": entry.receipt,
                "sender_label": entry.sender_label,
            })).collect::<Vec<_>>()
        })
    }

    pub fn crafting_framework_list(&self, include_archived: bool) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let frameworks = db::list_crafting_frameworks(&conn, include_archived)?;
        Ok(json!({ "frameworks": frameworks }))
    }

    pub fn crafting_framework_get(&self, framework_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let framework = db::get_crafting_framework(&conn, framework_id)?
            .ok_or_else(|| BtError::NotFound(format!("framework {} not found", framework_id)))?;
        Ok(json!({ "framework": framework }))
    }

    pub fn crafting_framework_create(&self, actor: &Actor, input: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.framework.create")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let name = required_str(&input, "name")?.trim().to_string();
        if name.is_empty() {
            return Err(BtError::Validation("name cannot be empty".to_string()));
        }
        let custom_instruction = required_str(&input, "custom_instruction")?
            .trim()
            .to_string();
        if custom_instruction.is_empty() {
            return Err(BtError::Validation(
                "custom_instruction cannot be empty".to_string(),
            ));
        }

        let chain_of_thought = Self::parse_chain_of_thought_config(input.get("chain_of_thought"));
        let chain_of_knowledge =
            Self::parse_chain_of_knowledge_config(input.get("chain_of_knowledge"));
        let enhanced_instruction = Self::enhance_framework_instruction(
            &name,
            &custom_instruction,
            &chain_of_thought,
            &chain_of_knowledge,
        );
        let now = Utc::now();
        let framework = CraftingFramework {
            framework_id: format!("fw_{}", Uuid::new_v4().simple()),
            name,
            custom_instruction,
            enhanced_instruction,
            chain_of_thought,
            chain_of_knowledge,
            archived: false,
            created_at: now,
            updated_at: now,
            enhancement_version: CRAFTING_ENHANCER_VERSION.to_string(),
        };

        let conn = self.open_conn()?;
        db::insert_crafting_framework(&conn, &framework)?;

        self.audit(
            actor,
            "crafting.framework.create",
            &input,
            None,
            None,
            "ok",
            json!({ "framework_id": framework.framework_id }),
        )?;

        Ok(json!({ "framework": framework }))
    }

    pub fn crafting_framework_update(&self, actor: &Actor, input: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.framework.update")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let framework_id = required_str(&input, "framework_id")?;

        let conn = self.open_conn()?;
        let existing = db::get_crafting_framework(&conn, framework_id)?
            .ok_or_else(|| BtError::NotFound(format!("framework {} not found", framework_id)))?;
        let name = optional_str(&input, "name")
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| existing.name.clone());
        let custom_instruction = optional_str(&input, "custom_instruction")
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| existing.custom_instruction.clone());
        let chain_of_thought = input
            .get("chain_of_thought")
            .map(|value| Self::parse_chain_of_thought_config(Some(value)))
            .unwrap_or_else(|| existing.chain_of_thought.clone());
        let chain_of_knowledge = input
            .get("chain_of_knowledge")
            .map(|value| Self::parse_chain_of_knowledge_config(Some(value)))
            .unwrap_or_else(|| existing.chain_of_knowledge.clone());
        let enhanced_instruction = Self::enhance_framework_instruction(
            &name,
            &custom_instruction,
            &chain_of_thought,
            &chain_of_knowledge,
        );

        let framework = CraftingFramework {
            framework_id: existing.framework_id.clone(),
            name,
            custom_instruction,
            enhanced_instruction,
            chain_of_thought,
            chain_of_knowledge,
            archived: existing.archived,
            created_at: existing.created_at,
            updated_at: Utc::now(),
            enhancement_version: CRAFTING_ENHANCER_VERSION.to_string(),
        };
        db::update_crafting_framework(&conn, &framework)?;

        self.audit(
            actor,
            "crafting.framework.update",
            &input,
            None,
            None,
            "ok",
            json!({ "framework_id": framework.framework_id }),
        )?;

        Ok(json!({ "framework": framework }))
    }

    pub fn crafting_framework_archive(
        &self,
        actor: &Actor,
        framework_id: &str,
        archived: bool,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.framework.archive")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let conn = self.open_conn()?;
        db::archive_crafting_framework(&conn, framework_id, archived, Utc::now())?;
        let framework = db::get_crafting_framework(&conn, framework_id)?
            .ok_or_else(|| BtError::NotFound(format!("framework {} not found", framework_id)))?;
        self.audit(
            actor,
            "crafting.framework.archive",
            &json!({ "framework_id": framework_id, "archived": archived }),
            None,
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "framework": framework }))
    }

    pub fn crafting_framework_render_payload(&self, framework_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let framework = db::get_crafting_framework(&conn, framework_id)?
            .ok_or_else(|| BtError::NotFound(format!("framework {} not found", framework_id)))?;
        Ok(json!({
            "framework": framework,
            "payload": framework.enhanced_instruction,
            "enhancement_version": framework.enhancement_version,
        }))
    }

    pub fn craftship_list(&self, include_archived: bool) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let craftships = db::list_craftships(&conn, include_archived)?;
        Ok(json!({ "craftships": craftships }))
    }

    pub fn craftship_get(&self, craftship_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let craftship = db::get_craftship(&conn, craftship_id)?
            .ok_or_else(|| BtError::NotFound(format!("craftship {} not found", craftship_id)))?;
        let nodes = db::list_craftship_nodes(&conn, craftship_id)?;
        Ok(json!({
            "craftship": craftship,
            "nodes": nodes,
        }))
    }

    pub fn craftship_default_get(&self) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let cfg = config::load_config(&root)?;
        let default_craftship_id = cfg.crafting.default_craftship_id.clone();
        let craftship = if let Some(craftship_id) = default_craftship_id.as_deref() {
            let conn = self.open_conn()?;
            db::get_craftship(&conn, craftship_id)?.filter(|row| !row.archived)
        } else {
            None
        };
        Ok(json!({
            "default_craftship_id": default_craftship_id,
            "craftship": craftship,
        }))
    }

    pub fn craftship_default_set(
        &self,
        actor: &Actor,
        craftship_id: Option<&str>,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.craftship.default.set")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let root = self.require_vault()?;
        let mut cfg = config::load_config(&root)?;

        let normalized = craftship_id
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned);
        let craftship = if let Some(craftship_id) = normalized.as_deref() {
            let conn = self.open_conn()?;
            let craftship = db::get_craftship(&conn, craftship_id)?.ok_or_else(|| {
                BtError::NotFound(format!("craftship {} not found", craftship_id))
            })?;
            if craftship.archived {
                return Err(BtError::Validation(
                    "archived craftships cannot be set as default".to_string(),
                ));
            }
            Some(craftship)
        } else {
            None
        };

        cfg.crafting.default_craftship_id = normalized.clone();
        config::save_config(&root, &cfg)?;
        self.audit(
            actor,
            "crafting.craftship.default.set",
            &json!({ "craftship_id": normalized }),
            None,
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({
            "default_craftship_id": cfg.crafting.default_craftship_id,
            "craftship": craftship,
        }))
    }

    pub fn craftship_create(&self, actor: &Actor, input: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.craftship.create")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let conn = self.open_conn()?;
        let now = Utc::now();
        let name = required_str(&input, "name")?.trim().to_string();
        if name.is_empty() {
            return Err(BtError::Validation("name cannot be empty".to_string()));
        }
        let necessity = optional_str(&input, "necessity")
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| name.clone());
        let mode =
            Self::validate_craftship_mode(optional_str(&input, "mode").unwrap_or("template"))?;
        // Required-steps agent fields. Default ON with brand=codex so every
        // new craftship gets the feature out of the box. The validator runs
        // *before* the insert so a bad value errors cleanly.
        let required_agent_enabled = input
            .get("required_agent_enabled")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let required_agent_brand = Self::validate_required_agent_brand(
            optional_str(&input, "required_agent_brand").unwrap_or("codex"),
        )?;
        let craftship = Craftship {
            craftship_id: format!("craftship_{}", Uuid::new_v4().simple()),
            name,
            necessity,
            mode,
            archived: false,
            required_agent_enabled,
            required_agent_brand,
            created_at: now,
            updated_at: now,
        };
        let nodes = if let Some(raw_nodes) = input.get("nodes") {
            self.parse_craftship_nodes_input(&conn, &craftship.craftship_id, raw_nodes, None)?
        } else {
            Self::default_craftship_nodes(&craftship.craftship_id, now)
        };
        db::insert_craftship(&conn, &craftship)?;
        db::replace_craftship_nodes(&conn, &craftship.craftship_id, &nodes)?;

        self.audit(
            actor,
            "crafting.craftship.create",
            &input,
            None,
            None,
            "ok",
            json!({ "craftship_id": craftship.craftship_id }),
        )?;

        self.craftship_get(&craftship.craftship_id)
    }

    pub fn craftship_update(&self, actor: &Actor, input: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.craftship.update")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let conn = self.open_conn()?;
        let craftship_id = required_str(&input, "craftship_id")?;
        let existing = db::get_craftship(&conn, craftship_id)?
            .ok_or_else(|| BtError::NotFound(format!("craftship {} not found", craftship_id)))?;
        // Required-steps agent fields: preserve existing values when the
        // caller does not explicitly supply them. The brand validator runs
        // only when a value is actually provided so "update without
        // touching the brand" never trips on an older (legal-at-write-time)
        // value.
        let required_agent_enabled = input
            .get("required_agent_enabled")
            .and_then(Value::as_bool)
            .unwrap_or(existing.required_agent_enabled);
        let required_agent_brand = match optional_str(&input, "required_agent_brand") {
            Some(value) => Self::validate_required_agent_brand(value)?,
            None => existing.required_agent_brand.clone(),
        };
        let updated = Craftship {
            craftship_id: existing.craftship_id.clone(),
            name: optional_str(&input, "name")
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| existing.name.clone()),
            necessity: optional_str(&input, "necessity")
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| existing.necessity.clone()),
            mode: input
                .get("mode")
                .and_then(Value::as_str)
                .map(Self::validate_craftship_mode)
                .transpose()?
                .unwrap_or_else(|| existing.mode.clone()),
            archived: input
                .get("archived")
                .and_then(Value::as_bool)
                .unwrap_or(existing.archived),
            required_agent_enabled,
            required_agent_brand,
            created_at: existing.created_at,
            updated_at: Utc::now(),
        };
        if updated.name.trim().is_empty() {
            return Err(BtError::Validation("name cannot be empty".to_string()));
        }
        db::update_craftship(&conn, &updated)?;
        if let Some(raw_nodes) = input.get("nodes") {
            let existing_nodes = db::list_craftship_nodes(&conn, craftship_id)?;
            let nodes = self.parse_craftship_nodes_input(
                &conn,
                craftship_id,
                raw_nodes,
                Some(existing_nodes.as_slice()),
            )?;
            db::replace_craftship_nodes(&conn, craftship_id, &nodes)?;
        }

        self.audit(
            actor,
            "crafting.craftship.update",
            &input,
            None,
            None,
            "ok",
            json!({ "craftship_id": craftship_id }),
        )?;

        self.craftship_get(craftship_id)
    }

    pub fn craftship_duplicate(
        &self,
        actor: &Actor,
        craftship_id: &str,
        name: Option<&str>,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.craftship.duplicate")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let conn = self.open_conn()?;
        let source = db::get_craftship(&conn, craftship_id)?
            .ok_or_else(|| BtError::NotFound(format!("craftship {} not found", craftship_id)))?;
        let source_nodes = db::list_craftship_nodes(&conn, craftship_id)?;
        let now = Utc::now();
        // Defensive validation when duplicating: if a prior write left the
        // source with a brand outside the allowed set (shouldn't happen, but
        // better to catch it here than propagate), surface the error before
        // the duplicate row lands in the DB.
        let duplicate_brand = Self::validate_required_agent_brand(&source.required_agent_brand)?;
        let duplicate = Craftship {
            craftship_id: format!("craftship_{}", Uuid::new_v4().simple()),
            name: name
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| format!("{} Copy", source.name)),
            necessity: source.necessity.clone(),
            mode: source.mode.clone(),
            archived: false,
            required_agent_enabled: source.required_agent_enabled,
            required_agent_brand: duplicate_brand,
            created_at: now,
            updated_at: now,
        };
        let mut node_id_map = HashMap::new();
        for node in &source_nodes {
            node_id_map.insert(
                node.node_id.clone(),
                format!("csn_{}", Uuid::new_v4().simple()),
            );
        }
        let nodes = source_nodes
            .iter()
            .map(|node| CraftshipNode {
                node_id: node_id_map
                    .get(&node.node_id)
                    .cloned()
                    .unwrap_or_else(|| format!("csn_{}", Uuid::new_v4().simple())),
                craftship_id: duplicate.craftship_id.clone(),
                parent_node_id: node
                    .parent_node_id
                    .as_ref()
                    .and_then(|parent_id| node_id_map.get(parent_id).cloned()),
                label: node.label.clone(),
                node_kind: node.node_kind.clone(),
                framework_id: node.framework_id.clone(),
                brand_id: node.brand_id.clone(),
                sort_order: node.sort_order,
                created_at: now,
                updated_at: now,
            })
            .collect::<Vec<_>>();
        db::insert_craftship(&conn, &duplicate)?;
        db::replace_craftship_nodes(&conn, &duplicate.craftship_id, &nodes)?;

        self.audit(
            actor,
            "crafting.craftship.duplicate",
            &json!({ "craftship_id": craftship_id, "name": name }),
            None,
            None,
            "ok",
            json!({ "craftship_id": duplicate.craftship_id }),
        )?;

        self.craftship_get(&duplicate.craftship_id)
    }

    pub fn craftship_archive(
        &self,
        actor: &Actor,
        craftship_id: &str,
        archived: bool,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.craftship.archive")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        db::archive_craftship(&conn, craftship_id, archived, Utc::now())?;
        if archived {
            let mut cfg = config::load_config(&root)?;
            if cfg.crafting.default_craftship_id.as_deref() == Some(craftship_id) {
                cfg.crafting.default_craftship_id = None;
                config::save_config(&root, &cfg)?;
            }
        }
        self.audit(
            actor,
            "crafting.craftship.archive",
            &json!({ "craftship_id": craftship_id, "archived": archived }),
            None,
            None,
            "ok",
            json!({}),
        )?;
        self.craftship_get(craftship_id)
    }

    pub fn craftship_session_list(
        &self,
        craftship_id: Option<&str>,
        status: Option<&str>,
        include_archived: bool,
        limit: usize,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let sessions =
            db::list_craftship_sessions(&conn, craftship_id, status, include_archived, limit)?;
        Ok(json!({ "sessions": sessions }))
    }

    pub fn craftship_session_get(&self, craftship_session_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let session = db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship session {} not found",
                craftship_session_id
            ))
        })?;
        self.build_craftship_session_payload(&conn, session)
    }

    /// Build the canonical agent system prompt for a craftship session. The
    /// prompt explicitly lists the pre-work phase ledger, the ordered node
    /// map, the tools catalog, and every tool doc the vault ships — so the
    /// agent receives its entire required-steps spec in one message.
    ///
    /// `role` selects which variant to produce:
    /// - `PromptRole::LeadAgent { analyze_first_path }` — the classic
    ///   Lead-agent prompt, optionally with a "First analyze `<path>`"
    ///   preamble when the required-steps agent is disabled.
    /// - `PromptRole::RequiredAgent { .. }` — the Required-Steps agent's
    ///   prompt, which instructs it to read the source doc and then
    ///   dispatch a synthesized plan to the Lead agent via `acpx`.

    pub fn craftship_session_rename(
        &self,
        actor: &Actor,
        craftship_session_id: &str,
        name: &str,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.craftship.session.rename")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return Err(BtError::Validation("name cannot be empty".to_string()));
        }
        let conn = self.open_conn()?;
        let mut session =
            db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    craftship_session_id
                ))
            })?;
        session.name = trimmed.to_string();
        session.updated_at = Utc::now();
        db::update_craftship_session(&conn, &session)?;
        self.audit(
            actor,
            "crafting.craftship.session.rename",
            &json!({ "craftship_session_id": craftship_session_id, "name": trimmed }),
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        self.craftship_session_get(craftship_session_id)
    }

    pub fn craftship_session_delete(
        &self,
        actor: &Actor,
        craftship_session_id: &str,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.craftship.session.delete")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let conn = self.open_conn()?;
        let session = db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship session {} not found",
                craftship_session_id
            ))
        })?;
        db::delete_craftship_session(&conn, craftship_session_id)?;

        // Clean up the linked session doc so it cannot orphan the
        // `docs(topic, slug)` UNIQUE index for the next launch with the
        // same session name. We delete both the docs row and (best
        // effort) the on-disk directory. Failures here are intentionally
        // non-fatal: the session row is already gone and a stale doc
        // row only causes a slug collision later, which `unique_slug`
        // now also defends against.
        if let Some(session_doc_id) = session.doc_id.as_deref() {
            if let Ok(Some(doc)) = db::get_doc(&conn, session_doc_id) {
                let _ = db::delete_doc_row(&conn, session_doc_id);
                if let Ok(root) = self.require_vault() {
                    let dir_rel = format!("topics/{}/{}", doc.topic, doc.slug);
                    if let Ok(dir_path) = fs_guard::safe_join(&root, Path::new(&dir_rel)) {
                        if dir_path.exists() {
                            let _ = fs::remove_dir_all(&dir_path);
                        }
                    }
                }
            }
        }

        self.audit(
            actor,
            "crafting.craftship.session.delete",
            &json!({ "craftship_session_id": craftship_session_id }),
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "deleted": true, "craftship_session_id": craftship_session_id }))
    }

    pub fn craftship_session_set_status(
        &self,
        actor: &Actor,
        craftship_session_id: &str,
        status: &str,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.craftship.session.set_status")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let normalized_status = Self::validate_craftship_session_status(status)?;
        let conn = self.open_conn()?;
        let mut session =
            db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    craftship_session_id
                ))
            })?;
        session.status = normalized_status.clone();
        session.updated_at = Utc::now();

        let mut context_pack = Value::Null;
        let mut context_error = Value::Null;
        if normalized_status == "completed" {
            if let Some(doc_id) =
                Self::craftship_session_context_doc_id(&session).map(str::to_string)
            {
                match self.context_compact(
                    actor,
                    &session.runtime_brand,
                    Some(&session.craftship_session_id),
                    Some(&doc_id),
                    false,
                ) {
                    Ok(compacted) => {
                        if let Some(context_id) = compacted
                            .get("context_pack")
                            .and_then(|row| row.get("context_id"))
                            .and_then(Value::as_str)
                        {
                            session.last_context_pack_id = Some(context_id.to_string());
                        }
                        context_pack = compacted
                            .get("context_pack")
                            .cloned()
                            .unwrap_or(Value::Null);
                    }
                    Err(error) => {
                        context_error = Value::String(error.to_string());
                    }
                }
            }
        }

        db::update_craftship_session(&conn, &session)?;
        self.audit(
            actor,
            "crafting.craftship.session.set_status",
            &json!({ "craftship_session_id": craftship_session_id, "status": normalized_status }),
            Self::craftship_session_context_doc_id(&session),
            None,
            "ok",
            json!({
                "last_context_pack_id": session.last_context_pack_id,
                "context_error": context_error,
            }),
        )?;
        let mut payload = self.craftship_session_get(craftship_session_id)?;
        if let Some(object) = payload.as_object_mut() {
            object.insert("context_pack".to_string(), context_pack);
            object.insert("context_error".to_string(), context_error);
        }
        Ok(payload)
    }

    pub fn craftship_session_digest(
        &self,
        actor: &Actor,
        craftship_session_id: &str,
        force: bool,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.craftship.session.digest")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let conn = self.open_conn()?;
        let mut session =
            db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    craftship_session_id
                ))
            })?;
        let doc_id = Self::craftship_session_context_doc_id(&session)
            .map(str::to_string)
            .ok_or_else(|| {
                BtError::Validation("craftship session has no source or dossier doc".to_string())
            })?;
        let compacted = self.context_compact(
            actor,
            &session.runtime_brand,
            Some(&session.craftship_session_id),
            Some(&doc_id),
            force,
        )?;
        if let Some(context_id) = compacted
            .get("context_pack")
            .and_then(|row| row.get("context_id"))
            .and_then(Value::as_str)
        {
            session.last_context_pack_id = Some(context_id.to_string());
        }
        session.updated_at = Utc::now();
        db::update_craftship_session(&conn, &session)?;
        self.audit(
            actor,
            "crafting.craftship.session.digest",
            &json!({
                "craftship_session_id": craftship_session_id,
                "force": force,
            }),
            Some(&doc_id),
            None,
            "ok",
            json!({
                "last_context_pack_id": session.last_context_pack_id,
            }),
        )?;
        let mut payload = self.craftship_session_get(craftship_session_id)?;
        if let Some(object) = payload.as_object_mut() {
            object.insert(
                "context_pack".to_string(),
                compacted
                    .get("context_pack")
                    .cloned()
                    .unwrap_or(Value::Null),
            );
        }
        Ok(payload)
    }

    pub fn craftship_session_bind_node_runtime(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "crafting.craftship.session.bind_node_runtime")?;
        self.apply_write(actor, WriteOperation::ManageCrafting)?;
        let conn = self.open_conn()?;
        let session_node_id = required_str(&input, "session_node_id")?;
        let mut node =
            db::get_craftship_session_node(&conn, session_node_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session node {} not found",
                    session_node_id
                ))
            })?;

        if input.get("terminal_ref").is_some() {
            node.terminal_ref = input
                .get("terminal_ref")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned);
        }
        if input.get("run_id").is_some() {
            node.run_id = input
                .get("run_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned);
            if let Some(run_id) = node.run_id.as_deref() {
                let _ = db::get_run(&conn, run_id)?
                    .ok_or_else(|| BtError::NotFound(format!("run {} not found", run_id)))?;
            }
        }
        if input.get("worktree_path").is_some() {
            node.worktree_path = input
                .get("worktree_path")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned);
        }
        if input.get("branch_name").is_some() {
            node.branch_name = input
                .get("branch_name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned);
        }
        if input.get("event_cursor").is_some() {
            node.event_cursor = input.get("event_cursor").and_then(Value::as_i64);
        }
        if input.get("presence").is_some() {
            node.presence = input
                .get("presence")
                .and_then(Value::as_str)
                .map(Self::validate_node_presence)
                .transpose()?;
        }
        if input.get("agent_name").is_some() {
            node.agent_name = input
                .get("agent_name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned);
        }
        if input.get("agent_token_id").is_some() {
            node.agent_token_id = input
                .get("agent_token_id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned);
            if let Some(token_id) = node.agent_token_id.as_deref() {
                let _ = self
                    .load_token_by_id(token_id)?
                    .ok_or_else(|| BtError::NotFound(format!("token {} not found", token_id)))?;
            }
        }
        if let Some(status) = input.get("status").and_then(Value::as_str) {
            node.status = status.trim().to_string();
        }
        node.updated_at = Utc::now();
        db::update_craftship_session_node(&conn, &node)?;

        let session =
            db::get_craftship_session(&conn, &node.craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    node.craftship_session_id
                ))
            })?;
        self.audit(
            actor,
            "crafting.craftship.session.bind_node_runtime",
            &input,
            session.doc_id.as_deref(),
            node.run_id.as_deref(),
            "ok",
            json!({}),
        )?;
        Ok(json!({ "session_node": node }))
    }

    pub fn craftship_session_node_runtime_update(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.craftship_session_bind_node_runtime(actor, input)
    }

    pub fn craftship_session_message_send(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let craftship_session_id = required_str(&input, "craftship_session_id")?;
        let session = db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship session {} not found",
                craftship_session_id
            ))
        })?;
        let actor_node = self.resolve_team_actor_node(&conn, actor, craftship_session_id)?;
        let sender_session_node_id = if let Some(sender) =
            optional_str(&input, "sender_session_node_id")
        {
            let sender_node =
                Self::require_session_node_belongs_to_session(&conn, craftship_session_id, sender)?;
            if let Some(actor_node) = actor_node.as_ref() {
                if actor_node.session_node_id != sender_node.session_node_id {
                    return Err(BtError::Forbidden(
                        "agents may only send messages as their bound craftship node".to_string(),
                    ));
                }
            }
            Some(sender_node.session_node_id)
        } else {
            actor_node.as_ref().map(|node| node.session_node_id.clone())
        };

        let recipients = input
            .get("recipient_session_node_ids")
            .and_then(Value::as_array)
            .ok_or_else(|| {
                BtError::Validation("recipient_session_node_ids must be an array".to_string())
            })?
            .iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .collect::<Vec<_>>();
        if recipients.is_empty() {
            return Err(BtError::Validation(
                "at least one recipient_session_node_id is required".to_string(),
            ));
        }

        let body_md = required_str(&input, "body_md")?.trim().to_string();
        if body_md.is_empty() {
            return Err(BtError::Validation("body_md cannot be empty".to_string()));
        }
        let message_kind = optional_str(&input, "message_kind")
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(TEAM_MESSAGE_KIND_DEFAULT)
            .to_string();
        let subject = optional_str(&input, "subject")
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned);

        let now = Utc::now();
        let message = CraftshipTeamMessage {
            message_id: format!("cstm_{}", Uuid::new_v4().simple()),
            craftship_session_id: craftship_session_id.to_string(),
            sender_session_node_id: sender_session_node_id.clone(),
            message_kind,
            subject,
            body_md,
            created_at: now,
            updated_at: now,
        };
        db::insert_craftship_team_message(&conn, &message)?;

        let mut receipts = Vec::new();
        for recipient in recipients {
            let recipient_node = Self::require_session_node_belongs_to_session(
                &conn,
                craftship_session_id,
                recipient,
            )?;
            receipts.push(CraftshipTeamMessageReceipt {
                receipt_id: format!("cstr_{}", Uuid::new_v4().simple()),
                message_id: message.message_id.clone(),
                recipient_session_node_id: recipient_node.session_node_id,
                state: TEAM_RECEIPT_PENDING.to_string(),
                delivered_at: None,
                acknowledged_at: None,
                created_at: now,
                updated_at: now,
            });
        }
        db::insert_craftship_team_message_receipts(&conn, &receipts)?;

        self.emit_event(
            actor,
            "craftship.team_message.sent",
            session.doc_id.as_deref(),
            None,
            json!({
                "craftship_session_id": craftship_session_id,
                "message_id": message.message_id,
                "sender_session_node_id": sender_session_node_id,
                "recipient_session_node_ids": receipts.iter().map(|row| row.recipient_session_node_id.clone()).collect::<Vec<_>>(),
            }),
            None,
        )?;
        self.audit(
            actor,
            "crafting.craftship.session.message.send",
            &input,
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({ "message_id": message.message_id }),
        )?;
        Ok(json!({ "message": message, "receipts": receipts }))
    }

    pub fn craftship_session_message_ack(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let message_id = required_str(&input, "message_id")?;
        let message = db::get_craftship_team_message(&conn, message_id)?.ok_or_else(|| {
            BtError::NotFound(format!("craftship team message {} not found", message_id))
        })?;
        let actor_node =
            self.resolve_team_actor_node(&conn, actor, &message.craftship_session_id)?;
        let recipient_session_node_id = if let Some(recipient) =
            optional_str(&input, "recipient_session_node_id")
        {
            let node = Self::require_session_node_belongs_to_session(
                &conn,
                &message.craftship_session_id,
                recipient,
            )?;
            if let Some(actor_node) = actor_node.as_ref() {
                if actor_node.session_node_id != node.session_node_id {
                    return Err(BtError::Forbidden(
                            "agents may only acknowledge messages addressed to their bound craftship node"
                                .to_string(),
                        ));
                }
            }
            node.session_node_id
        } else {
            actor_node
                .as_ref()
                .map(|node| node.session_node_id.clone())
                .ok_or_else(|| {
                    BtError::Validation(
                        "recipient_session_node_id is required for non-agent actors".to_string(),
                    )
                })?
        };
        let mut receipt = db::get_craftship_team_message_receipt(
            &conn,
            &message.message_id,
            &recipient_session_node_id,
        )?
        .ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship team message receipt {}:{} not found",
                message.message_id, recipient_session_node_id
            ))
        })?;
        let next_state = Self::validate_team_message_receipt_state(
            optional_str(&input, "state").unwrap_or(TEAM_RECEIPT_ACKNOWLEDGED),
        )?;
        let now = Utc::now();
        if next_state == TEAM_RECEIPT_DELIVERED {
            receipt.delivered_at = Some(now);
        } else if next_state == TEAM_RECEIPT_ACKNOWLEDGED {
            if receipt.delivered_at.is_none() {
                receipt.delivered_at = Some(now);
            }
            receipt.acknowledged_at = Some(now);
        }
        receipt.state = next_state;
        receipt.updated_at = now;
        db::update_craftship_team_message_receipt(&conn, &receipt)?;

        let session =
            db::get_craftship_session(&conn, &message.craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    message.craftship_session_id
                ))
            })?;
        self.emit_event(
            actor,
            "craftship.team_message.acked",
            session.doc_id.as_deref(),
            None,
            json!({
                "craftship_session_id": message.craftship_session_id,
                "message_id": message.message_id,
                "recipient_session_node_id": receipt.recipient_session_node_id,
                "state": receipt.state,
            }),
            None,
        )?;
        self.audit(
            actor,
            "crafting.craftship.session.message.ack",
            &input,
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "receipt": receipt }))
    }

    pub fn craftship_session_message_inbox(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let craftship_session_id = required_str(&input, "craftship_session_id")?;
        let session = db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship session {} not found",
                craftship_session_id
            ))
        })?;
        let actor_node = self.resolve_team_actor_node(&conn, actor, craftship_session_id)?;
        let recipient_session_node_id = if let Some(recipient) =
            optional_str(&input, "recipient_session_node_id")
        {
            let node = Self::require_session_node_belongs_to_session(
                &conn,
                craftship_session_id,
                recipient,
            )?;
            if let Some(actor_node) = actor_node.as_ref() {
                if actor_node.session_node_id != node.session_node_id {
                    return Err(BtError::Forbidden(
                        "agents may only read inbox entries for their bound craftship node"
                            .to_string(),
                    ));
                }
            }
            node.session_node_id
        } else {
            actor_node
                .as_ref()
                .map(|node| node.session_node_id.clone())
                .ok_or_else(|| {
                    BtError::Validation(
                        "recipient_session_node_id is required for non-agent actors".to_string(),
                    )
                })?
        };
        let include_acknowledged = optional_bool(&input, "include_acknowledged")
            .or_else(|| optional_bool(&input, "includeAcknowledged"))
            .unwrap_or(false);
        let limit = input.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize;
        let acknowledge = optional_bool(&input, "acknowledge").unwrap_or(false);
        let entries = db::list_craftship_team_inbox_entries(
            &conn,
            &recipient_session_node_id,
            include_acknowledged,
            limit,
        )?;
        if acknowledge {
            for entry in &entries {
                let _ = self.craftship_session_message_ack(
                    actor,
                    json!({
                        "message_id": entry.message.message_id,
                        "recipient_session_node_id": recipient_session_node_id,
                        "state": TEAM_RECEIPT_ACKNOWLEDGED,
                    }),
                )?;
            }
        }
        self.audit(
            actor,
            "crafting.craftship.session.message.inbox",
            &input,
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({ "entry_count": entries.len() }),
        )?;
        Ok(Self::build_team_inbox_payload(&entries))
    }

    // ── Peer communication ─────────────────────────────────────────────

    pub fn peers_list(&self, _actor: &Actor, input: Value) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let craftship_session_id = required_str(&input, "craftship_session_id")?;
        let _session =
            db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    craftship_session_id
                ))
            })?;
        let nodes = db::list_craftship_session_nodes(&conn, craftship_session_id)?;

        let mut peers = Vec::new();
        for node in &nodes {
            let summary: Option<String> = conn
                .prepare("SELECT summary FROM peer_summaries WHERE session_node_id = ?1")
                .and_then(|mut stmt| stmt.query_row([&node.session_node_id], |row| row.get(0)))
                .ok();
            peers.push(json!({
                "node_id": node.session_node_id,
                "label": node.label,
                "framework": node.framework_id,
                "brand": node.brand_id,
                "status": node.status,
                "sort_order": node.sort_order,
                "summary": summary,
            }));
        }
        Ok(json!({ "peers": peers }))
    }

    pub fn peers_send(&self, actor: &Actor, input: Value) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let craftship_session_id = required_str(&input, "craftship_session_id")?;
        let _session =
            db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    craftship_session_id
                ))
            })?;
        let actor_node = self.resolve_team_actor_node(&conn, actor, craftship_session_id)?;
        let sender_id = actor_node.as_ref().map(|n| n.session_node_id.clone());

        let to = required_str(&input, "to")?;
        let _recipient_node =
            Self::require_session_node_belongs_to_session(&conn, craftship_session_id, to)?;

        let body = required_str(&input, "body")?.trim().to_string();
        if body.is_empty() {
            return Err(BtError::Validation("body cannot be empty".to_string()));
        }
        let thread = optional_str(&input, "thread").map(ToOwned::to_owned);

        let now = Utc::now();
        let message = CraftshipTeamMessage {
            message_id: format!("cstm_{}", Uuid::new_v4().simple()),
            craftship_session_id: craftship_session_id.to_string(),
            sender_session_node_id: sender_id,
            message_kind: "peer".to_string(),
            subject: thread,
            body_md: body,
            created_at: now,
            updated_at: now,
        };
        db::insert_craftship_team_message(&conn, &message)?;

        let receipt = CraftshipTeamMessageReceipt {
            receipt_id: format!("cstr_{}", Uuid::new_v4().simple()),
            message_id: message.message_id.clone(),
            recipient_session_node_id: to.to_string(),
            state: TEAM_RECEIPT_PENDING.to_string(),
            delivered_at: None,
            acknowledged_at: None,
            created_at: now,
            updated_at: now,
        };
        db::insert_craftship_team_message_receipts(&conn, &[receipt])?;

        Ok(json!({ "message_id": message.message_id, "sent": true }))
    }

    pub fn peers_poll(&self, actor: &Actor, input: Value) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let craftship_session_id = required_str(&input, "craftship_session_id")?;
        let _session =
            db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    craftship_session_id
                ))
            })?;
        let actor_node = self.resolve_team_actor_node(&conn, actor, craftship_session_id)?;
        let recipient_id = actor_node
            .as_ref()
            .map(|n| n.session_node_id.clone())
            .ok_or_else(|| {
                BtError::Validation("could not resolve peer node for actor".to_string())
            })?;

        let acknowledge = optional_bool(&input, "acknowledge").unwrap_or(false);
        let entries = db::list_craftship_team_inbox_entries(&conn, &recipient_id, false, 50)?;

        // Filter to peer messages only.
        let peer_entries: Vec<_> = entries
            .iter()
            .filter(|e| e.message.message_kind == "peer")
            .collect();

        // Build human-readable conversation output.
        let mut messages = Vec::new();
        for entry in &peer_entries {
            let sender_label = entry
                .message
                .sender_session_node_id
                .as_deref()
                .and_then(|id| {
                    db::list_craftship_session_nodes(&conn, craftship_session_id)
                        .ok()
                        .and_then(|nodes| {
                            nodes
                                .into_iter()
                                .find(|n| n.session_node_id == id)
                                .map(|n| n.label)
                        })
                })
                .unwrap_or_else(|| "unknown".to_string());
            messages.push(json!({
                "from": sender_label,
                "from_node_id": entry.message.sender_session_node_id,
                "body": entry.message.body_md,
                "thread": entry.message.subject,
                "sent_at": entry.message.created_at.to_rfc3339(),
                "message_id": entry.message.message_id,
            }));

            if acknowledge {
                let _ = self.craftship_session_message_ack(
                    actor,
                    json!({
                        "message_id": entry.message.message_id,
                        "recipient_session_node_id": recipient_id,
                        "state": TEAM_RECEIPT_ACKNOWLEDGED,
                    }),
                );
            }
        }
        Ok(json!({ "messages": messages }))
    }

    pub fn peers_set_summary(&self, actor: &Actor, input: Value) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let craftship_session_id = required_str(&input, "craftship_session_id")?;
        let _session =
            db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    craftship_session_id
                ))
            })?;
        let actor_node = self.resolve_team_actor_node(&conn, actor, craftship_session_id)?;
        let node_id = actor_node
            .as_ref()
            .map(|n| n.session_node_id.clone())
            .ok_or_else(|| {
                BtError::Validation("could not resolve peer node for actor".to_string())
            })?;

        let summary = required_str(&input, "summary")?;
        let summary = &summary[..summary.len().min(200)];

        let now = Utc::now().to_rfc3339();
        conn.execute(
            r#"INSERT INTO peer_summaries (session_node_id, craftship_session_id, summary, status, updated_at)
               VALUES (?1, ?2, ?3, 'active', ?4)
               ON CONFLICT(session_node_id) DO UPDATE SET summary = ?3, updated_at = ?4"#,
            [&node_id, craftship_session_id, summary, &now],
        )?;

        Ok(json!({ "ok": true, "node_id": node_id, "summary": summary }))
    }

    pub fn craftship_session_work_item_create(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let craftship_session_id = required_str(&input, "craftship_session_id")?;
        let session = db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship session {} not found",
                craftship_session_id
            ))
        })?;
        let actor_node = self.require_team_lead_or_operator(
            &conn,
            actor,
            craftship_session_id,
            "work_item.create",
        )?;
        let title = required_str(&input, "title")?.trim().to_string();
        if title.is_empty() {
            return Err(BtError::Validation("title cannot be empty".to_string()));
        }
        let assigned_session_node_id = optional_str(&input, "assigned_session_node_id")
            .map(|node_id| {
                Self::require_session_node_belongs_to_session(&conn, craftship_session_id, node_id)
                    .map(|node| node.session_node_id)
            })
            .transpose()?;
        let status = Self::validate_team_work_item_status(
            optional_str(&input, "status").unwrap_or(if assigned_session_node_id.is_some() {
                "assigned"
            } else {
                "ready"
            }),
        )?;
        if let Some(source_task_id) = optional_str(&input, "source_task_id") {
            let _ = db::get_task(&conn, source_task_id)?
                .ok_or_else(|| BtError::NotFound(format!("task {} not found", source_task_id)))?;
        }
        let now = Utc::now();
        let item = CraftshipTeamWorkItem {
            work_item_id: format!("cswi_{}", Uuid::new_v4().simple()),
            craftship_session_id: craftship_session_id.to_string(),
            source_task_id: optional_str(&input, "source_task_id").map(ToOwned::to_owned),
            created_by_session_node_id: actor_node.map(|node| node.session_node_id),
            assigned_session_node_id,
            status,
            title,
            description_md: optional_str(&input, "description_md").map(ToOwned::to_owned),
            success_criteria: input
                .get("success_criteria")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(ToOwned::to_owned)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default(),
            verification_hint: optional_str(&input, "verification_hint").map(ToOwned::to_owned),
            result_summary: None,
            worktree_ref: optional_str(&input, "worktree_ref").map(ToOwned::to_owned),
            branch_name: optional_str(&input, "branch_name").map(ToOwned::to_owned),
            changed_files: Vec::new(),
            commit_hash: None,
            claimed_at: None,
            completed_at: None,
            created_at: now,
            updated_at: now,
        };
        db::insert_craftship_team_work_item(&conn, &item)?;
        self.emit_event(
            actor,
            "craftship.work_item.created",
            session.doc_id.as_deref(),
            None,
            json!({
                "craftship_session_id": craftship_session_id,
                "work_item_id": item.work_item_id,
                "assigned_session_node_id": item.assigned_session_node_id,
                "status": item.status,
            }),
            None,
        )?;
        self.audit(
            actor,
            "crafting.craftship.session.work_item.create",
            &input,
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({ "work_item_id": item.work_item_id }),
        )?;
        Ok(json!({ "work_item": item }))
    }

    pub fn craftship_session_work_item_list(&self, input: Value) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let craftship_session_id = required_str(&input, "craftship_session_id")?;
        let items = db::list_craftship_team_work_items(
            &conn,
            craftship_session_id,
            optional_str(&input, "status"),
            optional_str(&input, "assigned_session_node_id"),
            optional_bool(&input, "include_closed")
                .or_else(|| optional_bool(&input, "includeClosed"))
                .unwrap_or(false),
            input.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize,
        )?;
        Ok(json!({ "work_items": items }))
    }

    pub fn craftship_session_work_item_assign(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let work_item_id = required_str(&input, "work_item_id")?;
        let mut item = db::get_craftship_team_work_item(&conn, work_item_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship team work item {} not found",
                work_item_id
            ))
        })?;
        self.require_team_lead_or_operator(
            &conn,
            actor,
            &item.craftship_session_id,
            "work_item.assign",
        )?;
        let assigned = required_str(&input, "assigned_session_node_id")?;
        let node = Self::require_session_node_belongs_to_session(
            &conn,
            &item.craftship_session_id,
            assigned,
        )?;
        item.assigned_session_node_id = Some(node.session_node_id);
        item.status = "assigned".to_string();
        item.updated_at = Utc::now();
        db::update_craftship_team_work_item(&conn, &item)?;
        let session =
            db::get_craftship_session(&conn, &item.craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    item.craftship_session_id
                ))
            })?;
        self.emit_event(
            actor,
            "craftship.work_item.assigned",
            session.doc_id.as_deref(),
            None,
            json!({
                "craftship_session_id": item.craftship_session_id,
                "work_item_id": item.work_item_id,
                "assigned_session_node_id": item.assigned_session_node_id,
            }),
            None,
        )?;
        self.audit(
            actor,
            "crafting.craftship.session.work_item.assign",
            &input,
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "work_item": item }))
    }

    pub fn craftship_session_work_item_claim(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let work_item_id = required_str(&input, "work_item_id")?;
        let mut item = db::get_craftship_team_work_item(&conn, work_item_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship team work item {} not found",
                work_item_id
            ))
        })?;
        let actor_node = self.require_team_actor_node(&conn, actor, &item.craftship_session_id)?;
        if item.assigned_session_node_id.as_deref() != Some(actor_node.session_node_id.as_str()) {
            return Err(BtError::Forbidden(
                "workers may only claim work items assigned to their craftship node".to_string(),
            ));
        }
        item.status = "claimed".to_string();
        if item.claimed_at.is_none() {
            item.claimed_at = Some(Utc::now());
        }
        item.updated_at = Utc::now();
        db::update_craftship_team_work_item(&conn, &item)?;
        let session =
            db::get_craftship_session(&conn, &item.craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    item.craftship_session_id
                ))
            })?;
        self.emit_event(
            actor,
            "craftship.work_item.claimed",
            session.doc_id.as_deref(),
            None,
            json!({
                "craftship_session_id": item.craftship_session_id,
                "work_item_id": item.work_item_id,
                "claimed_by_session_node_id": actor_node.session_node_id,
            }),
            None,
        )?;
        self.audit(
            actor,
            "crafting.craftship.session.work_item.claim",
            &input,
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "work_item": item }))
    }

    pub fn craftship_session_work_item_update(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let work_item_id = required_str(&input, "work_item_id")?;
        let mut item = db::get_craftship_team_work_item(&conn, work_item_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship team work item {} not found",
                work_item_id
            ))
        })?;
        let actor_node = self.resolve_team_actor_node(&conn, actor, &item.craftship_session_id)?;
        if let Some(actor_node) = actor_node.as_ref() {
            if item.assigned_session_node_id.as_deref() != Some(actor_node.session_node_id.as_str())
            {
                return Err(BtError::Forbidden(
                    "workers may only update work items assigned to their craftship node"
                        .to_string(),
                ));
            }
        }
        if let Some(status) = optional_str(&input, "status") {
            let next_status = Self::validate_team_work_item_status(status)?;
            if actor_node.is_some()
                && !matches!(next_status.as_str(), "claimed" | "in_progress" | "blocked")
            {
                return Err(BtError::Forbidden(
                    "workers may only move work items into claimed, in_progress, or blocked"
                        .to_string(),
                ));
            }
            if matches!(next_status.as_str(), "claimed" | "in_progress")
                && item.claimed_at.is_none()
            {
                item.claimed_at = Some(Utc::now());
            }
            item.status = next_status;
        }
        if input.get("result_summary").is_some() {
            item.result_summary = optional_str(&input, "result_summary").map(ToOwned::to_owned);
        }
        if input.get("worktree_ref").is_some() {
            item.worktree_ref = optional_str(&input, "worktree_ref").map(ToOwned::to_owned);
        }
        if input.get("branch_name").is_some() {
            item.branch_name = optional_str(&input, "branch_name").map(ToOwned::to_owned);
        }
        if input.get("commit_hash").is_some() {
            item.commit_hash = optional_str(&input, "commit_hash").map(ToOwned::to_owned);
        }
        if input.get("changed_files").is_some() {
            item.changed_files = input
                .get("changed_files")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(ToOwned::to_owned)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
        }
        item.updated_at = Utc::now();
        db::update_craftship_team_work_item(&conn, &item)?;
        let session =
            db::get_craftship_session(&conn, &item.craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    item.craftship_session_id
                ))
            })?;
        self.emit_event(
            actor,
            "craftship.work_item.updated",
            session.doc_id.as_deref(),
            None,
            json!({
                "craftship_session_id": item.craftship_session_id,
                "work_item_id": item.work_item_id,
                "status": item.status,
                "assigned_session_node_id": item.assigned_session_node_id,
            }),
            None,
        )?;
        self.audit(
            actor,
            "crafting.craftship.session.work_item.update",
            &input,
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "work_item": item }))
    }

    pub fn craftship_session_work_item_complete(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let work_item_id = required_str(&input, "work_item_id")?;
        let mut item = db::get_craftship_team_work_item(&conn, work_item_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship team work item {} not found",
                work_item_id
            ))
        })?;
        if let Some(actor_node) =
            self.resolve_team_actor_node(&conn, actor, &item.craftship_session_id)?
        {
            if item.assigned_session_node_id.as_deref() != Some(actor_node.session_node_id.as_str())
            {
                return Err(BtError::Forbidden(
                    "workers may only complete work items assigned to their craftship node"
                        .to_string(),
                ));
            }
        } else {
            self.require_team_lead_or_operator(
                &conn,
                actor,
                &item.craftship_session_id,
                "work_item.complete",
            )?;
        }
        let result_summary = required_str(&input, "result_summary")?.trim().to_string();
        if result_summary.is_empty() {
            return Err(BtError::Validation(
                "result_summary cannot be empty".to_string(),
            ));
        }
        item.result_summary = Some(result_summary);
        item.status = "completed".to_string();
        let now = Utc::now();
        if item.claimed_at.is_none() {
            item.claimed_at = Some(now);
        }
        item.completed_at = Some(now);
        item.updated_at = now;
        if input.get("worktree_ref").is_some() {
            item.worktree_ref = optional_str(&input, "worktree_ref").map(ToOwned::to_owned);
        }
        if input.get("branch_name").is_some() {
            item.branch_name = optional_str(&input, "branch_name").map(ToOwned::to_owned);
        }
        if input.get("commit_hash").is_some() {
            item.commit_hash = optional_str(&input, "commit_hash").map(ToOwned::to_owned);
        }
        if input.get("changed_files").is_some() {
            item.changed_files = input
                .get("changed_files")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .filter_map(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(ToOwned::to_owned)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
        }
        db::update_craftship_team_work_item(&conn, &item)?;
        let session =
            db::get_craftship_session(&conn, &item.craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    item.craftship_session_id
                ))
            })?;
        self.emit_event(
            actor,
            "craftship.work_item.completed",
            session.doc_id.as_deref(),
            None,
            json!({
                "craftship_session_id": item.craftship_session_id,
                "work_item_id": item.work_item_id,
                "assigned_session_node_id": item.assigned_session_node_id,
            }),
            None,
        )?;
        self.audit(
            actor,
            "crafting.craftship.session.work_item.complete",
            &input,
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "work_item": item }))
    }

    pub fn craftship_session_work_item_cancel(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let work_item_id = required_str(&input, "work_item_id")?;
        let mut item = db::get_craftship_team_work_item(&conn, work_item_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship team work item {} not found",
                work_item_id
            ))
        })?;
        self.require_team_lead_or_operator(
            &conn,
            actor,
            &item.craftship_session_id,
            "work_item.cancel",
        )?;
        item.status = "canceled".to_string();
        item.updated_at = Utc::now();
        db::update_craftship_team_work_item(&conn, &item)?;
        let session =
            db::get_craftship_session(&conn, &item.craftship_session_id)?.ok_or_else(|| {
                BtError::NotFound(format!(
                    "craftship session {} not found",
                    item.craftship_session_id
                ))
            })?;
        self.emit_event(
            actor,
            "craftship.work_item.canceled",
            session.doc_id.as_deref(),
            None,
            json!({
                "craftship_session_id": item.craftship_session_id,
                "work_item_id": item.work_item_id,
            }),
            None,
        )?;
        self.audit(
            actor,
            "crafting.craftship.session.work_item.cancel",
            &input,
            session.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "work_item": item }))
    }

    pub fn craftship_session_orchestration_sync_from_doc(
        &self,
        actor: &Actor,
        input: Value,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let craftship_session_id = required_str(&input, "craftship_session_id")?;
        let requested_doc_id =
            optional_str(&input, "source_doc_id").or_else(|| optional_str(&input, "sourceDocId"));
        let doc_plan_handoff_id = optional_str(&input, "doc_plan_handoff_id")
            .or_else(|| optional_str(&input, "docPlanHandoffId"));

        let conn = self.open_conn()?;
        let session = db::get_craftship_session(&conn, craftship_session_id)?.ok_or_else(|| {
            BtError::NotFound(format!(
                "craftship session {} not found",
                craftship_session_id
            ))
        })?;
        let lead_node = self.require_team_lead_or_operator(
            &conn,
            actor,
            craftship_session_id,
            "orchestration.sync_from_doc",
        )?;
        let source_doc_id = requested_doc_id
            .or(session.source_doc_id.as_deref())
            .or(session.doc_id.as_deref())
            .ok_or_else(|| {
                BtError::Validation(
                    "craftship session orchestration sync needs a source_doc_id".to_string(),
                )
            })?;
        let doc = db::get_doc(&conn, source_doc_id)?
            .ok_or_else(|| BtError::NotFound(format!("doc {} not found", source_doc_id)))?;
        if let Some(handoff_id) = doc_plan_handoff_id {
            let handoff = db::get_doc_plan_handoff(&conn, handoff_id)?.ok_or_else(|| {
                BtError::NotFound(format!("doc plan handoff {} not found", handoff_id))
            })?;
            if handoff.doc_id != doc.id {
                return Err(BtError::Validation(format!(
                    "doc plan handoff {} does not belong to doc {}",
                    handoff_id, doc.id
                )));
            }
        }

        let root = self.require_vault()?;
        let agent_path = fs_guard::safe_join(&root, Path::new(&doc.agent_path))?;
        let agent_content = fs::read_to_string(agent_path)?;
        let task_plan = parse_dome_task_plan(&agent_content)?.ok_or_else(|| {
            BtError::Validation("agent.md is missing a valid dome-task-plan block".to_string())
        })?;
        let craftship_plan = parse_dome_craftship_plan(&agent_content)?.ok_or_else(|| {
            BtError::Validation("agent.md is missing a valid dome-craftship-plan block".to_string())
        })?;
        if craftship_plan.craftship_id != session.craftship_id {
            return Err(BtError::Validation(format!(
                "dome-craftship-plan craftship_id {} does not match craftship session craftship_id {}",
                craftship_plan.craftship_id, session.craftship_id
            )));
        }

        let task_plan_by_order = task_plan
            .tasks
            .iter()
            .cloned()
            .map(|entry| (entry.order, entry))
            .collect::<BTreeMap<_, _>>();
        for step in &craftship_plan.steps {
            let task_entry = task_plan_by_order.get(&step.task_order).ok_or_else(|| {
                BtError::Validation(format!(
                    "dome-craftship-plan task_order {} does not exist in dome-task-plan",
                    step.task_order
                ))
            })?;
            if normalize_task_title(&step.task_title) != normalize_task_title(&task_entry.title) {
                return Err(BtError::Validation(format!(
                    "dome-craftship-plan task_title {:?} does not match dome-task-plan title {:?} for task_order {}",
                    step.task_title, task_entry.title, step.task_order
                )));
            }
        }

        let nodes: Vec<_> = db::list_craftship_session_nodes(&conn, craftship_session_id)?
            .into_iter()
            .filter(|n| !n.session_node_id.starts_with("cssn_req_"))
            .collect();
        let lead_session_node_id = lead_node
            .as_ref()
            .map(|node| node.session_node_id.clone())
            .or_else(|| {
                nodes
                    .iter()
                    .find(|node| node.parent_session_node_id.is_none())
                    .map(|node| node.session_node_id.clone())
            });
        let session_nodes_by_template = nodes
            .iter()
            .filter_map(|node| {
                node.template_node_id
                    .as_ref()
                    .map(|template_node_id| (template_node_id.clone(), node.clone()))
            })
            .collect::<HashMap<_, _>>();
        for step in &craftship_plan.steps {
            for assignment in &step.assignments {
                if !session_nodes_by_template.contains_key(&assignment.template_node_id) {
                    return Err(BtError::Validation(format!(
                        "dome-craftship-plan template_node_id {} does not exist in craftship session {}",
                        assignment.template_node_id, craftship_session_id
                    )));
                }
            }
        }
        drop(conn);

        let task_sync = self.task_plan_sync_from_doc(actor, &doc.id)?;

        let conn = self.open_conn()?;
        let active_task = db::get_active_task_for_doc(&conn, Some(&doc.id))?;
        let active_plan_entry = if let Some(task) = active_task.as_ref() {
            Some(
                task_plan
                    .tasks
                    .iter()
                    .find(|entry| task_plan_entry_matches_active(entry, task))
                    .cloned()
                    .ok_or_else(|| {
                        BtError::Validation(format!(
                            "active task {:?} is not present in dome-task-plan",
                            task.title
                        ))
                    })?,
            )
        } else {
            None
        };
        let active_craftship_step = if let Some(entry) = active_plan_entry.as_ref() {
            Some(
                craftship_plan
                    .steps
                    .iter()
                    .find(|step| step.task_order == entry.order)
                    .cloned()
                    .ok_or_else(|| {
                        BtError::Validation(format!(
                            "dome-craftship-plan is missing the active task_order {}",
                            entry.order
                        ))
                    })?,
            )
        } else {
            None
        };

        let all_items =
            db::list_craftship_team_work_items(&conn, craftship_session_id, None, None, true, 500)?;
        let mut existing_by_id = all_items
            .iter()
            .cloned()
            .map(|item| (item.work_item_id.clone(), item))
            .collect::<HashMap<_, _>>();
        let now = Utc::now();
        let mut desired_open_ids = HashSet::new();
        let mut created_work_item_ids = Vec::new();
        let mut updated_work_item_ids = Vec::new();
        let mut canceled_work_item_ids = Vec::new();
        let mut notifications = Vec::new();

        if let (Some(task), Some(step)) = (active_task.as_ref(), active_craftship_step.as_ref()) {
            for assignment in &step.assignments {
                let session_node = session_nodes_by_template
                    .get(&assignment.template_node_id)
                    .cloned()
                    .ok_or_else(|| {
                        BtError::Validation(format!(
                            "dome-craftship-plan template_node_id {} no longer resolves in craftship session {}",
                            assignment.template_node_id, craftship_session_id
                        ))
                    })?;
                let work_item_id = Self::craftship_sync_work_item_id(
                    craftship_session_id,
                    &task.id,
                    &assignment.template_node_id,
                    &assignment.title,
                );
                let mut should_notify = false;

                if let Some(mut existing) = existing_by_id.remove(&work_item_id) {
                    let was_closed = Self::team_work_item_is_closed(&existing.status);
                    let mut changed = false;
                    let mut reassigned = false;

                    if existing.source_task_id.as_deref() != Some(task.id.as_str()) {
                        existing.source_task_id = Some(task.id.clone());
                        changed = true;
                    }
                    if existing.created_by_session_node_id.is_none()
                        && lead_session_node_id.is_some()
                    {
                        existing.created_by_session_node_id = lead_session_node_id.clone();
                        changed = true;
                    }
                    if existing.title != assignment.title {
                        existing.title = assignment.title.clone();
                        changed = true;
                        should_notify = true;
                    }
                    if existing.description_md.as_deref()
                        != Some(assignment.description_md.as_str())
                    {
                        existing.description_md = Some(assignment.description_md.clone());
                        changed = true;
                        should_notify = true;
                    }
                    if existing.success_criteria != assignment.success_criteria {
                        existing.success_criteria = assignment.success_criteria.clone();
                        changed = true;
                        should_notify = true;
                    }
                    if existing.verification_hint != assignment.verification_hint {
                        existing.verification_hint = assignment.verification_hint.clone();
                        changed = true;
                        should_notify = true;
                    }
                    if existing.assigned_session_node_id.as_deref()
                        != Some(session_node.session_node_id.as_str())
                    {
                        existing.assigned_session_node_id =
                            Some(session_node.session_node_id.clone());
                        reassigned = true;
                        changed = true;
                        should_notify = true;
                    }

                    if !was_closed {
                        if reassigned {
                            existing.status = "assigned".to_string();
                            existing.claimed_at = None;
                            existing.completed_at = None;
                            existing.result_summary = None;
                            existing.worktree_ref = None;
                            existing.branch_name = None;
                            existing.changed_files.clear();
                            existing.commit_hash = None;
                        } else if matches!(existing.status.as_str(), "proposed" | "ready") {
                            existing.status = "assigned".to_string();
                            changed = true;
                        }
                    }

                    if changed {
                        existing.updated_at = now;
                        db::update_craftship_team_work_item(&conn, &existing)?;
                        self.emit_event(
                            actor,
                            "craftship.work_item.updated",
                            session.doc_id.as_deref(),
                            None,
                            json!({
                                "craftship_session_id": craftship_session_id,
                                "work_item_id": existing.work_item_id,
                                "status": existing.status,
                                "assigned_session_node_id": existing.assigned_session_node_id,
                            }),
                            None,
                        )?;
                        updated_work_item_ids.push(existing.work_item_id.clone());
                    }

                    if !Self::team_work_item_is_closed(&existing.status) {
                        desired_open_ids.insert(existing.work_item_id.clone());
                    }
                    if !was_closed && should_notify {
                        notifications.push((
                            session_node.session_node_id.clone(),
                            existing.work_item_id.clone(),
                            task.title.clone(),
                            assignment.title.clone(),
                            assignment.description_md.clone(),
                            assignment.success_criteria.clone(),
                            assignment.verification_hint.clone(),
                        ));
                    }
                } else {
                    let item = CraftshipTeamWorkItem {
                        work_item_id: work_item_id.clone(),
                        craftship_session_id: craftship_session_id.to_string(),
                        source_task_id: Some(task.id.clone()),
                        created_by_session_node_id: lead_session_node_id.clone(),
                        assigned_session_node_id: Some(session_node.session_node_id.clone()),
                        status: "assigned".to_string(),
                        title: assignment.title.clone(),
                        description_md: Some(assignment.description_md.clone()),
                        success_criteria: assignment.success_criteria.clone(),
                        verification_hint: assignment.verification_hint.clone(),
                        result_summary: None,
                        worktree_ref: None,
                        branch_name: None,
                        changed_files: Vec::new(),
                        commit_hash: None,
                        claimed_at: None,
                        completed_at: None,
                        created_at: now,
                        updated_at: now,
                    };
                    db::insert_craftship_team_work_item(&conn, &item)?;
                    self.emit_event(
                        actor,
                        "craftship.work_item.created",
                        session.doc_id.as_deref(),
                        None,
                        json!({
                            "craftship_session_id": craftship_session_id,
                            "work_item_id": item.work_item_id,
                            "assigned_session_node_id": item.assigned_session_node_id,
                            "status": item.status,
                        }),
                        None,
                    )?;
                    created_work_item_ids.push(item.work_item_id.clone());
                    desired_open_ids.insert(item.work_item_id.clone());
                    notifications.push((
                        session_node.session_node_id.clone(),
                        item.work_item_id.clone(),
                        task.title.clone(),
                        assignment.title.clone(),
                        assignment.description_md.clone(),
                        assignment.success_criteria.clone(),
                        assignment.verification_hint.clone(),
                    ));
                }
            }
        }

        for mut item in all_items {
            if desired_open_ids.contains(&item.work_item_id)
                || Self::team_work_item_is_closed(&item.status)
            {
                continue;
            }
            item.status = "canceled".to_string();
            item.updated_at = now;
            db::update_craftship_team_work_item(&conn, &item)?;
            self.emit_event(
                actor,
                "craftship.work_item.canceled",
                session.doc_id.as_deref(),
                None,
                json!({
                    "craftship_session_id": craftship_session_id,
                    "work_item_id": item.work_item_id,
                }),
                None,
            )?;
            canceled_work_item_ids.push(item.work_item_id);
        }

        for (
            recipient_session_node_id,
            work_item_id,
            source_task_title,
            item_title,
            description_md,
            success_criteria,
            verification_hint,
        ) in notifications
        {
            let mut body_lines = vec![
                format!(
                    "You are assigned work for the active top-level task \"{}\".",
                    source_task_title
                ),
                format!("Work item id: {}", work_item_id),
                format!("Title: {}", item_title),
                String::new(),
                description_md,
            ];
            if !success_criteria.is_empty() {
                body_lines.push(String::new());
                body_lines.push("Success criteria:".to_string());
                for criterion in success_criteria {
                    body_lines.push(format!("- {}", criterion));
                }
            }
            if let Some(hint) = verification_hint {
                body_lines.push(String::new());
                body_lines.push(format!("Verification: {}", hint));
            }
            body_lines.push(String::new());
            body_lines.push(format!(
                "Claim it with `bt team work claim --work-item-id {}` and keep the work item updated as you work.",
                work_item_id
            ));
            self.craftship_session_message_send(
                actor,
                json!({
                    "craftship_session_id": craftship_session_id,
                    "sender_session_node_id": lead_session_node_id,
                    "recipient_session_node_ids": [recipient_session_node_id],
                    "subject": format!("Assignment: {}", item_title),
                    "message_kind": "assignment",
                    "body_md": body_lines.join("\n"),
                }),
            )?;
        }

        let completed_handoff = if let Some(handoff_id) = doc_plan_handoff_id {
            Some(
                self.doc_plan_handoff_complete(actor, handoff_id)?
                    .get("handoff")
                    .cloned()
                    .unwrap_or(Value::Null),
            )
        } else {
            None
        };
        let open_work_items = db::list_craftship_team_work_items(
            &conn,
            craftship_session_id,
            None,
            None,
            false,
            500,
        )?;

        self.emit_event(
            actor,
            "craftship.orchestration.synced",
            Some(&doc.id),
            None,
            json!({
                "craftship_session_id": craftship_session_id,
                "doc_id": doc.id,
                "active_task_id": active_task.as_ref().map(|task| task.id.clone()),
                "active_task_title": active_task.as_ref().map(|task| task.title.clone()),
                "created_work_item_ids": created_work_item_ids,
                "updated_work_item_ids": updated_work_item_ids,
                "canceled_work_item_ids": canceled_work_item_ids,
                "open_work_item_ids": open_work_items.iter().map(|item| item.work_item_id.clone()).collect::<Vec<_>>(),
            }),
            None,
        )?;
        self.audit(
            actor,
            "crafting.craftship.session.orchestration.sync_from_doc",
            &input,
            Some(&doc.id),
            None,
            "ok",
            json!({
                "active_task_id": active_task.as_ref().map(|task| task.id.clone()),
                "created_work_item_ids": created_work_item_ids,
                "updated_work_item_ids": updated_work_item_ids,
                "canceled_work_item_ids": canceled_work_item_ids,
                "handoff_completed": completed_handoff.is_some(),
            }),
        )?;

        Ok(json!({
            "doc_id": doc.id,
            "task_sync": task_sync,
            "active_task": active_task,
            "open_work_items": open_work_items,
            "completed_handoff": completed_handoff,
        }))
    }

    fn parse_chain_of_thought_config(value: Option<&Value>) -> ChainOfThoughtConfig {
        let defaults = ChainOfThoughtConfig {
            autonomy_level: "balanced".to_string(),
            workflow_order: "research_plan_implement".to_string(),
            priority_focus: "core_feature_first".to_string(),
            planning_depth: "standard".to_string(),
            research_preference: "balanced".to_string(),
            set_pillar: "knowledge_notes_calendar".to_string(),
        };
        let Some(value) = value else {
            return defaults;
        };
        let obj = value.as_object();
        let field = |key: &str, fallback: &str| -> String {
            obj.and_then(|row| row.get(key))
                .and_then(Value::as_str)
                .map(|raw| raw.trim().to_string())
                .filter(|raw| !raw.is_empty())
                .unwrap_or_else(|| fallback.to_string())
        };
        ChainOfThoughtConfig {
            autonomy_level: field("autonomy_level", &defaults.autonomy_level),
            workflow_order: field("workflow_order", &defaults.workflow_order),
            priority_focus: field("priority_focus", &defaults.priority_focus),
            planning_depth: field("planning_depth", &defaults.planning_depth),
            research_preference: field("research_preference", &defaults.research_preference),
            set_pillar: field("set_pillar", &defaults.set_pillar),
        }
    }

    fn parse_chain_of_knowledge_config(value: Option<&Value>) -> ChainOfKnowledgeConfig {
        let defaults = ChainOfKnowledgeConfig {
            focus_mode: "unrestricted".to_string(),
            allowed_knowledge: Vec::new(),
            blocked_knowledge: Vec::new(),
        };
        let Some(value) = value else {
            return defaults;
        };
        let obj = value.as_object();
        let parse_list = |key: &str| -> Vec<String> {
            obj.and_then(|row| row.get(key))
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .filter_map(|entry| entry.as_str())
                        .map(str::trim)
                        .filter(|entry| !entry.is_empty())
                        .map(ToOwned::to_owned)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        };

        let mut parsed = ChainOfKnowledgeConfig {
            focus_mode: obj
                .and_then(|row| row.get("focus_mode"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .unwrap_or(defaults.focus_mode),
            allowed_knowledge: parse_list("allowed_knowledge"),
            blocked_knowledge: parse_list("blocked_knowledge"),
        };

        match parsed.focus_mode.as_str() {
            "allowed_only" | "focused" | "strict" => {
                parsed.focus_mode = "allowed_only".to_string();
                parsed.blocked_knowledge.clear();
            }
            "blocked_only" | "exclude_list" | "avoid_blocked" => {
                parsed.focus_mode = "blocked_only".to_string();
                parsed.allowed_knowledge.clear();
            }
            _ => {
                parsed.focus_mode = "unrestricted".to_string();
                parsed.allowed_knowledge.clear();
                parsed.blocked_knowledge.clear();
            }
        }
        parsed
    }

    fn enhance_framework_instruction(
        name: &str,
        custom_instruction: &str,
        chain_of_thought: &ChainOfThoughtConfig,
        chain_of_knowledge: &ChainOfKnowledgeConfig,
    ) -> String {
        let allowed = if chain_of_knowledge.allowed_knowledge.is_empty() {
            "none".to_string()
        } else {
            chain_of_knowledge.allowed_knowledge.join(", ")
        };
        let blocked = if chain_of_knowledge.blocked_knowledge.is_empty() {
            "none".to_string()
        } else {
            chain_of_knowledge.blocked_knowledge.join(", ")
        };

        format!(
            "# Framework: {name}\n\n\
User Intent\n\
{custom_instruction}\n\n\
Execution Controls\n\
- chain_of_thought.autonomy_level: {autonomy_level}\n\
- chain_of_thought.workflow_order: {workflow_order}\n\
- chain_of_thought.priority_focus: {priority_focus}\n\
- chain_of_thought.planning_depth: {planning_depth}\n\
- chain_of_thought.research_preference: {research_preference}\n\
- chain_of_thought.set_pillar: {set_pillar}\n\
- chain_of_knowledge.focus_mode: {focus_mode}\n\
- chain_of_knowledge.allowed_knowledge: {allowed}\n\
- chain_of_knowledge.blocked_knowledge: {blocked}\n\n\
Behavioral Policy\n\
1. Start with the selected workflow order and keep reasoning aligned to priority focus.\n\
2. Use set_pillar as the source priority order before acting.\n\
3. Increase planning depth and research effort according to autonomy_level.\n\
4. In focus_mode allowed_only, use only allowed_knowledge and ignore all other knowledge.\n\
5. In focus_mode blocked_only, use all available knowledge except blocked_knowledge.\n\
6. Keep output explicit about assumptions, constraints, risks, and verification steps.\n\
7. If constraints conflict, prefer correctness, safety, and objective completion over speed.\n",
            name = name,
            custom_instruction = custom_instruction,
            autonomy_level = chain_of_thought.autonomy_level,
            workflow_order = chain_of_thought.workflow_order,
            priority_focus = chain_of_thought.priority_focus,
            planning_depth = chain_of_thought.planning_depth,
            research_preference = chain_of_thought.research_preference,
            set_pillar = chain_of_thought.set_pillar,
            focus_mode = chain_of_knowledge.focus_mode,
            allowed = allowed,
            blocked = blocked,
        )
    }

    fn validate_runtime_brand(brand: &str) -> Result<String, BtError> {
        let normalized = Self::normalize_brand_id(brand);
        if Self::runtime_brand_exists(&normalized) {
            Ok(normalized)
        } else {
            Err(BtError::Validation(format!(
                "unsupported runtime brand {}",
                brand
            )))
        }
    }

    /// Validate that `brand` is one of the three brands the Required-Steps
    /// agent is allowed to run as. Keeps the list authoritative server-side
    /// (the UI picker hardcodes the same three, but the server is the source
    /// of truth).
    fn validate_required_agent_brand(brand: &str) -> Result<String, BtError> {
        let normalized = Self::normalize_brand_id(brand);
        if REQUIRED_AGENT_SUPPORTED_BRANDS
            .iter()
            .any(|b| *b == normalized)
        {
            Ok(normalized)
        } else {
            Err(BtError::Validation(format!(
                "required-steps agent brand must be one of {:?}, got {}",
                REQUIRED_AGENT_SUPPORTED_BRANDS, brand
            )))
        }
    }

    fn validate_craftship_mode(mode: &str) -> Result<String, BtError> {
        let normalized = mode.trim().to_ascii_lowercase();
        if matches!(normalized.as_str(), "template" | "personalized") {
            Ok(normalized)
        } else {
            Err(BtError::Validation(
                "mode must be template or personalized".to_string(),
            ))
        }
    }

    fn validate_craftship_node_kind(kind: &str) -> Result<String, BtError> {
        let normalized = kind.trim().to_ascii_lowercase();
        if matches!(normalized.as_str(), "root" | "subagent" | "custom") {
            Ok(normalized)
        } else {
            Err(BtError::Validation(
                "node_kind must be root, subagent, or custom".to_string(),
            ))
        }
    }

    fn validate_craftship_launch_mode(mode: &str) -> Result<String, BtError> {
        let normalized = mode.trim().to_ascii_lowercase();
        if matches!(normalized.as_str(), "new" | "attach") {
            Ok(normalized)
        } else {
            Err(BtError::Validation(
                "launch_mode must be new or attach".to_string(),
            ))
        }
    }

    fn validate_craftship_session_status(status: &str) -> Result<String, BtError> {
        let normalized = status.trim().to_ascii_lowercase();
        if matches!(
            normalized.as_str(),
            "live" | "saved" | "completed" | "archived"
        ) {
            Ok(normalized)
        } else {
            Err(BtError::Validation(
                "status must be live, saved, completed, or archived".to_string(),
            ))
        }
    }

    fn craftship_session_context_doc_id(session: &CraftshipSession) -> Option<&str> {
        session
            .source_doc_id
            .as_deref()
            .or(session.doc_id.as_deref())
    }

    fn default_craftship_nodes(craftship_id: &str, now: DateTime<Utc>) -> Vec<CraftshipNode> {
        let root_id = format!("csn_{}", Uuid::new_v4().simple());
        let mut nodes = vec![CraftshipNode {
            node_id: root_id.clone(),
            craftship_id: craftship_id.to_string(),
            parent_node_id: None,
            label: "Primary Agent".to_string(),
            node_kind: "root".to_string(),
            framework_id: None,
            brand_id: None,
            sort_order: 0,
            created_at: now,
            updated_at: now,
        }];
        for index in 0..3 {
            nodes.push(CraftshipNode {
                node_id: format!("csn_{}", Uuid::new_v4().simple()),
                craftship_id: craftship_id.to_string(),
                parent_node_id: Some(root_id.clone()),
                label: format!("Subagent {}", index + 1),
                node_kind: "subagent".to_string(),
                framework_id: None,
                brand_id: None,
                sort_order: (index + 1) as i64,
                created_at: now,
                updated_at: now,
            });
        }
        nodes
    }

    fn create_new_craftship_session(
        &self,
        _actor: &Actor,
        conn: &rusqlite::Connection,
        craftship: &Craftship,
        runtime_brand: &str,
        launch_mode: String,
        requested_source_doc_id: Option<String>,
        input: &Value,
        now: DateTime<Utc>,
        pre_doc_id: Option<String>,
    ) -> Result<CraftshipSession, BtError> {
        let session_name = optional_str(input, "name")
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| format!("{} Session", craftship.name));
        let doc_id = match pre_doc_id {
            Some(id) => id,
            None => {
                self.ensure_craftship_session_doc(conn, craftship, &session_name, runtime_brand)?
            }
        };
        let session = CraftshipSession {
            craftship_session_id: format!("css_{}", Uuid::new_v4().simple()),
            craftship_id: craftship.craftship_id.clone(),
            name: session_name,
            status: "live".to_string(),
            launch_mode,
            runtime_brand: runtime_brand.to_string(),
            doc_id: Some(doc_id),
            source_doc_id: requested_source_doc_id,
            last_context_pack_id: None,
            created_at: now,
            updated_at: now,
        };
        let craftship_nodes = db::list_craftship_nodes(conn, &craftship.craftship_id)?;
        let session_nodes = Self::build_craftship_session_nodes(
            &session.craftship_session_id,
            &craftship_nodes,
            now,
        );
        db::insert_craftship_session(conn, &session)?;
        db::replace_craftship_session_nodes(conn, &session.craftship_session_id, &session_nodes)?;
        Ok(session)
    }

    fn build_craftship_session_nodes(
        craftship_session_id: &str,
        template_nodes: &[CraftshipNode],
        now: DateTime<Utc>,
    ) -> Vec<CraftshipSessionNode> {
        let mut id_map = HashMap::new();
        for node in template_nodes {
            id_map.insert(
                node.node_id.clone(),
                format!("cssn_{}", Uuid::new_v4().simple()),
            );
        }
        template_nodes
            .iter()
            .map(|node| CraftshipSessionNode {
                session_node_id: id_map
                    .get(&node.node_id)
                    .cloned()
                    .unwrap_or_else(|| format!("cssn_{}", Uuid::new_v4().simple())),
                craftship_session_id: craftship_session_id.to_string(),
                template_node_id: Some(node.node_id.clone()),
                parent_session_node_id: node
                    .parent_node_id
                    .as_ref()
                    .and_then(|parent_id| id_map.get(parent_id).cloned()),
                label: node.label.clone(),
                framework_id: node.framework_id.clone(),
                brand_id: node.brand_id.clone(),
                terminal_ref: None,
                run_id: None,
                worktree_path: None,
                branch_name: None,
                event_cursor: None,
                presence: None,
                agent_name: None,
                agent_token_id: None,
                status: "pending".to_string(),
                sort_order: node.sort_order,
                created_at: now,
                updated_at: now,
            })
            .collect::<Vec<_>>()
    }

    fn parse_craftship_nodes_input(
        &self,
        conn: &rusqlite::Connection,
        craftship_id: &str,
        raw_nodes: &Value,
        existing_nodes: Option<&[CraftshipNode]>,
    ) -> Result<Vec<CraftshipNode>, BtError> {
        let entries = raw_nodes
            .as_array()
            .ok_or_else(|| BtError::Validation("nodes must be an array".to_string()))?;
        if entries.is_empty() {
            return Err(BtError::Validation(
                "craftship requires at least one node".to_string(),
            ));
        }

        let parsed = entries
            .iter()
            .map(|entry| {
                serde_json::from_value::<CraftshipNodeInput>(entry.clone()).map_err(|error| {
                    BtError::Validation(format!("invalid craftship node: {}", error))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let existing_map = existing_nodes
            .unwrap_or(&[])
            .iter()
            .map(|node| (node.node_id.clone(), node))
            .collect::<HashMap<_, _>>();
        let now = Utc::now();
        let mut nodes = Vec::with_capacity(parsed.len());
        let mut seen_ids = HashSet::new();

        for (index, entry) in parsed.into_iter().enumerate() {
            let label = entry.label.trim().to_string();
            if label.is_empty() {
                return Err(BtError::Validation(
                    "craftship node label cannot be empty".to_string(),
                ));
            }
            let node_id = entry
                .node_id
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| format!("csn_{}", Uuid::new_v4().simple()));
            if !seen_ids.insert(node_id.clone()) {
                return Err(BtError::Validation(format!(
                    "duplicate craftship node id {}",
                    node_id
                )));
            }
            let parent_node_id = entry
                .parent_node_id
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned);
            let requested_kind =
                entry
                    .node_kind
                    .as_deref()
                    .unwrap_or(if parent_node_id.is_none() {
                        "root"
                    } else {
                        "custom"
                    });
            let node_kind = Self::validate_craftship_node_kind(requested_kind)?;
            let framework_id = entry
                .framework_id
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned);
            if let Some(framework_id) = framework_id.as_deref() {
                let framework =
                    db::get_crafting_framework(conn, framework_id)?.ok_or_else(|| {
                        BtError::NotFound(format!("framework {} not found", framework_id))
                    })?;
                if framework.archived {
                    return Err(BtError::Validation(format!(
                        "framework {} is archived",
                        framework_id
                    )));
                }
            }
            let brand_id = entry
                .brand_id
                .as_deref()
                .map(Self::normalize_brand_id)
                .filter(|value| !value.is_empty());
            if let Some(brand_id) = brand_id.as_deref() {
                let brand = db::get_brand(conn, brand_id)?
                    .ok_or_else(|| BtError::NotFound(format!("brand {} not found", brand_id)))?;
                if !brand.enabled {
                    return Err(BtError::Validation(format!(
                        "brand {} is disabled",
                        brand_id
                    )));
                }
            }
            let created_at = existing_map
                .get(&node_id)
                .map(|node| node.created_at)
                .unwrap_or(now);
            nodes.push(CraftshipNode {
                node_id,
                craftship_id: craftship_id.to_string(),
                parent_node_id,
                label,
                node_kind,
                framework_id,
                brand_id,
                sort_order: entry.sort_order.unwrap_or(index as i64),
                created_at,
                updated_at: now,
            });
        }

        let root_count = nodes
            .iter()
            .filter(|node| node.parent_node_id.is_none())
            .count();
        if root_count != 1 {
            return Err(BtError::Validation(
                "craftship must have exactly one root node".to_string(),
            ));
        }

        let node_ids = nodes
            .iter()
            .map(|node| node.node_id.clone())
            .collect::<HashSet<_>>();
        for node in &nodes {
            if node.parent_node_id.as_deref() == Some(node.node_id.as_str()) {
                return Err(BtError::Validation(
                    "craftship node cannot be its own parent".to_string(),
                ));
            }
            if let Some(parent_id) = node.parent_node_id.as_deref() {
                if !node_ids.contains(parent_id) {
                    return Err(BtError::Validation(format!(
                        "craftship node parent {} does not exist",
                        parent_id
                    )));
                }
            }
        }

        Ok(nodes)
    }

    /// Create the session doc for a craftship session on the caller's
    /// DB connection. No audit entries or graph refreshes — the caller's
    /// `crafting.craftship.session.launch` audit covers the operation.
    /// Accepts `conn` to avoid opening extra SQLite connections on the
    /// hot launch path (each `open_conn` runs WAL pragmas + migrations).
    fn ensure_craftship_session_doc(
        &self,
        conn: &rusqlite::Connection,
        craftship: &Craftship,
        session_name: &str,
        runtime_brand: &str,
    ) -> Result<String, BtError> {
        let root = self.require_vault()?;

        // Ensure topics/sessions/ directory exists (idempotent).
        let topic_slug = fs_guard::sanitize_segment("sessions")?;
        let topic_path = fs_guard::safe_join(&root, Path::new(&format!("topics/{}", topic_slug)))?;
        fs::create_dir_all(&topic_path)?;

        // Generate a unique slug using the caller's connection.
        let base = fs_guard::sanitize_segment(session_name)?;
        let doc_slug = {
            let mut idx = 1usize;
            let mut slug = base.clone();
            loop {
                let rel = format!("topics/{}/{}", topic_slug, slug);
                let path = fs_guard::safe_join(&root, Path::new(&rel))?;
                let dir_taken = path.exists();
                let row_taken = db::doc_exists_with_topic_slug(conn, &topic_slug, &slug)?;
                if !dir_taken && !row_taken {
                    break slug;
                }
                idx += 1;
                slug = format!("{}-{}", base, idx);
            }
        };

        let id = Uuid::new_v4();
        let now = Self::now();
        let dir_rel = format!("topics/{}/{}", topic_slug, doc_slug);
        let dir = fs_guard::safe_join(&root, Path::new(&dir_rel))?;
        if dir.exists() {
            return Err(BtError::Conflict(format!(
                "document folder {} already exists",
                dir_rel
            )));
        }
        fs::create_dir_all(dir.join("attachments"))?;

        let user_rel = format!("{}/user.md", dir_rel);
        let agent_rel = format!("{}/agent.md", dir_rel);
        let meta_rel = format!("{}/meta.json", dir_rel);

        let user_path = fs_guard::safe_join(&root, Path::new(&user_rel))?;
        let agent_path = fs_guard::safe_join(&root, Path::new(&agent_rel))?;
        let meta_path = fs_guard::safe_join(&root, Path::new(&meta_rel))?;

        let user_content = format!("# {}\n\n", session_name);
        let agent_content = "# Agent Notes\n\n".to_string();

        fs_guard::atomic_write(&root, &user_path, &user_content)?;
        fs_guard::atomic_write(&root, &agent_path, &agent_content)?;

        let tags = vec![
            "craftship".to_string(),
            format!("craftship:{}", craftship.craftship_id),
            format!("mode:{}", craftship.mode),
            format!("brand:{}", runtime_brand),
        ];
        let meta = DocMeta {
            id,
            title: session_name.to_string(),
            topic: topic_slug.clone(),
            created_at: now,
            updated_at: now,
            tags: tags.clone(),
            links_out: Vec::new(),
            status: Some("running".to_string()),
            pair: PairPaths {
                user_path: user_rel.clone(),
                agent_path: agent_rel.clone(),
            },
        };
        let meta_json =
            serde_json::to_string_pretty(&meta).map_err(|e| BtError::Validation(e.to_string()))?;
        fs_guard::atomic_write(&root, &meta_path, &meta_json)?;

        db::upsert_doc(
            conn,
            &DocRecord {
                id: id.to_string(),
                topic: topic_slug.clone(),
                slug: doc_slug.clone(),
                title: session_name.to_string(),
                user_path: user_rel.clone(),
                agent_path: agent_rel.clone(),
                created_at: now,
                updated_at: now,
                owner_scope: "global".to_string(),
                project_id: None,
                project_root: None,
                knowledge_kind: "system".to_string(),
            },
            &Self::sha(&user_content),
            &Self::sha(&agent_content),
        )?;
        db::upsert_doc_meta(conn, &id.to_string(), &tags, &[], Some("running"), now)?;
        db::refresh_fts(conn, &id.to_string(), &user_content, &agent_content)?;
        self.reindex_doc_embeddings(conn, &id.to_string(), &user_content, &agent_content)?;

        Ok(id.to_string())
    }

    fn build_craftship_session_payload(
        &self,
        conn: &rusqlite::Connection,
        session: CraftshipSession,
    ) -> Result<Value, BtError> {
        let context_doc_id = Self::craftship_session_context_doc_id(&session);
        let craftship = db::get_craftship(conn, &session.craftship_id)?.ok_or_else(|| {
            BtError::NotFound(format!("craftship {} not found", session.craftship_id))
        })?;
        let all_nodes = db::list_craftship_session_nodes(conn, &session.craftship_session_id)?;
        // Filter out the synthetic required-agent node (cssn_req_*) so
        // clients and node-context-pack routing only see template-derived
        // nodes. The required-agent metadata travels in `required_steps`.
        let nodes: Vec<_> = all_nodes
            .into_iter()
            .filter(|n| !n.session_node_id.starts_with("cssn_req_"))
            .collect();
        let resolved_context = self
            .context_resolve(
                Some(&session.runtime_brand),
                Some(&session.craftship_session_id),
                context_doc_id,
                Some("compact"),
            )
            .ok();
        let node_context_packs = self.build_craftship_node_context_packs(conn, &session, &nodes)?;
        let team_state = self.build_team_state_payload(conn, &session, &nodes)?;
        Ok(json!({
            "session": session,
            "craftship": craftship,
            "nodes": nodes,
            "resolved_context": resolved_context,
            "node_context_packs": node_context_packs,
            "team_state": team_state,
        }))
    }

    fn build_craftship_node_context_packs(
        &self,
        conn: &rusqlite::Connection,
        session: &CraftshipSession,
        nodes: &[CraftshipSessionNode],
    ) -> Result<Vec<Value>, BtError> {
        let context_doc_id = Self::craftship_session_context_doc_id(session);
        let (mut base_sources, _) = self.collect_context_sources(
            conn,
            Some(&session.craftship_session_id),
            context_doc_id,
        )?;
        base_sources.sort_by(|left, right| {
            left.rank
                .cmp(&right.rank)
                .then_with(|| left.source_ref.cmp(&right.source_ref))
        });

        let mut frameworks = HashMap::new();
        for framework_id in nodes
            .iter()
            .filter_map(|row| row.framework_id.clone())
            .collect::<BTreeSet<_>>()
        {
            if let Some(framework) = db::get_crafting_framework(conn, &framework_id)? {
                if !framework.archived {
                    frameworks.insert(framework_id, framework);
                }
            }
        }

        let mut ordered_nodes = nodes.to_vec();
        ordered_nodes.sort_by(|left, right| {
            left.sort_order
                .cmp(&right.sort_order)
                .then_with(|| left.label.cmp(&right.label))
                .then_with(|| left.session_node_id.cmp(&right.session_node_id))
        });

        let mut packs = Vec::new();
        for node in ordered_nodes {
            let framework = node
                .framework_id
                .as_ref()
                .and_then(|framework_id| frameworks.get(framework_id));
            let chain_of_thought = framework
                .map(|row| row.chain_of_thought.clone())
                .unwrap_or_else(|| Self::parse_chain_of_thought_config(None));
            let chain_of_knowledge = framework
                .map(|row| row.chain_of_knowledge.clone())
                .unwrap_or_else(|| Self::parse_chain_of_knowledge_config(None));
            let budget = Self::craftship_node_context_budget(&chain_of_thought);

            let mut candidates = base_sources
                .iter()
                .cloned()
                .map(|source| {
                    let knowledge_labels = Self::craftship_source_knowledge_labels(&source);
                    CraftshipNodeContextCandidate {
                        priority_group: Self::craftship_node_source_priority_group(
                            &source,
                            &node,
                            &chain_of_thought.priority_focus,
                        ),
                        mandatory: false,
                        source,
                        knowledge_labels,
                    }
                })
                .collect::<Vec<_>>();

            if let Some(sibling_source) = Self::build_craftship_sibling_status_source(nodes, &node)
            {
                candidates.push(CraftshipNodeContextCandidate {
                    priority_group: 0,
                    mandatory: true,
                    knowledge_labels: Self::craftship_source_knowledge_labels(&sibling_source),
                    source: sibling_source,
                });
            }

            let selection = Self::select_craftship_node_context_sources(
                candidates,
                &chain_of_knowledge,
                &budget,
            );
            let selected_sources = selection
                .selected
                .iter()
                .map(|row| row.candidate.source.clone())
                .collect::<Vec<_>>();

            let (mut summary, _) =
                self.build_structured_context_summary(&selected_sources, context_doc_id)?;
            let mut sibling_statuses = Vec::new();
            let mut seen_sibling_statuses = HashSet::new();
            for source in &selected_sources {
                if source.source_kind != "sibling_status" {
                    continue;
                }
                for item in Self::extract_heading_bullets(
                    &source.body,
                    &["sibling status", "sibling statuses"],
                ) {
                    Self::push_context_statement(
                        &mut sibling_statuses,
                        &mut seen_sibling_statuses,
                        item,
                        &source.source_ref,
                    );
                }
            }
            if let Some(summary_object) = summary.as_object_mut() {
                summary_object.insert(
                    "sibling_statuses".to_string(),
                    Self::statements_to_values(&sibling_statuses).into(),
                );
            }
            let citation_count =
                Self::trim_context_summary_sections(&mut summary, budget.max_items_per_section);

            let source_references = selection
                .selected
                .iter()
                .map(|selected| {
                    json!({
                        "source_kind": selected.candidate.source.source_kind,
                        "source_ref": selected.candidate.source.source_ref,
                        "source_path": selected.candidate.source.source_path,
                        "title": selected.candidate.source.title,
                        "source_hash": selected.candidate.source.hash,
                        "rank": selected.candidate.source.rank,
                        "locator": selected.candidate.source.locator_json,
                        "knowledge_labels": selected.candidate.knowledge_labels,
                        "inclusion_reason": selected.inclusion_reason,
                    })
                })
                .collect::<Vec<_>>();
            let routing = json!({
                "focus_mode": chain_of_knowledge.focus_mode,
                "allowed_knowledge": chain_of_knowledge.allowed_knowledge,
                "blocked_knowledge": chain_of_knowledge.blocked_knowledge,
                "priority_focus": chain_of_thought.priority_focus,
                "planning_depth": chain_of_thought.planning_depth,
                "inclusion_rules": [
                    "Always include sibling status summaries when siblings exist.",
                    "In focus_mode allowed_only, keep only sources matching allowed_knowledge labels.",
                    "In focus_mode blocked_only, drop sources matching blocked_knowledge labels.",
                    "Sort candidates by explicit source-kind priority, then by source rank, then by source_ref.",
                    "Stop at the fixed planning-depth source and character budgets."
                ],
                "exclusion_rules": [
                    "Exclude sources dropped by knowledge filters.",
                    "Exclude non-mandatory sources that exceed the fixed pack budget."
                ],
                "budget": {
                    "max_sources": budget.max_sources,
                    "max_chars": budget.max_chars,
                    "max_chars_per_source": budget.max_chars_per_source,
                    "max_items_per_section": budget.max_items_per_section,
                    "selected_source_count": selection.selected.len(),
                    "selected_chars": selection.selected_chars,
                    "dropped_source_count": selection.dropped.len(),
                },
                "dropped_sources": selection.dropped,
            });
            let summary_markdown = self.build_craftship_node_context_markdown(
                session,
                &node,
                framework,
                &routing,
                &summary,
                &selection.selected,
            );
            let framework_payload = framework
                .map(|row| row.enhanced_instruction.clone())
                .unwrap_or_default();
            let payload = if framework_payload.trim().is_empty() {
                summary_markdown.clone()
            } else {
                format!("{}\n\n{}", framework_payload, summary_markdown)
            };

            packs.push(json!({
                "session_node_id": node.session_node_id,
                "template_node_id": node.template_node_id,
                "label": node.label,
                "status": node.status,
                "framework_id": node.framework_id,
                "framework_name": framework.map(|row| row.name.clone()),
                "framework_payload": if framework_payload.is_empty() { Value::Null } else { Value::String(framework_payload) },
                "routing": routing,
                "summary": summary,
                "summary_markdown": summary_markdown,
                "payload": payload,
                "source_references": source_references,
                "citation_count": citation_count,
                "unresolved_citation_count": 0,
            }));
        }

        Ok(packs)
    }

    fn craftship_node_context_budget(
        chain_of_thought: &ChainOfThoughtConfig,
    ) -> CraftshipNodeContextBudget {
        match chain_of_thought.planning_depth.as_str() {
            "deep" | "comprehensive" | "extended" => CraftshipNodeContextBudget {
                max_sources: 8,
                max_chars: 3_600,
                max_chars_per_source: 700,
                max_items_per_section: 8,
            },
            "shallow" | "minimal" | "brief" => CraftshipNodeContextBudget {
                max_sources: 4,
                max_chars: 1_800,
                max_chars_per_source: 450,
                max_items_per_section: 4,
            },
            _ => CraftshipNodeContextBudget {
                max_sources: 6,
                max_chars: 2_600,
                max_chars_per_source: 550,
                max_items_per_section: 6,
            },
        }
    }

    fn normalize_knowledge_key(value: &str) -> Option<String> {
        let normalized = value
            .trim()
            .to_ascii_lowercase()
            .chars()
            .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '_' })
            .collect::<String>()
            .trim_matches('_')
            .to_string();
        if normalized.is_empty() {
            None
        } else {
            Some(normalized)
        }
    }

    fn push_knowledge_alias(labels: &mut BTreeSet<String>, value: &str) {
        let Some(normalized) = Self::normalize_knowledge_key(value) else {
            return;
        };
        labels.insert(normalized.clone());
        if normalized.ends_with('s') && normalized.len() > 1 {
            labels.insert(normalized.trim_end_matches('s').to_string());
        } else {
            labels.insert(format!("{}s", normalized));
        }
    }

    fn craftship_source_knowledge_labels(source: &ContextSourceItem) -> Vec<String> {
        let mut labels = BTreeSet::new();
        Self::push_knowledge_alias(&mut labels, &source.source_kind);
        match source.source_kind.as_str() {
            "doc_user" => {
                for alias in [
                    "doc",
                    "docs",
                    "note",
                    "notes",
                    "knowledge_notes",
                    "user",
                    "user_note",
                ] {
                    Self::push_knowledge_alias(&mut labels, alias);
                }
            }
            "doc_agent" => {
                for alias in [
                    "doc",
                    "docs",
                    "note",
                    "notes",
                    "knowledge_notes",
                    "agent",
                    "agent_note",
                    "planning",
                    "plans",
                ] {
                    Self::push_knowledge_alias(&mut labels, alias);
                }
            }
            "doc_meta" => {
                for alias in ["doc", "docs", "meta", "graph", "links"] {
                    Self::push_knowledge_alias(&mut labels, alias);
                }
            }
            "task" => {
                for alias in ["task", "tasks", "planning"] {
                    Self::push_knowledge_alias(&mut labels, alias);
                }
            }
            "run" => {
                for alias in ["run", "runs", "execution", "checks"] {
                    Self::push_knowledge_alias(&mut labels, alias);
                }
            }
            "run_artifact" => {
                for alias in [
                    "run",
                    "runs",
                    "artifact",
                    "artifacts",
                    "execution",
                    "checks",
                ] {
                    Self::push_knowledge_alias(&mut labels, alias);
                }
                if let Some(kind) = source.locator_json.get("kind").and_then(Value::as_str) {
                    Self::push_knowledge_alias(&mut labels, kind);
                    if kind == "stderr" {
                        for alias in ["failures", "logs", "verification"] {
                            Self::push_knowledge_alias(&mut labels, alias);
                        }
                    }
                }
            }
            "graph_context" => {
                for alias in ["graph", "docs", "files", "references"] {
                    Self::push_knowledge_alias(&mut labels, alias);
                }
            }
            "previous_pack" => {
                for alias in ["context_pack", "summary", "history"] {
                    Self::push_knowledge_alias(&mut labels, alias);
                }
            }
            "sibling_status" => {
                for alias in ["sibling", "siblings", "status", "craftship_status"] {
                    Self::push_knowledge_alias(&mut labels, alias);
                }
            }
            _ => {}
        }

        for key in ["topic", "slug", "status", "kind"] {
            if let Some(value) = source.locator_json.get(key).and_then(Value::as_str) {
                Self::push_knowledge_alias(&mut labels, value);
            }
        }
        for key in ["tags", "links_out"] {
            if let Some(values) = source.locator_json.get(key).and_then(Value::as_array) {
                for value in values.iter().filter_map(Value::as_str) {
                    Self::push_knowledge_alias(&mut labels, value);
                }
            }
        }
        if let Some(path) = &source.source_path {
            for token in path.split(|ch: char| !ch.is_ascii_alphanumeric()) {
                if !token.is_empty() {
                    Self::push_knowledge_alias(&mut labels, token);
                }
            }
        }

        labels.into_iter().collect()
    }

    fn craftship_node_source_priority_group(
        source: &ContextSourceItem,
        node: &CraftshipSessionNode,
        priority_focus: &str,
    ) -> usize {
        let verification_first = {
            let lowered = priority_focus.to_ascii_lowercase();
            lowered.contains("verify")
                || lowered.contains("test")
                || lowered.contains("qa")
                || lowered.contains("quality")
        };
        let current_node_match = source
            .locator_json
            .get("craftship_session_node_id")
            .and_then(Value::as_str)
            == Some(node.session_node_id.as_str());

        match source.source_kind.as_str() {
            "sibling_status" => 0,
            "task" => {
                if verification_first {
                    4
                } else {
                    1
                }
            }
            "run_artifact" if current_node_match => 2,
            "run" if current_node_match => 3,
            "doc_agent" => 4,
            "doc_user" => 5,
            "run_artifact" => {
                if verification_first {
                    1
                } else {
                    6
                }
            }
            "run" => {
                if verification_first {
                    2
                } else {
                    7
                }
            }
            "graph_context" => 8,
            "doc_meta" => 9,
            "previous_pack" => 10,
            _ => 11,
        }
    }

    fn select_craftship_node_context_sources(
        mut candidates: Vec<CraftshipNodeContextCandidate>,
        chain_of_knowledge: &ChainOfKnowledgeConfig,
        budget: &CraftshipNodeContextBudget,
    ) -> CraftshipNodeContextSelection {
        candidates.sort_by(|left, right| {
            left.priority_group
                .cmp(&right.priority_group)
                .then_with(|| left.source.rank.cmp(&right.source.rank))
                .then_with(|| left.source.source_ref.cmp(&right.source.source_ref))
        });

        let allowed = chain_of_knowledge
            .allowed_knowledge
            .iter()
            .filter_map(|row| Self::normalize_knowledge_key(row))
            .collect::<BTreeSet<_>>();
        let blocked = chain_of_knowledge
            .blocked_knowledge
            .iter()
            .filter_map(|row| Self::normalize_knowledge_key(row))
            .collect::<BTreeSet<_>>();

        let mut selected = Vec::new();
        let mut dropped = Vec::new();
        let mut selected_chars = 0usize;

        for candidate in candidates {
            let label_set = candidate
                .knowledge_labels
                .iter()
                .cloned()
                .collect::<BTreeSet<_>>();
            let matched_allowed = label_set
                .intersection(&allowed)
                .cloned()
                .collect::<Vec<_>>();
            let matched_blocked = label_set
                .intersection(&blocked)
                .cloned()
                .collect::<Vec<_>>();

            if !candidate.mandatory && chain_of_knowledge.focus_mode == "allowed_only" {
                if matched_allowed.is_empty() {
                    dropped.push(json!({
                        "source_ref": candidate.source.source_ref,
                        "source_kind": candidate.source.source_kind,
                        "reason": "focus_mode=allowed_only:no_allowed_match",
                    }));
                    continue;
                }
            }
            if !candidate.mandatory && chain_of_knowledge.focus_mode == "blocked_only" {
                if !matched_blocked.is_empty() {
                    dropped.push(json!({
                        "source_ref": candidate.source.source_ref,
                        "source_kind": candidate.source.source_kind,
                        "reason": format!("blocked_knowledge:{}", matched_blocked.join(",")),
                    }));
                    continue;
                }
            }

            let source_cost = candidate
                .source
                .body
                .chars()
                .count()
                .min(budget.max_chars_per_source);
            if !candidate.mandatory {
                if selected.len() >= budget.max_sources {
                    dropped.push(json!({
                        "source_ref": candidate.source.source_ref,
                        "source_kind": candidate.source.source_kind,
                        "reason": "budget:max_sources",
                    }));
                    continue;
                }
                if selected_chars + source_cost > budget.max_chars {
                    dropped.push(json!({
                        "source_ref": candidate.source.source_ref,
                        "source_kind": candidate.source.source_kind,
                        "reason": "budget:max_chars",
                    }));
                    continue;
                }
            }

            selected_chars += source_cost;
            let inclusion_reason = if candidate.mandatory {
                format!("mandatory:{}", candidate.source.source_kind)
            } else if chain_of_knowledge.focus_mode == "allowed_only" {
                format!("allowed_knowledge:{}", matched_allowed.join(","))
            } else if chain_of_knowledge.focus_mode == "blocked_only" {
                "allowed_by_block_filter".to_string()
            } else {
                "priority_order".to_string()
            };
            selected.push(CraftshipNodeSelectedSource {
                candidate,
                inclusion_reason,
            });
        }

        CraftshipNodeContextSelection {
            selected,
            dropped,
            selected_chars,
        }
    }

    fn build_craftship_sibling_status_source(
        nodes: &[CraftshipSessionNode],
        node: &CraftshipSessionNode,
    ) -> Option<ContextSourceItem> {
        let mut siblings = nodes
            .iter()
            .filter(|row| {
                row.session_node_id != node.session_node_id
                    && row.parent_session_node_id == node.parent_session_node_id
            })
            .cloned()
            .collect::<Vec<_>>();
        siblings.sort_by(|left, right| {
            left.sort_order
                .cmp(&right.sort_order)
                .then_with(|| left.label.cmp(&right.label))
                .then_with(|| left.session_node_id.cmp(&right.session_node_id))
        });
        if siblings.is_empty() {
            return None;
        }

        let body = format!(
            "# Sibling Statuses\n\n{}",
            siblings
                .iter()
                .map(|sibling| {
                    let mut text = format!("{}: {}", sibling.label, sibling.status);
                    if let Some(run_id) = &sibling.run_id {
                        text.push_str(&format!(" (run {})", run_id));
                    }
                    text
                })
                .map(|row| format!("- {}", row))
                .collect::<Vec<_>>()
                .join("\n")
        );
        Some(ContextSourceItem {
            source_kind: "sibling_status".to_string(),
            source_ref: format!("craftship_session_node:{}:siblings", node.session_node_id),
            source_path: None,
            title: format!("Sibling status for {}", node.label),
            hash: Self::sha(&body),
            body,
            rank: 0,
            locator_json: json!({
                "craftship_session_id": node.craftship_session_id,
                "craftship_session_node_id": node.session_node_id,
                "siblings": siblings.iter().map(|sibling| {
                    json!({
                        "session_node_id": sibling.session_node_id,
                        "label": sibling.label,
                        "status": sibling.status,
                        "run_id": sibling.run_id,
                    })
                }).collect::<Vec<_>>(),
            }),
        })
    }

    fn trim_context_summary_sections(summary: &mut Value, max_items: usize) -> usize {
        let mut citation_count = 0usize;
        if let Some(summary_object) = summary.as_object_mut() {
            for value in summary_object.values_mut() {
                if let Some(rows) = value.as_array_mut() {
                    if rows.len() > max_items {
                        rows.truncate(max_items);
                    }
                    citation_count += rows
                        .iter()
                        .filter_map(|row| row.get("citations").and_then(Value::as_array))
                        .map(|citations| citations.len())
                        .sum::<usize>();
                }
            }
        }
        citation_count
    }

    fn build_craftship_node_context_markdown(
        &self,
        session: &CraftshipSession,
        node: &CraftshipSessionNode,
        framework: Option<&CraftingFramework>,
        routing: &Value,
        summary: &Value,
        selected_sources: &[CraftshipNodeSelectedSource],
    ) -> String {
        let mut out = Vec::new();
        out.push("# Craftship Node Context".to_string());
        out.push(String::new());
        out.push(format!("- Session: `{}`", session.craftship_session_id));
        out.push(format!("- Node: `{}`", node.label));
        out.push(format!("- Status: `{}`", node.status));
        if let Some(framework) = framework {
            out.push(format!("- Framework: `{}`", framework.name));
        }
        out.push(format!(
            "- Focus mode: `{}`",
            routing
                .get("focus_mode")
                .and_then(Value::as_str)
                .unwrap_or("unrestricted")
        ));
        let allowed = routing
            .get("allowed_knowledge")
            .and_then(Value::as_array)
            .map(|rows| {
                rows.iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .filter(|row| !row.is_empty())
            .unwrap_or_else(|| "none".to_string());
        let blocked = routing
            .get("blocked_knowledge")
            .and_then(Value::as_array)
            .map(|rows| {
                rows.iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .filter(|row| !row.is_empty())
            .unwrap_or_else(|| "none".to_string());
        out.push(format!("- Allowed knowledge: {}", allowed));
        out.push(format!("- Blocked knowledge: {}", blocked));

        for (title, key) in [
            ("Goals", "goals"),
            ("Decisions", "decisions"),
            ("Constraints", "constraints"),
            ("Sibling Statuses", "sibling_statuses"),
            ("Open Questions", "open_questions"),
            ("Touched Files And Docs", "touched_files_docs"),
            ("Commands And Checks", "commands_checks_run"),
            ("Failures", "failures"),
            ("Next Actions", "next_actions"),
        ] {
            out.push(String::new());
            out.push(format!("## {}", title));
            out.push(String::new());
            let rows = summary
                .get(key)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if rows.is_empty() {
                out.push("- None captured.".to_string());
                continue;
            }
            for row in rows {
                let text = row.get("text").and_then(Value::as_str).unwrap_or("");
                let citations = row
                    .get("citations")
                    .and_then(Value::as_array)
                    .map(|citations| {
                        citations
                            .iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join(", ")
                    })
                    .unwrap_or_default();
                out.push(format!("- {} [{}]", text, citations));
            }
        }

        out.push(String::new());
        out.push("## Sources".to_string());
        out.push(String::new());
        for source in selected_sources {
            let path_or_title = source
                .candidate
                .source
                .source_path
                .clone()
                .unwrap_or_else(|| source.candidate.source.title.clone());
            out.push(format!(
                "- `{}`: {} ({})",
                source.candidate.source.source_ref, path_or_title, source.inclusion_reason
            ));
        }

        out.join("\n")
    }

    fn validate_executor_kind(&self, executor_kind: &str) -> Result<(), BtError> {
        if matches!(executor_kind, "openclaw_local" | "command_local") {
            return Ok(());
        }
        let conn = self.open_conn()?;
        if db::has_adapter_kind(&conn, executor_kind)? {
            Ok(())
        } else {
            Err(BtError::Validation(format!(
                "unsupported executor_kind: {}",
                executor_kind
            )))
        }
    }

    fn build_automation_record(
        &self,
        input: &Value,
        existing: Option<&AutomationRecord>,
    ) -> Result<AutomationRecord, BtError> {
        let now = Utc::now();
        let executor_kind = optional_str(input, "executor_kind")
            .map(ToOwned::to_owned)
            .or_else(|| existing.map(|row| row.executor_kind.clone()))
            .ok_or_else(|| BtError::Validation("executor_kind is required".to_string()))?;
        self.validate_executor_kind(&executor_kind)?;

        let title = optional_str(input, "title")
            .map(ToOwned::to_owned)
            .or_else(|| existing.map(|row| row.title.clone()))
            .ok_or_else(|| BtError::Validation("title is required".to_string()))?;
        let prompt_template = optional_str(input, "prompt_template")
            .map(ToOwned::to_owned)
            .or_else(|| existing.map(|row| row.prompt_template.clone()))
            .ok_or_else(|| BtError::Validation("prompt_template is required".to_string()))?;
        let schedule_kind = optional_str(input, "schedule_kind")
            .map(ToOwned::to_owned)
            .or_else(|| existing.map(|row| row.schedule_kind.clone()))
            .ok_or_else(|| BtError::Validation("schedule_kind is required".to_string()))?;
        let schedule_json = input
            .get("schedule_json")
            .cloned()
            .or_else(|| existing.map(|row| row.schedule_json.clone()))
            .ok_or_else(|| BtError::Validation("schedule_json is required".to_string()))?;
        let executor_config_json = input
            .get("executor_config_json")
            .cloned()
            .or_else(|| existing.map(|row| row.executor_config_json.clone()))
            .unwrap_or_else(|| json!({}));
        let retry_policy_json = input
            .get("retry_policy_json")
            .cloned()
            .or_else(|| existing.map(|row| row.retry_policy_json.clone()))
            .unwrap_or_else(|| json!({ "max_attempts": 1, "backoff_seconds": 300 }));
        let concurrency_policy = optional_str(input, "concurrency_policy")
            .map(ToOwned::to_owned)
            .or_else(|| existing.map(|row| row.concurrency_policy.clone()))
            .unwrap_or_else(|| "serial".to_string());
        if !matches!(
            concurrency_policy.as_str(),
            "serial" | "allow_overlap" | "replace_stale"
        ) {
            return Err(BtError::Validation(format!(
                "unsupported concurrency_policy: {}",
                concurrency_policy
            )));
        }

        let timezone = optional_str(input, "timezone")
            .map(ToOwned::to_owned)
            .or_else(|| existing.map(|row| row.timezone.clone()))
            .unwrap_or_else(|| "UTC".to_string());
        let _ = crate::automation::parse_timezone(&timezone)?;

        let enabled = optional_bool(input, "enabled")
            .or_else(|| existing.map(|row| row.enabled))
            .unwrap_or(true);
        let company_id = optional_string_value(input, "company_id")
            .or_else(|| existing.and_then(|row| row.company_id.clone()))
            .or(Some(DEFAULT_COMPANY_ID.to_string()));
        let goal_id = optional_string_value(input, "goal_id")
            .or_else(|| existing.and_then(|row| row.goal_id.clone()));
        let brand_id = optional_string_value(input, "brand_id")
            .or_else(|| existing.and_then(|row| row.brand_id.clone()))
            .or_else(|| {
                if executor_kind == "openclaw_local" {
                    Some("openclaw".to_string())
                } else if executor_kind == "command_local" {
                    Some("bash".to_string())
                } else {
                    Some("other".to_string())
                }
            });
        let adapter_kind = optional_string_value(input, "adapter_kind")
            .or_else(|| existing.and_then(|row| row.adapter_kind.clone()))
            .or(Some(executor_kind.clone()));
        let shared_context_key = optional_string_value(input, "shared_context_key")
            .or_else(|| existing.and_then(|row| row.shared_context_key.clone()));
        let doc_id = optional_string_value(input, "doc_id")
            .or_else(|| existing.and_then(|row| row.doc_id.clone()));
        let task_id = optional_string_value(input, "task_id")
            .or_else(|| existing.and_then(|row| row.task_id.clone()));

        let automation = AutomationRecord {
            id: existing
                .map(|row| row.id.clone())
                .unwrap_or_else(|| format!("aut_{}", Uuid::new_v4().simple())),
            executor_kind,
            executor_config_json,
            title,
            prompt_template,
            doc_id,
            task_id,
            shared_context_key,
            schedule_kind,
            schedule_json,
            retry_policy_json,
            concurrency_policy,
            timezone,
            enabled,
            company_id,
            goal_id,
            brand_id,
            adapter_kind,
            created_at: existing.map(|row| row.created_at).unwrap_or(now),
            updated_at: now,
            paused_at: if enabled {
                None
            } else {
                existing.and_then(|row| row.paused_at).or(Some(now))
            },
            last_planned_at: existing.and_then(|row| row.last_planned_at),
        };
        let _ = parse_schedule(&automation)?;
        let _ = parse_retry_policy(&automation.retry_policy_json)?;
        Ok(automation)
    }

    fn build_occurrence(
        &self,
        automation: &AutomationRecord,
        planned_at: DateTime<Utc>,
        trigger_reason: &str,
        attempt: i64,
        status: &str,
    ) -> AutomationOccurrence {
        let now = Utc::now();
        let dedupe_key = format!(
            "{}:{}:{}:{}",
            automation.id,
            trigger_reason,
            attempt,
            planned_at.to_rfc3339()
        );
        AutomationOccurrence {
            id: format!("occ_{}", Uuid::new_v4().simple()),
            automation_id: automation.id.clone(),
            attempt,
            trigger_reason: trigger_reason.to_string(),
            planned_at,
            ready_at: if matches!(status, "ready" | "retry_ready") {
                Some(now)
            } else {
                None
            },
            leased_at: None,
            started_at: None,
            finished_at: None,
            status: status.to_string(),
            dedupe_key,
            lease_owner: None,
            lease_expires_at: None,
            last_heartbeat_at: None,
            run_id: None,
            failure_kind: None,
            failure_message: None,
            retry_count: 0,
            created_at: now,
            updated_at: now,
        }
    }

    fn evaluate_run_for_occurrence(
        &self,
        conn: &rusqlite::Connection,
        run_id: &str,
        occurrence: &AutomationOccurrence,
        succeeded: bool,
        finished_at: DateTime<Utc>,
    ) -> Result<RunEvaluation, BtError> {
        let intervention_count = db::count_interventions_for_run(conn, run_id)?;
        let lateness_seconds = (finished_at - occurrence.planned_at).num_seconds().max(0);
        let (completion_class, quality_score) =
            completion_class(succeeded, intervention_count, lateness_seconds);
        let evaluation = RunEvaluation {
            run_id: run_id.to_string(),
            quality_score,
            completion_class: completion_class.to_string(),
            intervention_count,
            retry_count: occurrence.retry_count,
            lateness_seconds,
            evaluated_at: finished_at,
        };
        db::upsert_run_evaluation(conn, &evaluation)?;
        Ok(evaluation)
    }

    pub fn automation_create(&self, actor: &Actor, input: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "automation.create")?;
        self.apply_write(actor, WriteOperation::ManageAutomation)?;
        let automation = self.build_automation_record(&input, None)?;
        let conn = self.open_conn()?;
        if let Some(doc_id) = &automation.doc_id {
            let _ = db::get_doc(&conn, doc_id)?
                .ok_or_else(|| BtError::NotFound(format!("doc {} not found", doc_id)))?;
        }
        db::insert_automation(&conn, &automation)?;
        self.audit(
            actor,
            "automation.create",
            &input,
            automation.doc_id.as_deref(),
            None,
            "ok",
            json!({ "automation_id": automation.id }),
        )?;
        Ok(json!({ "automation": automation }))
    }

    pub fn automation_update(
        &self,
        actor: &Actor,
        automation_id: &str,
        input: Value,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "automation.update")?;
        self.apply_write(actor, WriteOperation::ManageAutomation)?;
        let conn = self.open_conn()?;
        let existing = db::get_automation(&conn, automation_id)?
            .ok_or_else(|| BtError::NotFound(format!("automation {} not found", automation_id)))?;
        let automation = self.build_automation_record(&input, Some(&existing))?;
        if let Some(doc_id) = &automation.doc_id {
            let _ = db::get_doc(&conn, doc_id)?
                .ok_or_else(|| BtError::NotFound(format!("doc {} not found", doc_id)))?;
        }
        db::update_automation(&conn, &automation)?;
        self.audit(
            actor,
            "automation.update",
            &json!({ "automation_id": automation_id, "patch": input }),
            automation.doc_id.as_deref(),
            None,
            "ok",
            json!({ "automation_id": automation_id }),
        )?;
        Ok(json!({ "automation": automation }))
    }

    pub fn automation_get(&self, automation_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let automation = db::get_automation(&conn, automation_id)?
            .ok_or_else(|| BtError::NotFound(format!("automation {} not found", automation_id)))?;
        Ok(json!({ "automation": automation }))
    }

    pub fn automation_list(
        &self,
        enabled: Option<bool>,
        executor_kind: Option<&str>,
        limit: usize,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let automations = db::list_automations(&conn, enabled, executor_kind, limit)?;
        Ok(json!({ "automations": automations }))
    }

    pub fn automation_pause(&self, actor: &Actor, automation_id: &str) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "automation.pause")?;
        self.apply_write(actor, WriteOperation::ManageAutomation)?;
        let now = Utc::now();
        let conn = self.open_conn()?;
        db::set_automation_enabled(&conn, automation_id, false, now)?;
        let automation = db::get_automation(&conn, automation_id)?
            .ok_or_else(|| BtError::NotFound(format!("automation {} not found", automation_id)))?;
        self.audit(
            actor,
            "automation.pause",
            &json!({ "automation_id": automation_id }),
            automation.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "automation": automation }))
    }

    pub fn automation_resume(&self, actor: &Actor, automation_id: &str) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "automation.resume")?;
        self.apply_write(actor, WriteOperation::ManageAutomation)?;
        let now = Utc::now();
        let conn = self.open_conn()?;
        db::set_automation_enabled(&conn, automation_id, true, now)?;
        let automation = db::get_automation(&conn, automation_id)?
            .ok_or_else(|| BtError::NotFound(format!("automation {} not found", automation_id)))?;
        self.audit(
            actor,
            "automation.resume",
            &json!({ "automation_id": automation_id }),
            automation.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "automation": automation }))
    }

    pub fn automation_delete(&self, actor: &Actor, automation_id: &str) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "automation.delete")?;
        self.apply_write(actor, WriteOperation::ManageAutomation)?;
        let conn = self.open_conn()?;
        if db::has_active_occurrence(&conn, automation_id)? {
            return Err(BtError::Conflict(
                "cannot delete automation with active occurrences".to_string(),
            ));
        }
        db::delete_automation(&conn, automation_id)?;
        self.audit(
            actor,
            "automation.delete",
            &json!({ "automation_id": automation_id }),
            None,
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "automation_id": automation_id, "deleted": true }))
    }

    pub fn automation_occurrence_list(
        &self,
        automation_id: Option<&str>,
        status: Option<&str>,
        from: Option<&str>,
        to: Option<&str>,
        limit: usize,
    ) -> Result<Value, BtError> {
        let from = parse_optional_rfc3339(from, "from")?;
        let to = parse_optional_rfc3339(to, "to")?;
        let conn = self.open_conn()?;
        let occurrences = db::list_occurrences(&conn, automation_id, status, from, to, limit)?;
        Ok(json!({ "occurrences": occurrences }))
    }

    pub fn automation_occurrence_get(&self, occurrence_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let occurrence = db::get_occurrence(&conn, occurrence_id)?
            .ok_or_else(|| BtError::NotFound(format!("occurrence {} not found", occurrence_id)))?;
        Ok(json!({ "occurrence": occurrence }))
    }

    pub fn automation_enqueue_now(
        &self,
        actor: &Actor,
        automation_id: &str,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "automation.enqueue_now")?;
        self.apply_write(actor, WriteOperation::ManageAutomation)?;
        let conn = self.open_conn()?;
        let automation = db::get_automation(&conn, automation_id)?
            .ok_or_else(|| BtError::NotFound(format!("automation {} not found", automation_id)))?;
        if automation.concurrency_policy == "serial"
            && db::has_active_occurrence(&conn, automation_id)?
        {
            return Err(BtError::Conflict(
                "serial automation already has an active occurrence".to_string(),
            ));
        }
        let now = Utc::now();
        let occurrence = self.build_occurrence(&automation, now, "manual_enqueue", 1, "ready");
        db::insert_occurrence_if_absent(&conn, &occurrence)?;
        self.emit_event(
            actor,
            "automation.occurrence.ready",
            automation.doc_id.as_deref(),
            None,
            json!({
                "automation_id": automation.id,
                "occurrence_id": occurrence.id,
                "trigger_reason": occurrence.trigger_reason,
                "planned_at": occurrence.planned_at,
            }),
            Some(&occurrence.dedupe_key),
        )?;
        self.audit(
            actor,
            "automation.enqueue_now",
            &json!({ "automation_id": automation_id }),
            automation.doc_id.as_deref(),
            None,
            "ok",
            json!({ "occurrence_id": occurrence.id }),
        )?;
        Ok(json!({ "occurrence": occurrence }))
    }

    pub fn automation_retry_occurrence(
        &self,
        actor: &Actor,
        occurrence_id: &str,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "automation.retry_occurrence")?;
        self.apply_write(actor, WriteOperation::ManageAutomation)?;
        let conn = self.open_conn()?;
        let occurrence = db::get_occurrence(&conn, occurrence_id)?
            .ok_or_else(|| BtError::NotFound(format!("occurrence {} not found", occurrence_id)))?;
        let automation =
            db::get_automation(&conn, &occurrence.automation_id)?.ok_or_else(|| {
                BtError::NotFound(format!("automation {} not found", occurrence.automation_id))
            })?;
        let retry_policy = parse_retry_policy(&automation.retry_policy_json)?;
        if occurrence.attempt >= retry_policy.max_attempts {
            return Err(BtError::Conflict(
                "retry limit exhausted for this occurrence".to_string(),
            ));
        }
        let retry = self.build_occurrence(
            &automation,
            Utc::now(),
            "manual_retry",
            occurrence.attempt + 1,
            "retry_ready",
        );
        db::insert_occurrence_if_absent(&conn, &retry)?;
        self.emit_event(
            actor,
            "automation.occurrence.ready",
            automation.doc_id.as_deref(),
            retry.run_id.as_deref(),
            json!({
                "automation_id": automation.id,
                "occurrence_id": retry.id,
                "retry_of": occurrence.id,
                "planned_at": retry.planned_at,
            }),
            Some(&retry.dedupe_key),
        )?;
        self.audit(
            actor,
            "automation.retry_occurrence",
            &json!({ "occurrence_id": occurrence_id }),
            automation.doc_id.as_deref(),
            occurrence.run_id.as_deref(),
            "ok",
            json!({ "new_occurrence_id": retry.id }),
        )?;
        Ok(json!({ "occurrence": retry }))
    }

    pub fn automation_claim_occurrence(
        &self,
        actor: &Actor,
        occurrence_id: &str,
        lease_owner: &str,
        lease_seconds: i64,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManageWorker)?;
        let now = Utc::now();
        let lease_expires_at = now + Duration::seconds(lease_seconds.max(30));
        let conn = self.open_conn()?;
        let claimed =
            db::claim_occurrence(&conn, occurrence_id, lease_owner, now, lease_expires_at)?;
        let occurrence = db::get_occurrence(&conn, occurrence_id)?;
        Ok(json!({
            "claimed": claimed,
            "lease_owner": lease_owner,
            "lease_expires_at": lease_expires_at,
            "occurrence": occurrence,
        }))
    }

    pub fn automation_heartbeat_occurrence(
        &self,
        actor: &Actor,
        occurrence_id: &str,
        lease_owner: &str,
        lease_seconds: i64,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManageWorker)?;
        let now = Utc::now();
        let lease_expires_at = now + Duration::seconds(lease_seconds.max(30));
        let conn = self.open_conn()?;
        let updated =
            db::heartbeat_occurrence(&conn, occurrence_id, lease_owner, now, lease_expires_at)?;
        Ok(json!({
            "updated": updated,
            "lease_expires_at": lease_expires_at,
        }))
    }

    pub fn automation_start_occurrence(
        &self,
        actor: &Actor,
        occurrence_id: &str,
        lease_owner: &str,
        run_id: Option<&str>,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManageWorker)?;
        let now = Utc::now();
        let conn = self.open_conn()?;
        let started = db::start_occurrence(&conn, occurrence_id, lease_owner, now, run_id)?;
        let occurrence = db::get_occurrence(&conn, occurrence_id)?;
        Ok(json!({ "started": started, "occurrence": occurrence }))
    }

    pub fn automation_complete_occurrence(
        &self,
        actor: &Actor,
        occurrence_id: &str,
        lease_owner: &str,
        status: &str,
        run_id: Option<&str>,
        failure_kind: Option<&str>,
        failure_message: Option<&str>,
        shared_context: Option<Value>,
        artifact_path: Option<&str>,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManageWorker)?;
        let finished_at = Utc::now();
        let conn = self.open_conn()?;
        let occurrence = db::get_occurrence(&conn, occurrence_id)?
            .ok_or_else(|| BtError::NotFound(format!("occurrence {} not found", occurrence_id)))?;
        let automation =
            db::get_automation(&conn, &occurrence.automation_id)?.ok_or_else(|| {
                BtError::NotFound(format!("automation {} not found", occurrence.automation_id))
            })?;
        let retry_policy = parse_retry_policy(&automation.retry_policy_json)?;

        let completed = db::finish_occurrence(
            &conn,
            occurrence_id,
            Some(lease_owner),
            status,
            finished_at,
            run_id,
            failure_kind,
            failure_message,
            occurrence.retry_count,
        )?;
        if !completed {
            return Err(BtError::Conflict(format!(
                "occurrence {} is not owned by {}",
                occurrence_id, lease_owner
            )));
        }

        let updated_occurrence = db::get_occurrence(&conn, occurrence_id)?
            .ok_or_else(|| BtError::NotFound(format!("occurrence {} not found", occurrence_id)))?;
        let evaluation = if let Some(run_id) = run_id {
            Some(self.evaluate_run_for_occurrence(
                &conn,
                run_id,
                &updated_occurrence,
                status == "succeeded",
                finished_at,
            )?)
        } else {
            None
        };

        if let Some(shared_context) = shared_context {
            if let Some(context_key) = &automation.shared_context_key {
                db::upsert_shared_context(
                    &conn,
                    &SharedContextRecord {
                        context_key: context_key.clone(),
                        automation_id: Some(automation.id.clone()),
                        latest_run_id: run_id.map(ToOwned::to_owned),
                        latest_occurrence_id: Some(updated_occurrence.id.clone()),
                        state_json: shared_context,
                        artifact_path: artifact_path.map(ToOwned::to_owned),
                        updated_at: finished_at,
                    },
                )?;
            }
        }

        let retry_occurrence =
            if status == "failed" && updated_occurrence.attempt < retry_policy.max_attempts {
                let retry_at = next_retry_at(&updated_occurrence, &retry_policy);
                let retry_status = if retry_at <= Utc::now() {
                    "retry_ready"
                } else {
                    "scheduled"
                };
                let retry = self.build_occurrence(
                    &automation,
                    retry_at,
                    "automatic_retry",
                    updated_occurrence.attempt + 1,
                    retry_status,
                );
                db::insert_occurrence_if_absent(&conn, &retry)?;
                if retry_status == "retry_ready" {
                    self.emit_event(
                        &Actor::System {
                            component: "scheduler".to_string(),
                        },
                        "automation.occurrence.ready",
                        automation.doc_id.as_deref(),
                        run_id,
                        json!({
                            "automation_id": automation.id,
                            "occurrence_id": retry.id,
                            "retry_of": updated_occurrence.id,
                            "planned_at": retry.planned_at,
                        }),
                        Some(&retry.dedupe_key),
                    )?;
                }
                Some(retry)
            } else {
                None
            };

        self.emit_event(
            actor,
            "automation.occurrence.completed",
            automation.doc_id.as_deref(),
            run_id,
            json!({
                "automation_id": automation.id,
                "occurrence_id": updated_occurrence.id,
                "status": status,
                "retry_scheduled": retry_occurrence.as_ref().map(|r| r.id.clone()),
            }),
            None,
        )?;

        Ok(json!({
            "occurrence": updated_occurrence,
            "evaluation": evaluation,
            "retry_occurrence": retry_occurrence,
        }))
    }

    pub fn worker_cursor_touch(
        &self,
        actor: &Actor,
        worker_id: &str,
        consumer_group: &str,
        executor_kind: &str,
        last_event_id: i64,
        status: &str,
        lease_count: i64,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManageWorker)?;
        let now = Utc::now();
        let cursor = WorkerCursor {
            worker_id: worker_id.to_string(),
            consumer_group: consumer_group.to_string(),
            executor_kind: executor_kind.to_string(),
            last_event_id,
            last_heartbeat_at: now,
            status: status.to_string(),
            lease_count,
            updated_at: now,
        };
        let conn = self.open_conn()?;
        db::upsert_worker_cursor(&conn, &cursor)?;
        Ok(json!({ "worker": cursor }))
    }

    pub fn worker_cursor_get(&self, worker_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let worker = db::get_worker_cursor(&conn, worker_id)?;
        Ok(json!({ "worker": worker }))
    }

    pub fn system_automation_status(&self) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let workers = db::list_worker_cursors(&conn)?;
        let ready_count = db::count_occurrences_by_status(&conn, &["ready", "retry_ready"])?;
        let scheduled_count = db::count_occurrences_by_status(&conn, &["scheduled"])?;
        let active_count = db::count_occurrences_by_status(&conn, &["leased", "running"])?;
        let stale_leases = db::list_occurrences(&conn, None, None, None, None, 5000)?
            .into_iter()
            .filter(|occ| {
                matches!(occ.status.as_str(), "leased" | "running")
                    && occ
                        .lease_expires_at
                        .map(|lease| lease <= Utc::now())
                        .unwrap_or(false)
            })
            .count();

        Ok(json!({
            "ok": true,
            "queue_depth": {
                "ready": ready_count,
                "scheduled": scheduled_count,
                "active": active_count,
            },
            "stale_leases": stale_leases,
            "workers": workers,
        }))
    }

    pub fn calendar_range(
        &self,
        from: &str,
        to: &str,
        timezone: &str,
        agent: Option<&str>,
        status: Option<&str>,
    ) -> Result<Value, BtError> {
        let from = parse_required_rfc3339(from, "from")?;
        let to = parse_required_rfc3339(to, "to")?;
        let tz = crate::automation::parse_timezone(timezone)?;
        let conn = self.open_conn()?;
        let occurrences = db::list_occurrences(&conn, None, status, Some(from), Some(to), 2000)?;
        let mut entries = Vec::new();
        let mut succeeded = 0usize;
        let mut failed = 0usize;
        let mut active = 0usize;
        let mut terminal_canvas_entries = 0usize;
        let mut framework_accuracy_total = 0.0f64;
        let mut framework_accuracy_count = 0usize;

        for occurrence in occurrences {
            let automation =
                db::get_automation(&conn, &occurrence.automation_id)?.ok_or_else(|| {
                    BtError::NotFound(format!("automation {} not found", occurrence.automation_id))
                })?;
            let run = if let Some(run_id) = &occurrence.run_id {
                db::get_run(&conn, run_id)?
            } else {
                None
            };
            if let Some(agent_filter) = agent {
                let run_matches = run
                    .as_ref()
                    .and_then(|row| {
                        row.agent_name
                            .as_deref()
                            .or(row.openclaw_agent_name.as_deref())
                    })
                    .map(|value| value == agent_filter)
                    .unwrap_or(false);
                let executor_matches = automation
                    .executor_config_json
                    .get("agent_name")
                    .and_then(Value::as_str)
                    .map(|value| value == agent_filter)
                    .unwrap_or(false);
                if !run_matches && !executor_matches {
                    continue;
                }
            }
            let evaluation = if let Some(run_id) = &occurrence.run_id {
                db::get_run_evaluation(&conn, run_id)?
            } else {
                None
            };
            let shared_context = if let Some(key) = &automation.shared_context_key {
                db::get_shared_context(&conn, key)?
            } else {
                None
            };

            match occurrence.status.as_str() {
                "succeeded" => succeeded += 1,
                "failed" => failed += 1,
                "ready" | "retry_ready" | "leased" | "running" => active += 1,
                _ => {}
            }

            let display_status =
                if matches!(automation.schedule_kind.as_str(), "heartbeat" | "watchdog")
                    && occurrence.status != "succeeded"
                {
                    "heartbeat_missed".to_string()
                } else {
                    occurrence.status.clone()
                };

            let quality_badge = evaluation
                .as_ref()
                .map(|row| row.completion_class.clone())
                .unwrap_or_else(|| match display_status.as_str() {
                    "succeeded" => "good".to_string(),
                    "failed" | "heartbeat_missed" => "failed".to_string(),
                    "running" | "leased" => "active".to_string(),
                    _ => "scheduled".to_string(),
                });

            entries.push(json!({
                "id": occurrence.id,
                "entry_type": "automation",
                "display_status": display_status,
                "quality_badge": quality_badge,
                "automation": automation.clone(),
                "occurrence": occurrence.clone(),
                "run": run.clone(),
                "evaluation": evaluation.clone(),
                "shared_context": shared_context.clone(),
                "planned_local": occurrence.planned_at.with_timezone(&tz).to_rfc3339(),
                "finished_local": occurrence.finished_at.map(|ts| ts.with_timezone(&tz).to_rfc3339()),
            }));
        }

        let session_runs = db::list_runs_in_range(&conn, Some("terminal_canvas"), from, to, 2_000)?;
        for run in session_runs {
            if let Some(status_filter) = status {
                if run.status != status_filter {
                    continue;
                }
            }
            let run_agent_name = run
                .agent_name
                .clone()
                .or(run.openclaw_agent_name.clone())
                .unwrap_or_default();
            if let Some(agent_filter) = agent {
                if run_agent_name != agent_filter {
                    continue;
                }
            }

            let artifacts = db::list_run_artifacts(&conn, &run.id)?;
            let metrics = artifacts
                .iter()
                .rev()
                .find(|artifact| artifact.kind == "terminal_canvas_framework_metrics")
                .and_then(|artifact| artifact.meta_json.clone());
            let session_manifest = artifacts
                .iter()
                .rev()
                .find(|artifact| artifact.kind == "terminal_canvas_session_manifest")
                .and_then(|artifact| artifact.meta_json.clone());

            let framework_name = session_manifest
                .as_ref()
                .and_then(|row| row.get("framework_name"))
                .and_then(Value::as_str)
                .or_else(|| {
                    metrics
                        .as_ref()
                        .and_then(|row| row.get("framework_name"))
                        .and_then(Value::as_str)
                })
                .unwrap_or("")
                .to_string();
            let startup_stage = session_manifest
                .as_ref()
                .and_then(|row| row.get("startup_stage"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let manifest_doc_id = session_manifest
                .as_ref()
                .and_then(|row| row.get("doc_id"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let manifest_doc_title = session_manifest
                .as_ref()
                .and_then(|row| row.get("doc_title"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let prompt_present = session_manifest
                .as_ref()
                .and_then(|row| row.get("prompt_present"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let transcript_length = session_manifest
                .as_ref()
                .and_then(|row| row.get("transcript_length"))
                .and_then(Value::as_u64)
                .unwrap_or(0);
            let framework_accuracy = metrics
                .as_ref()
                .and_then(|row| row.get("framework_follow_accuracy_percent"))
                .and_then(Value::as_f64);
            let overall_accuracy = metrics
                .as_ref()
                .and_then(|row| row.get("overall_accuracy_percent"))
                .and_then(Value::as_f64)
                .or(framework_accuracy)
                .unwrap_or(0.0);

            if let Some(score) = framework_accuracy {
                framework_accuracy_total += score;
                framework_accuracy_count += 1;
            }

            let display_status = match run.status.as_str() {
                "queued" => "scheduled".to_string(),
                "running" => "running".to_string(),
                "succeeded" => "succeeded".to_string(),
                "failed" => "failed".to_string(),
                "canceled" => "canceled".to_string(),
                "aborted" => "aborted".to_string(),
                _ => run.status.clone(),
            };

            let quality_badge = if overall_accuracy >= 90.0 {
                "excellent"
            } else if overall_accuracy >= 75.0 {
                "good"
            } else if overall_accuracy >= 55.0 {
                "needs_review"
            } else {
                "failed"
            };

            match display_status.as_str() {
                "succeeded" => succeeded += 1,
                "failed" => failed += 1,
                "running" | "scheduled" => active += 1,
                _ => {}
            }

            let planned_at = run.started_at.unwrap_or(run.created_at);
            let occurrence_id = format!("occ_terminal_{}", run.id);
            let run_id = run.id.clone();
            let run_status = run.status.clone();
            let run_summary = run.summary.clone();
            let run_doc_id = run.doc_id.clone();
            let run_task_id = run.task_id.clone();
            let run_started_at = run.started_at;
            let run_ended_at = run.ended_at;
            let run_created_at = run.created_at;
            let run_agent_session_id = run.agent_session_id.clone();
            let run_error_kind = run.error_kind.clone();
            let run_error_message = run.error_message.clone();
            let automation_title = if run_agent_name.is_empty() {
                "Dome Canvas Session".to_string()
            } else {
                format!("{} Session", run_agent_name)
            };
            let framework_name_value = if framework_name.is_empty() {
                Value::Null
            } else {
                Value::String(framework_name.clone())
            };

            entries.push(json!({
                "id": format!("terminal_canvas_{}", run_id),
                "entry_type": "agent_run",
                "display_status": display_status,
                "quality_badge": quality_badge,
                "framework_name": framework_name_value,
                "framework_metrics": metrics.clone(),
                "session_manifest": session_manifest.clone(),
                "automation": {
                    "id": format!("terminal_canvas_session_{}", run_id),
                    "executor_kind": "terminal_canvas",
                    "executor_config_json": {
                        "agent_name": run_agent_name.clone(),
                        "framework_name": framework_name,
                        "startup_stage": startup_stage,
                        "session_doc_title": if manifest_doc_title.is_empty() { Value::Null } else { Value::String(manifest_doc_title.clone()) },
                        "prompt_present": prompt_present,
                        "transcript_length": transcript_length,
                    },
                    "title": automation_title,
                    "prompt_template": run_summary,
                    "doc_id": if manifest_doc_id.is_empty() { run_doc_id.clone() } else { Some(manifest_doc_id.clone()) },
                    "task_id": run_task_id,
                    "shared_context_key": Value::Null,
                    "schedule_kind": "manual",
                    "schedule_json": {},
                    "retry_policy_json": {},
                    "concurrency_policy": "serial",
                    "timezone": timezone,
                    "enabled": true,
                    "created_at": run_created_at,
                    "updated_at": run_ended_at.unwrap_or(planned_at),
                    "paused_at": Value::Null,
                    "last_planned_at": Value::Null,
                },
                "occurrence": {
                    "id": occurrence_id,
                    "automation_id": format!("terminal_canvas_session_{}", run_id),
                    "attempt": 1,
                    "trigger_reason": "interactive_dome",
                    "planned_at": planned_at,
                    "ready_at": planned_at,
                    "leased_at": run_started_at,
                    "started_at": run_started_at,
                    "finished_at": run_ended_at,
                    "status": run_status,
                    "dedupe_key": format!("terminal_canvas:{}", run_id),
                    "lease_owner": run_agent_session_id,
                    "lease_expires_at": Value::Null,
                    "last_heartbeat_at": Value::Null,
                    "run_id": run_id.clone(),
                    "failure_kind": run_error_kind,
                    "failure_message": run_error_message,
                    "retry_count": 0,
                    "created_at": run_created_at,
                    "updated_at": run_ended_at.unwrap_or(planned_at),
                },
                "run": run.clone(),
                "evaluation": {
                    "run_id": run_id,
                    "quality_score": (overall_accuracy / 100.0).clamp(0.0, 1.0),
                    "completion_class": quality_badge,
                    "intervention_count": metrics
                        .as_ref()
                        .and_then(|row| row.get("intervention_count"))
                        .and_then(Value::as_i64)
                        .unwrap_or(0),
                    "retry_count": 0,
                    "lateness_seconds": 0,
                    "evaluated_at": run_ended_at.unwrap_or(planned_at),
                },
                "shared_context": Value::Null,
                "planned_local": planned_at.with_timezone(&tz).to_rfc3339(),
                "finished_local": run_ended_at.map(|ts| ts.with_timezone(&tz).to_rfc3339()),
            }));
            terminal_canvas_entries += 1;
        }

        entries.sort_by(|left, right| {
            let left_planned = left
                .get("planned_local")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let right_planned = right
                .get("planned_local")
                .and_then(Value::as_str)
                .unwrap_or_default();
            left_planned.cmp(right_planned)
        });

        Ok(json!({
            "from": from,
            "to": to,
            "timezone": timezone,
            "summary": {
                "entries": entries.len(),
                "succeeded": succeeded,
                "failed": failed,
                "active": active,
                "terminal_canvas_entries": terminal_canvas_entries,
                "framework_accuracy_average_percent": if framework_accuracy_count == 0 {
                    Value::Null
                } else {
                    json!(framework_accuracy_total / framework_accuracy_count as f64)
                },
            },
            "entries": entries,
        }))
    }

    pub fn monitor_run_evaluation(&self, actor: &Actor, run_id: &str) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "monitor.run_evaluation")?;
        let conn = self.open_conn()?;
        let run = db::get_run(&conn, run_id)?
            .ok_or_else(|| BtError::NotFound(format!("run {} not found", run_id)))?;
        let evaluation = db::get_run_evaluation(&conn, run_id)?
            .ok_or_else(|| BtError::NotFound(format!("run evaluation {} not found", run_id)))?;
        let occurrence = if let Some(occurrence_id) = &run.occurrence_id {
            db::get_occurrence(&conn, occurrence_id)?
        } else {
            None
        };
        Ok(json!({
            "run": run,
            "evaluation": evaluation,
            "occurrence": occurrence,
        }))
    }

    pub fn monitor_overnight_summary(
        &self,
        actor: &Actor,
        from: &str,
        to: &str,
        timezone: &str,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "monitor.overnight_summary")?;
        let from = parse_required_rfc3339(from, "from")?;
        let to = parse_required_rfc3339(to, "to")?;
        let tz = crate::automation::parse_timezone(timezone)?;
        let conn = self.open_conn()?;
        let occurrences = db::list_occurrences(&conn, None, None, Some(from), Some(to), 2000)?;
        let mut finished = 0i64;
        let mut succeeded = 0i64;
        let mut intervention_total = 0i64;
        let mut lateness_total = 0i64;
        let mut daily = std::collections::BTreeMap::<String, serde_json::Map<String, Value>>::new();

        for occurrence in occurrences {
            if !matches!(occurrence.status.as_str(), "succeeded" | "failed") {
                continue;
            }
            finished += 1;
            if occurrence.status == "succeeded" {
                succeeded += 1;
            }
            let eval = if let Some(run_id) = &occurrence.run_id {
                db::get_run_evaluation(&conn, run_id)?
            } else {
                None
            };
            if let Some(eval) = &eval {
                intervention_total += eval.intervention_count;
                lateness_total += eval.lateness_seconds;
            }
            let date_key = occurrence
                .planned_at
                .with_timezone(&tz)
                .format("%Y-%m-%d")
                .to_string();
            let bucket = daily.entry(date_key).or_insert_with(|| {
                let mut map = serde_json::Map::new();
                map.insert("finished".to_string(), json!(0));
                map.insert("succeeded".to_string(), json!(0));
                map.insert("interventions".to_string(), json!(0));
                map
            });
            bucket.insert(
                "finished".to_string(),
                json!(bucket.get("finished").and_then(Value::as_i64).unwrap_or(0) + 1),
            );
            bucket.insert(
                "succeeded".to_string(),
                json!(
                    bucket.get("succeeded").and_then(Value::as_i64).unwrap_or(0)
                        + if occurrence.status == "succeeded" {
                            1
                        } else {
                            0
                        }
                ),
            );
            bucket.insert(
                "interventions".to_string(),
                json!(
                    bucket
                        .get("interventions")
                        .and_then(Value::as_i64)
                        .unwrap_or(0)
                        + eval.as_ref().map(|row| row.intervention_count).unwrap_or(0)
                ),
            );
        }

        let completion_rate = if finished == 0 {
            0.0
        } else {
            succeeded as f64 / finished as f64
        };
        let average_lateness_seconds = if finished == 0 {
            0.0
        } else {
            lateness_total as f64 / finished as f64
        };

        Ok(json!({
            "from": from,
            "to": to,
            "timezone": timezone,
            "summary": {
                "finished": finished,
                "succeeded": succeeded,
                "completion_rate": completion_rate,
                "intervention_total": intervention_total,
                "average_lateness_seconds": average_lateness_seconds,
            },
            "days": daily.into_iter().map(|(date, metrics)| json!({
                "date": date,
                "metrics": metrics,
            })).collect::<Vec<_>>(),
        }))
    }

    pub fn shared_context_get(&self, context_key: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let shared_context = db::get_shared_context(&conn, context_key)?;
        Ok(json!({ "shared_context": shared_context }))
    }

    pub fn context_compact(
        &self,
        actor: &Actor,
        brand: &str,
        session_id: Option<&str>,
        doc_id: Option<&str>,
        force: bool,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManageContext)?;
        let brand_id = Self::normalize_brand_id(brand);
        if !Self::runtime_brand_exists(&brand_id) {
            return Err(BtError::Validation(format!("unsupported brand {}", brand)));
        }
        if session_id.is_none() && doc_id.is_none() {
            return Err(BtError::Validation(
                "session_id or doc_id is required".to_string(),
            ));
        }

        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        let (sources, resolved_doc_id) = self.collect_context_sources(&conn, session_id, doc_id)?;
        if sources.is_empty() {
            return Err(BtError::Validation(
                "no compactable context sources found".to_string(),
            ));
        }

        let source_hash = Self::sha(
            &sources
                .iter()
                .map(|source| format!("{}:{}:{}", source.source_ref, source.hash, source.rank))
                .collect::<Vec<_>>()
                .join("\n"),
        );
        let effective_doc_id = doc_id.map(ToOwned::to_owned).or(resolved_doc_id.clone());
        let previous = db::get_latest_context_pack(
            &conn,
            Some(&brand_id),
            session_id,
            effective_doc_id.as_deref(),
        )?;
        if let Some(previous) = &previous {
            if previous.source_hash == source_hash && !force {
                return Ok(json!({
                    "created": false,
                    "reason": "source hash unchanged",
                    "context_pack": previous,
                }));
            }
        }

        let mut pack_sources = sources.clone();
        if let Some(previous_pack) = &previous {
            let previous_summary_path =
                fs_guard::safe_join(&root, Path::new(&previous_pack.summary_path))?;
            if previous_summary_path.exists() {
                let body = fs::read_to_string(previous_summary_path)?;
                let rank = pack_sources.iter().map(|row| row.rank).max().unwrap_or(0) + 1;
                pack_sources.push(ContextSourceItem {
                    source_kind: "previous_pack".to_string(),
                    source_ref: format!("context:{}", previous_pack.context_id),
                    source_path: Some(previous_pack.summary_path.clone()),
                    title: format!("Previous context pack {}", previous_pack.context_id),
                    body: body.clone(),
                    hash: Self::sha(&body),
                    rank,
                    locator_json: json!({
                        "context_id": previous_pack.context_id,
                        "brand": previous_pack.brand,
                        "session_id": previous_pack.session_id,
                        "doc_id": previous_pack.doc_id,
                    }),
                });
            }
        }

        let (structured_summary, citation_count) =
            self.build_structured_context_summary(&pack_sources, effective_doc_id.as_deref())?;
        let delta = if let Some(previous_pack) = &previous {
            let previous_sources = db::list_context_pack_sources(&conn, &previous_pack.context_id)?;
            let previous_map = previous_sources
                .into_iter()
                .map(|row| (row.source_ref, row.source_hash))
                .collect::<HashMap<_, _>>();
            let current_map = sources
                .iter()
                .map(|row| (row.source_ref.clone(), row.hash.clone()))
                .collect::<HashMap<_, _>>();
            let changed = current_map
                .iter()
                .filter(|(source_ref, hash)| previous_map.get(*source_ref) != Some(*hash))
                .count();
            let unchanged = current_map
                .iter()
                .filter(|(source_ref, hash)| previous_map.get(*source_ref) == Some(*hash))
                .count();
            let added = current_map
                .keys()
                .filter(|source_ref| !previous_map.contains_key(*source_ref))
                .count();
            let removed = previous_map
                .keys()
                .filter(|source_ref| !current_map.contains_key(*source_ref))
                .count();
            json!({
                "previous_context_id": previous_pack.context_id,
                "changed_sources": changed,
                "unchanged_sources": unchanged,
                "added_sources": added,
                "removed_sources": removed,
            })
        } else {
            Value::Null
        };

        let created_at = Utc::now();
        let context_id = format!("ctx_{}", Uuid::new_v4().simple());
        let pack_dir_rel = format!("{}/{}", CONTEXT_PACKS_DIR_REL, context_id);
        let manifest_rel = format!("{}/manifest.json", pack_dir_rel);
        let summary_rel = format!("{}/summary.md", pack_dir_rel);
        let excerpts_rel = format!("{}/excerpts.jsonl", pack_dir_rel);
        let views_dir_rel = format!("{}/views", pack_dir_rel);

        let summary_markdown = self.build_context_summary_markdown(
            &context_id,
            &brand_id,
            session_id,
            effective_doc_id.as_deref(),
            &structured_summary,
            &pack_sources,
        );
        let token_estimate = ((summary_markdown.len()
            + pack_sources
                .iter()
                .map(|row| row.body.len().min(2_400))
                .sum::<usize>())
            / 4) as i64;

        let source_refs = pack_sources
            .iter()
            .map(|source| {
                json!({
                    "source_kind": source.source_kind,
                    "source_ref": source.source_ref,
                    "source_path": source.source_path,
                    "title": source.title,
                    "source_hash": source.hash,
                    "rank": source.rank,
                    "locator": source.locator_json,
                })
            })
            .collect::<Vec<_>>();

        let manifest_value = json!({
            "schema_version": CONTEXT_PACK_SCHEMA_VERSION,
            "anatomy_version": RUNTIME_ANATOMY_VERSION,
            "context_id": context_id,
            "brand": brand_id,
            "session_id": session_id,
            "doc_id": effective_doc_id,
            "created_at": created_at,
            "source_hash": source_hash,
            "previous_context_id": previous.as_ref().map(|row| row.context_id.clone()),
            "delta": delta,
            "structured_summary": structured_summary,
            "source_refs": source_refs,
            "citation_count": citation_count,
            "unresolved_citation_count": 0,
            "token_estimate": token_estimate,
        });

        let excerpts = pack_sources
            .iter()
            .map(|source| {
                serde_json::to_string(&json!({
                    "source_kind": source.source_kind,
                    "source_ref": source.source_ref,
                    "source_path": source.source_path,
                    "title": source.title,
                    "source_hash": source.hash,
                    "rank": source.rank,
                    "locator": source.locator_json,
                    "excerpt": Self::truncate_text(&source.body, 2400),
                }))
                .map_err(|e| BtError::Validation(e.to_string()))
            })
            .collect::<Result<Vec<_>, _>>()?
            .join("\n");

        self.upsert_runtime_json_file(&root, &manifest_rel, &manifest_value)?;
        self.upsert_runtime_file(&root, &summary_rel, &summary_markdown)?;
        self.upsert_runtime_file(&root, &excerpts_rel, &excerpts)?;
        for (view_brand, _) in SUPPORTED_RUNTIME_BRANDS {
            let view_rel = format!("{}/{}.md", views_dir_rel, view_brand);
            let view = self.build_context_brand_view(view_brand, &context_id, &summary_markdown);
            self.upsert_runtime_file(&root, &view_rel, &view)?;
        }

        db::supersede_active_context_packs(
            &conn,
            &brand_id,
            session_id,
            effective_doc_id.as_deref(),
            created_at,
        )?;
        let pack_record = ContextPackRecord {
            context_id: context_id.clone(),
            brand: brand_id.clone(),
            session_id: session_id.map(ToOwned::to_owned),
            doc_id: effective_doc_id.clone(),
            status: "ready".to_string(),
            source_hash,
            token_estimate,
            citation_count: citation_count as i64,
            unresolved_citation_count: 0,
            previous_context_id: previous.as_ref().map(|row| row.context_id.clone()),
            manifest_path: manifest_rel.clone(),
            summary_path: summary_rel.clone(),
            created_at,
            superseded_at: None,
        };
        let source_records = pack_sources
            .iter()
            .map(|source| ContextPackSourceRecord {
                id: None,
                context_id: context_id.clone(),
                source_kind: source.source_kind.clone(),
                source_ref: source.source_ref.clone(),
                source_path: source.source_path.clone(),
                source_hash: source.hash.clone(),
                source_rank: source.rank,
                locator_json: source.locator_json.clone(),
            })
            .collect::<Vec<_>>();
        db::insert_context_pack(&conn, &pack_record)?;
        db::replace_context_pack_sources(&conn, &context_id, &source_records)?;

        self.audit(
            actor,
            "context.compact",
            &json!({
                "brand": brand_id,
                "session_id": session_id,
                "doc_id": effective_doc_id,
                "force": force,
            }),
            effective_doc_id.as_deref(),
            None,
            "ok",
            json!({ "context_id": context_id }),
        )?;

        Ok(json!({
            "created": true,
            "context_pack": pack_record,
            "preferred_view_path": root.join(format!("{}/views/{}.md", pack_dir_rel, brand_id)),
            "structured_summary": manifest_value.get("structured_summary").cloned().unwrap_or(Value::Null),
        }))
    }

    pub fn context_resolve(
        &self,
        brand: Option<&str>,
        session_id: Option<&str>,
        doc_id: Option<&str>,
        mode: Option<&str>,
    ) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        let brand_id = brand.map(Self::normalize_brand_id);
        let pack = db::get_latest_context_pack(&conn, brand_id.as_deref(), session_id, doc_id)?;

        let Some(pack) = pack else {
            return Ok(json!({
                "resolved": false,
                "brand": brand_id,
                "mode": mode.unwrap_or("compact"),
                "recommended_next_steps": ["Run context.compact for this session or doc."],
            }));
        };

        let manifest = self
            .read_optional_json_file(&root, &pack.manifest_path)?
            .unwrap_or(Value::Null);
        let sources = db::list_context_pack_sources(&conn, &pack.context_id)?;
        let preferred_view_rel = format!(
            "{}/{}/views/{}.md",
            CONTEXT_PACKS_DIR_REL, pack.context_id, pack.brand
        );

        Ok(json!({
            "resolved": true,
            "brand": pack.brand,
            "mode": mode.unwrap_or("compact"),
            "context_pack": pack,
            "preferred_view_path": root.join(&preferred_view_rel),
            "structured_summary": manifest.get("structured_summary").cloned().unwrap_or(Value::Null),
            "source_references": sources,
            "expansion_recommendations": [
                "Read the preferred brand view first.",
                "Expand cited sources only when the compact summary is insufficient.",
            ],
        }))
    }

    pub fn context_get(&self, context_id: &str) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        let pack = db::get_context_pack(&conn, context_id)?
            .ok_or_else(|| BtError::NotFound(format!("context pack {} not found", context_id)))?;
        let manifest = self
            .read_optional_json_file(&root, &pack.manifest_path)?
            .unwrap_or(Value::Null);
        let summary_path = fs_guard::safe_join(&root, Path::new(&pack.summary_path))?;
        let summary = if summary_path.exists() {
            Some(fs::read_to_string(summary_path)?)
        } else {
            None
        };
        let sources = db::list_context_pack_sources(&conn, context_id)?;

        Ok(json!({
            "context_pack": pack,
            "manifest": manifest,
            "summary": summary,
            "source_references": sources,
        }))
    }

    pub fn context_list(
        &self,
        brand: Option<&str>,
        session_id: Option<&str>,
        doc_id: Option<&str>,
        limit: usize,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let brand_id = brand.map(Self::normalize_brand_id);
        let packs = db::list_context_packs(&conn, brand_id.as_deref(), session_id, doc_id, limit)?;
        Ok(json!({ "context_packs": packs }))
    }

    pub fn scheduler_tick(&self) -> Result<Value, BtError> {
        let actor = Actor::System {
            component: "scheduler".to_string(),
        };
        let now = Utc::now();
        let horizon_end = now + Duration::days(30);
        let conn = self.open_conn()?;
        let automations = db::list_automations(&conn, Some(true), None, 1000)?;
        let recovered = db::recover_expired_occurrences(&conn, now)?;
        let mut materialized = 0usize;
        let mut promoted = 0usize;

        for automation in automations {
            match parse_schedule(&automation)? {
                ScheduleDefinition::Heartbeat(schedule) => {
                    let last_success = db::latest_success_for_automation(&conn, &automation.id)?
                        .unwrap_or(automation.created_at);
                    let stale_at =
                        last_success + Duration::seconds(schedule.stale_after_seconds.max(60));
                    if stale_at <= now {
                        let status = if automation.concurrency_policy == "allow_overlap"
                            || !db::has_active_occurrence(&conn, &automation.id)?
                        {
                            "ready"
                        } else {
                            "scheduled"
                        };
                        let occurrence = self.build_occurrence(
                            &automation,
                            stale_at,
                            "heartbeat_stale",
                            1,
                            status,
                        );
                        if db::insert_occurrence_if_absent(&conn, &occurrence)? {
                            materialized += 1;
                            if status == "ready" {
                                self.emit_event(
                                    &actor,
                                    "automation.occurrence.ready",
                                    automation.doc_id.as_deref(),
                                    None,
                                    json!({
                                        "automation_id": automation.id,
                                        "occurrence_id": occurrence.id,
                                        "trigger_reason": occurrence.trigger_reason,
                                        "planned_at": occurrence.planned_at,
                                    }),
                                    Some(&occurrence.dedupe_key),
                                )?;
                            }
                        }
                        db::set_automation_last_planned(&conn, &automation.id, stale_at)?;
                    }
                }
                _ => {
                    let planned_times = expand_schedule(&automation, now, horizon_end)?;
                    let mut latest_planned = automation.last_planned_at;
                    let serial_active = automation.concurrency_policy != "allow_overlap"
                        && db::has_active_occurrence(&conn, &automation.id)?;
                    for planned_at in planned_times {
                        let status = if planned_at <= now && !serial_active {
                            "ready"
                        } else {
                            "scheduled"
                        };
                        let occurrence =
                            self.build_occurrence(&automation, planned_at, "scheduled", 1, status);
                        if db::insert_occurrence_if_absent(&conn, &occurrence)? {
                            materialized += 1;
                            if status == "ready" {
                                self.emit_event(
                                    &actor,
                                    "automation.occurrence.ready",
                                    automation.doc_id.as_deref(),
                                    None,
                                    json!({
                                        "automation_id": automation.id,
                                        "occurrence_id": occurrence.id,
                                        "trigger_reason": occurrence.trigger_reason,
                                        "planned_at": occurrence.planned_at,
                                    }),
                                    Some(&occurrence.dedupe_key),
                                )?;
                            }
                        }
                        latest_planned = Some(planned_at);
                    }
                    if let Some(latest_planned) = latest_planned {
                        db::set_automation_last_planned(&conn, &automation.id, latest_planned)?;
                    }
                }
            }

            let due_scheduled = db::list_occurrences(
                &conn,
                Some(&automation.id),
                Some("scheduled"),
                None,
                Some(now),
                500,
            )?;
            if due_scheduled.is_empty() {
                continue;
            }

            if automation.concurrency_policy == "allow_overlap" {
                for occurrence in due_scheduled {
                    if db::mark_occurrence_ready(
                        &conn,
                        &occurrence.id,
                        "ready",
                        now,
                        occurrence.retry_count,
                    )? {
                        promoted += 1;
                        self.emit_event(
                            &actor,
                            "automation.occurrence.ready",
                            automation.doc_id.as_deref(),
                            occurrence.run_id.as_deref(),
                            json!({
                                "automation_id": automation.id,
                                "occurrence_id": occurrence.id,
                                "planned_at": occurrence.planned_at,
                                "trigger_reason": occurrence.trigger_reason,
                            }),
                            Some(&occurrence.dedupe_key),
                        )?;
                    }
                }
            } else if !db::has_active_occurrence(&conn, &automation.id)? {
                let occurrence = &due_scheduled[0];
                if db::mark_occurrence_ready(
                    &conn,
                    &occurrence.id,
                    "ready",
                    now,
                    occurrence.retry_count,
                )? {
                    promoted += 1;
                    self.emit_event(
                        &actor,
                        "automation.occurrence.ready",
                        automation.doc_id.as_deref(),
                        occurrence.run_id.as_deref(),
                        json!({
                            "automation_id": automation.id,
                            "occurrence_id": occurrence.id,
                            "planned_at": occurrence.planned_at,
                            "trigger_reason": occurrence.trigger_reason,
                        }),
                        Some(&occurrence.dedupe_key),
                    )?;
                }
            }
        }

        db::upsert_worker_cursor(
            &conn,
            &WorkerCursor {
                worker_id: "bt-core-scheduler".to_string(),
                consumer_group: "scheduler".to_string(),
                executor_kind: "scheduler".to_string(),
                last_event_id: 0,
                last_heartbeat_at: now,
                status: "healthy".to_string(),
                lease_count: db::count_occurrences_by_status(&conn, &["leased", "running"])?,
                updated_at: now,
            },
        )?;

        Ok(json!({
            "ok": true,
            "materialized": materialized,
            "promoted": promoted,
            "recovered": recovered,
        }))
    }

    pub fn brand_list(&self) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let brands = db::list_brands(&conn)?;
        Ok(json!({ "brands": brands }))
    }

    pub fn brand_upsert(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "brand.upsert")?;
        self.apply_write(actor, WriteOperation::ManageRegistry)?;
        let conn = self.open_conn()?;
        let now = Utc::now();
        let brand_id = required_str(&params, "brand_id")?;
        let existing = db::get_brand(&conn, brand_id)?;
        let brand = BrandRecord {
            brand_id: brand_id.to_string(),
            label: required_str(&params, "label")?.to_string(),
            adapter_kind: required_str(&params, "adapter_kind")?.to_string(),
            enabled: params
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            metadata_json: params
                .get("metadata_json")
                .cloned()
                .unwrap_or_else(|| json!({})),
            created_at: existing.as_ref().map(|row| row.created_at).unwrap_or(now),
            updated_at: now,
        };
        db::upsert_brand(&conn, &brand)?;
        self.audit(
            actor,
            "brand.upsert",
            &params,
            None,
            None,
            "ok",
            json!({ "brand_id": brand.brand_id }),
        )?;
        Ok(json!({ "brand": brand }))
    }

    pub fn adapter_list(&self) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let adapters = db::list_adapters(&conn)?;
        Ok(json!({ "adapters": adapters }))
    }

    pub fn adapter_upsert(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "adapter.upsert")?;
        self.apply_write(actor, WriteOperation::ManageRegistry)?;
        let conn = self.open_conn()?;
        let now = Utc::now();
        let adapter_kind = required_str(&params, "adapter_kind")?;
        let existing = db::get_adapter(&conn, adapter_kind)?;
        let adapter = AdapterRecord {
            adapter_kind: adapter_kind.to_string(),
            display_name: required_str(&params, "display_name")?.to_string(),
            enabled: params
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            config_json: params
                .get("config_json")
                .cloned()
                .unwrap_or_else(|| json!({})),
            created_at: existing.as_ref().map(|row| row.created_at).unwrap_or(now),
            updated_at: now,
        };
        db::upsert_adapter(&conn, &adapter)?;
        self.audit(
            actor,
            "adapter.upsert",
            &params,
            None,
            None,
            "ok",
            json!({ "adapter_kind": adapter.adapter_kind }),
        )?;
        Ok(json!({ "adapter": adapter }))
    }

    pub fn company_list(&self) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let companies = db::list_companies(&conn)?;
        Ok(json!({ "companies": companies }))
    }

    pub fn company_get(&self, company_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let company = db::get_company(&conn, company_id)?
            .ok_or_else(|| BtError::NotFound(format!("company {} not found", company_id)))?;
        Ok(json!({ "company": company }))
    }

    pub fn company_upsert(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "company.upsert")?;
        self.apply_write(actor, WriteOperation::ManageOrg)?;
        let conn = self.open_conn()?;
        let now = Utc::now();
        let company_id = required_str(&params, "company_id")?;
        let existing = db::get_company(&conn, company_id)?;
        let company = CompanyRecord {
            company_id: company_id.to_string(),
            name: required_str(&params, "name")?.to_string(),
            mission: optional_str(&params, "mission")
                .unwrap_or_default()
                .to_string(),
            active: params
                .get("active")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            created_at: existing.as_ref().map(|row| row.created_at).unwrap_or(now),
            updated_at: now,
        };
        db::upsert_company(&conn, &company)?;
        self.audit(
            actor,
            "company.upsert",
            &params,
            None,
            None,
            "ok",
            json!({ "company_id": company.company_id }),
        )?;
        Ok(json!({ "company": company }))
    }

    pub fn agent_list(&self, company_id: Option<&str>) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let agents = db::list_agents(&conn, company_id)?;
        Ok(json!({ "agents": agents }))
    }

    pub fn agent_get(&self, agent_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let agent = db::get_agent(&conn, agent_id)?
            .ok_or_else(|| BtError::NotFound(format!("agent {} not found", agent_id)))?;
        Ok(json!({ "agent": agent }))
    }

    pub fn agent_upsert(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "agent.upsert")?;
        self.apply_write(actor, WriteOperation::ManageOrg)?;
        let conn = self.open_conn()?;
        let now = Utc::now();
        let agent_id = required_str(&params, "agent_id")?;
        let existing = db::get_agent(&conn, agent_id)?;
        if existing.is_some() {
            self.require_governance_approval(
                &conn,
                optional_str(&params, "approval_id"),
                "agent.update",
                agent_id,
            )?;
        }
        let company_id = optional_str(&params, "company_id").unwrap_or(DEFAULT_COMPANY_ID);
        if db::get_company(&conn, company_id)?.is_none() {
            return Err(BtError::NotFound(format!(
                "company {} not found",
                company_id
            )));
        }
        let brand_id = optional_str(&params, "brand_id").unwrap_or("other");
        let brand = db::get_brand(&conn, brand_id)?
            .ok_or_else(|| BtError::NotFound(format!("brand {} not found", brand_id)))?;
        let adapter_kind = optional_str(&params, "adapter_kind").unwrap_or(&brand.adapter_kind);
        if db::get_adapter(&conn, adapter_kind)?.is_none() {
            return Err(BtError::NotFound(format!(
                "adapter {} not found",
                adapter_kind
            )));
        }
        let runtime_mode = optional_str(&params, "runtime_mode").unwrap_or("event_driven");
        if !matches!(runtime_mode, "event_driven" | "continuous") {
            return Err(BtError::Validation(
                "runtime_mode must be event_driven or continuous".to_string(),
            ));
        }
        let state = optional_str(&params, "state").unwrap_or("active");
        let agent = AgentRecord {
            agent_id: agent_id.to_string(),
            company_id: company_id.to_string(),
            display_name: required_str(&params, "display_name")?.to_string(),
            role_title: required_str(&params, "role_title")?.to_string(),
            role_description: optional_str(&params, "role_description")
                .unwrap_or_default()
                .to_string(),
            manager_agent_id: optional_str(&params, "manager_agent_id").map(ToOwned::to_owned),
            brand_id: brand_id.to_string(),
            adapter_kind: adapter_kind.to_string(),
            runtime_mode: runtime_mode.to_string(),
            budget_monthly_cap_usd: params
                .get("budget_monthly_cap_usd")
                .and_then(Value::as_f64)
                .unwrap_or_else(|| {
                    existing
                        .as_ref()
                        .map(|row| row.budget_monthly_cap_usd)
                        .unwrap_or(0.0)
                }),
            budget_warn_percent: params
                .get("budget_warn_percent")
                .and_then(Value::as_f64)
                .unwrap_or_else(|| {
                    existing
                        .as_ref()
                        .map(|row| row.budget_warn_percent)
                        .unwrap_or(80.0)
                }),
            state: state.to_string(),
            policy_json: params.get("policy_json").cloned().unwrap_or_else(|| {
                existing
                    .as_ref()
                    .map(|row| row.policy_json.clone())
                    .unwrap_or_else(|| json!({}))
            }),
            created_at: existing.as_ref().map(|row| row.created_at).unwrap_or(now),
            updated_at: now,
            paused_at: if state == "paused" { Some(now) } else { None },
        };
        db::upsert_agent(&conn, &agent)?;
        self.record_config_revision(
            &conn,
            &agent.company_id,
            "agent_profile",
            &json!(agent),
            &actor.actor_id(),
        )?;
        self.audit(
            actor,
            "agent.upsert",
            &params,
            None,
            None,
            "ok",
            json!({ "agent_id": agent.agent_id }),
        )?;
        Ok(json!({ "agent": agent }))
    }

    pub fn goal_list(
        &self,
        company_id: Option<&str>,
        parent_goal_id: Option<&str>,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let goals = db::list_goals(&conn, company_id, parent_goal_id)?;
        Ok(json!({ "goals": goals }))
    }

    pub fn goal_get(&self, goal_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let goal = db::get_goal(&conn, goal_id)?
            .ok_or_else(|| BtError::NotFound(format!("goal {} not found", goal_id)))?;
        Ok(json!({ "goal": goal }))
    }

    pub fn goal_upsert(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "goal.upsert")?;
        self.apply_write(actor, WriteOperation::ManageGoal)?;
        let conn = self.open_conn()?;
        let now = Utc::now();
        let goal_id = required_str(&params, "goal_id")?;
        let existing = db::get_goal(&conn, goal_id)?;
        let company_id = optional_str(&params, "company_id").unwrap_or(DEFAULT_COMPANY_ID);
        let goal = GoalRecord {
            goal_id: goal_id.to_string(),
            company_id: company_id.to_string(),
            parent_goal_id: optional_str(&params, "parent_goal_id").map(ToOwned::to_owned),
            kind: optional_str(&params, "kind")
                .unwrap_or("project")
                .to_string(),
            title: required_str(&params, "title")?.to_string(),
            description: optional_str(&params, "description")
                .unwrap_or_default()
                .to_string(),
            status: optional_str(&params, "status")
                .unwrap_or("active")
                .to_string(),
            owner_agent_id: optional_str(&params, "owner_agent_id").map(ToOwned::to_owned),
            created_at: existing.as_ref().map(|row| row.created_at).unwrap_or(now),
            updated_at: now,
        };
        db::upsert_goal(&conn, &goal)?;
        self.audit(
            actor,
            "goal.upsert",
            &params,
            None,
            None,
            "ok",
            json!({ "goal_id": goal.goal_id }),
        )?;
        Ok(json!({ "goal": goal }))
    }

    pub fn ticket_list(
        &self,
        company_id: Option<&str>,
        status: Option<&str>,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let tickets = db::list_tickets(&conn, company_id, status)?;
        Ok(json!({ "tickets": tickets }))
    }

    pub fn ticket_get(&self, ticket_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let ticket = db::get_ticket(&conn, ticket_id)?
            .ok_or_else(|| BtError::NotFound(format!("ticket {} not found", ticket_id)))?;
        Ok(json!({ "ticket": ticket }))
    }

    pub fn ticket_upsert(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "ticket.upsert")?;
        self.apply_write(actor, WriteOperation::ManageTicket)?;
        let conn = self.open_conn()?;
        let now = Utc::now();
        let ticket_id = required_str(&params, "ticket_id")?;
        let existing = db::get_ticket(&conn, ticket_id)?;
        let ticket = TicketRecord {
            ticket_id: ticket_id.to_string(),
            company_id: optional_str(&params, "company_id")
                .unwrap_or(DEFAULT_COMPANY_ID)
                .to_string(),
            goal_id: optional_str(&params, "goal_id").map(ToOwned::to_owned),
            task_id: optional_str(&params, "task_id").map(ToOwned::to_owned),
            title: required_str(&params, "title")?.to_string(),
            status: optional_str(&params, "status")
                .unwrap_or("open")
                .to_string(),
            priority: optional_str(&params, "priority").map(ToOwned::to_owned),
            assigned_agent_id: optional_str(&params, "assigned_agent_id").map(ToOwned::to_owned),
            current_run_id: optional_str(&params, "current_run_id").map(ToOwned::to_owned),
            plan_required: params
                .get("plan_required")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            plan_id: optional_str(&params, "plan_id").map(ToOwned::to_owned),
            created_at: existing.as_ref().map(|row| row.created_at).unwrap_or(now),
            updated_at: now,
        };
        db::upsert_ticket(&conn, &ticket)?;
        self.audit(
            actor,
            "ticket.upsert",
            &params,
            None,
            ticket.current_run_id.as_deref(),
            "ok",
            json!({ "ticket_id": ticket.ticket_id }),
        )?;
        Ok(json!({ "ticket": ticket }))
    }

    pub fn ticket_thread_message(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManageTicket)?;
        let conn = self.open_conn()?;
        let message = TicketThreadMessage {
            message_id: format!("tmsg_{}", Uuid::new_v4().simple()),
            ticket_id: required_str(&params, "ticket_id")?.to_string(),
            run_id: optional_str(&params, "run_id").map(ToOwned::to_owned),
            actor_type: actor.actor_type().to_string(),
            actor_id: actor.actor_id(),
            body_md: required_str(&params, "body_md")?.to_string(),
            created_at: Utc::now(),
        };
        db::insert_ticket_message(&conn, &message)?;
        Ok(json!({ "message": message }))
    }

    pub fn ticket_thread_decision(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManageTicket)?;
        let conn = self.open_conn()?;
        let decision = TicketDecision {
            decision_id: format!("tdc_{}", Uuid::new_v4().simple()),
            ticket_id: required_str(&params, "ticket_id")?.to_string(),
            run_id: optional_str(&params, "run_id").map(ToOwned::to_owned),
            decision_type: optional_str(&params, "decision_type")
                .unwrap_or("generic")
                .to_string(),
            decision_text: required_str(&params, "decision_text")?.to_string(),
            created_at: Utc::now(),
        };
        db::insert_ticket_decision(&conn, &decision)?;
        Ok(json!({ "decision": decision }))
    }

    pub fn ticket_thread_trace(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManageTicket)?;
        let conn = self.open_conn()?;
        let trace = TicketToolTrace {
            trace_id: format!("ttr_{}", Uuid::new_v4().simple()),
            ticket_id: required_str(&params, "ticket_id")?.to_string(),
            run_id: optional_str(&params, "run_id").map(ToOwned::to_owned),
            tool_name: required_str(&params, "tool_name")?.to_string(),
            input_json: params.get("input_json").cloned().unwrap_or(Value::Null),
            output_json: params.get("output_json").cloned().unwrap_or(Value::Null),
            created_at: Utc::now(),
        };
        db::insert_ticket_trace(&conn, &trace)?;
        Ok(json!({ "trace": trace }))
    }

    pub fn ticket_thread_get(&self, ticket_id: &str, limit: usize) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let messages = db::list_ticket_messages(&conn, ticket_id, limit)?;
        let decisions = db::list_ticket_decisions(&conn, ticket_id, limit)?;
        let traces = db::list_ticket_traces(&conn, ticket_id, limit)?;
        Ok(json!({
            "ticket_id": ticket_id,
            "messages": messages,
            "decisions": decisions,
            "traces": traces,
        }))
    }

    pub fn budget_get_status(&self, company_id: &str, agent_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let agent = db::get_agent(&conn, agent_id)?
            .ok_or_else(|| BtError::NotFound(format!("agent {} not found", agent_id)))?;
        if agent.company_id != company_id {
            return Err(BtError::Conflict(format!(
                "agent {} does not belong to company {}",
                agent_id, company_id
            )));
        }
        let now = Utc::now();
        let month_key = Self::budget_month_key(now);
        let used = db::sum_budget_usage_for_month(&conn, company_id, agent_id, &month_key)?;
        let cap = agent.budget_monthly_cap_usd;
        let ratio = if cap > 0.0 { used / cap } else { 0.0 };
        let warn_threshold = agent.budget_warn_percent / 100.0;
        let active_override = db::get_active_budget_override(&conn, agent_id, now)?;
        Ok(json!({
            "company_id": company_id,
            "agent_id": agent_id,
            "month_key": month_key,
            "used_usd": used,
            "cap_usd": cap,
            "ratio": ratio,
            "warn_threshold": warn_threshold,
            "warned": cap > 0.0 && ratio >= warn_threshold,
            "hard_cap_reached": cap > 0.0 && ratio >= 1.0,
            "agent_state": agent.state,
            "active_override": active_override,
        }))
    }

    pub fn budget_override(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "budget.override")?;
        self.apply_write(actor, WriteOperation::ManageBudget)?;
        let conn = self.open_conn()?;
        let agent_id = required_str(&params, "agent_id")?;
        self.require_governance_approval(
            &conn,
            optional_str(&params, "approval_id"),
            "budget.override",
            agent_id,
        )?;
        let company_id = optional_str(&params, "company_id").unwrap_or(DEFAULT_COMPANY_ID);
        let override_row = BudgetOverrideRecord {
            override_id: format!("bovr_{}", Uuid::new_v4().simple()),
            company_id: company_id.to_string(),
            agent_id: agent_id.to_string(),
            reason: required_str(&params, "reason")?.to_string(),
            approved_by: optional_str(&params, "approved_by")
                .unwrap_or(DEFAULT_BOARD_ACTOR)
                .to_string(),
            active: true,
            expires_at: parse_optional_rfc3339(optional_str(&params, "expires_at"), "expires_at")?,
            created_at: Utc::now(),
        };
        db::insert_budget_override(&conn, &override_row)?;
        db::set_agent_state(&conn, agent_id, "active", None, Utc::now())?;
        self.record_config_revision(
            &conn,
            company_id,
            "budget_override",
            &json!(override_row),
            &actor.actor_id(),
        )?;
        Ok(json!({ "override": override_row }))
    }

    pub fn plan_submit(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManagePlan)?;
        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        let company_id = optional_str(&params, "company_id").unwrap_or(DEFAULT_COMPANY_ID);
        let submitted_by = actor.actor_id();
        let now = Utc::now();

        let input_path = required_str(&params, "file_path")?;
        let plan_input_path = PathBuf::from(input_path);
        let plan_source = if plan_input_path.is_absolute() {
            plan_input_path
        } else {
            fs_guard::safe_join(&root, Path::new(input_path))?
        };
        let allow_external = std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join(".local/share/opencode/plans"))
            .map(|allowed| plan_source.starts_with(&allowed))
            .unwrap_or(false);
        if !allow_external && !plan_source.starts_with(&root) {
            return Err(BtError::Validation(
                "plan file path must be inside vault or ~/.local/share/opencode/plans".to_string(),
            ));
        }
        let content_md = fs::read_to_string(&plan_source)?;
        let plan_id = optional_str(&params, "plan_id")
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| format!("plan_{}", Uuid::new_v4().simple()));
        let ticket_id = optional_str(&params, "ticket_id").map(ToOwned::to_owned);
        let task_id = optional_str(&params, "task_id").map(ToOwned::to_owned);
        let agent_id = optional_str(&params, "agent_id").map(ToOwned::to_owned);

        let plans_dir = fs_guard::safe_join(&root, Path::new(".bt/plans"))?;
        fs::create_dir_all(&plans_dir)?;
        let canonical_rel = format!(".bt/plans/{}.md", plan_id);
        let canonical_abs = fs_guard::safe_join(&root, Path::new(&canonical_rel))?;
        fs_guard::atomic_write(&root, &canonical_abs, &content_md)?;

        let existing = db::get_plan(&conn, &plan_id)?;
        let next_revision = existing
            .as_ref()
            .map(|row| row.latest_revision + 1)
            .unwrap_or(1);
        let revision_rel = format!(".bt/plans/{}.r{}.md", plan_id, next_revision);
        let revision_abs = fs_guard::safe_join(&root, Path::new(&revision_rel))?;
        fs_guard::atomic_write(&root, &revision_abs, &content_md)?;

        let revision = PlanRevisionRecord {
            revision_id: format!("prev_{}", Uuid::new_v4().simple()),
            plan_id: plan_id.clone(),
            revision_number: next_revision,
            file_path: revision_rel.clone(),
            content_md: content_md.clone(),
            submitted_by: submitted_by.clone(),
            submitted_at: now,
            review_status: "submitted".to_string(),
            review_comment: None,
        };
        db::insert_plan_revision(&conn, &revision)?;

        let plan = PlanRecord {
            plan_id: plan_id.clone(),
            company_id: company_id.to_string(),
            ticket_id: ticket_id.clone(),
            task_id: task_id.clone(),
            agent_id: agent_id.clone(),
            status: "plan_submitted".to_string(),
            plan_path: canonical_rel,
            latest_revision: next_revision,
            submitted_by: Some(submitted_by),
            approved_by: existing.as_ref().and_then(|row| row.approved_by.clone()),
            approved_at: existing.as_ref().and_then(|row| row.approved_at),
            review_note: None,
            created_at: existing.as_ref().map(|row| row.created_at).unwrap_or(now),
            updated_at: now,
        };
        if existing.is_some() {
            db::update_plan(&conn, &plan)?;
        } else {
            db::insert_plan(&conn, &plan)?;
        }
        if let Some(ticket_id) = &ticket_id {
            db::set_ticket_plan(&conn, ticket_id, Some(&plan_id), now)?;
        }
        self.emit_event(
            actor,
            "plan.submitted",
            None,
            None,
            json!({
                "plan_id": plan.plan_id,
                "ticket_id": plan.ticket_id,
                "task_id": plan.task_id,
                "revision_number": next_revision,
                "plan_path": plan.plan_path,
            }),
            None,
        )?;
        Ok(json!({ "plan": plan, "revision": revision }))
    }

    pub fn plan_get(&self, plan_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let plan = db::get_plan(&conn, plan_id)?
            .ok_or_else(|| BtError::NotFound(format!("plan {} not found", plan_id)))?;
        let revisions = db::list_plan_revisions(&conn, plan_id)?;
        Ok(json!({ "plan": plan, "revisions": revisions }))
    }

    pub fn plan_list(
        &self,
        ticket_id: Option<&str>,
        task_id: Option<&str>,
        status: Option<&str>,
        limit: usize,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let plans = db::list_plans(&conn, ticket_id, task_id, status, limit)?;
        Ok(json!({ "plans": plans }))
    }

    pub fn plan_review(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "plan.review")?;
        self.apply_write(actor, WriteOperation::ManagePlan)?;
        let conn = self.open_conn()?;
        let plan_id = required_str(&params, "plan_id")?;
        let mut plan = db::get_plan(&conn, plan_id)?
            .ok_or_else(|| BtError::NotFound(format!("plan {} not found", plan_id)))?;
        plan.status = "plan_approved".to_string();
        plan.approved_by = Some(actor.actor_id());
        plan.approved_at = Some(Utc::now());
        plan.review_note = optional_str(&params, "review_note").map(ToOwned::to_owned);
        plan.updated_at = Utc::now();
        db::update_plan(&conn, &plan)?;
        self.emit_event(
            actor,
            "plan.approved",
            None,
            None,
            json!({ "plan_id": plan.plan_id, "status": plan.status }),
            None,
        )?;
        Ok(json!({ "plan": plan }))
    }

    pub fn plan_request_changes(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "plan.request_changes")?;
        self.apply_write(actor, WriteOperation::ManagePlan)?;
        let conn = self.open_conn()?;
        let plan_id = required_str(&params, "plan_id")?;
        let mut plan = db::get_plan(&conn, plan_id)?
            .ok_or_else(|| BtError::NotFound(format!("plan {} not found", plan_id)))?;
        plan.status = "plan_changes_requested".to_string();
        plan.review_note = optional_str(&params, "review_note").map(ToOwned::to_owned);
        plan.updated_at = Utc::now();
        db::update_plan(&conn, &plan)?;
        self.emit_event(
            actor,
            "plan.changes_requested",
            None,
            None,
            json!({ "plan_id": plan.plan_id, "status": plan.status }),
            None,
        )?;
        Ok(json!({ "plan": plan }))
    }

    pub fn runtime_mode_get(&self, agent_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let agent = db::get_agent(&conn, agent_id)?
            .ok_or_else(|| BtError::NotFound(format!("agent {} not found", agent_id)))?;
        Ok(json!({
            "agent_id": agent_id,
            "runtime_mode": agent.runtime_mode,
            "state": agent.state,
            "paused_at": agent.paused_at,
        }))
    }

    pub fn runtime_mode_set(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "runtime.mode.set")?;
        self.apply_write(actor, WriteOperation::ManageRuntime)?;
        let conn = self.open_conn()?;
        let agent_id = required_str(&params, "agent_id")?;
        self.require_governance_approval(
            &conn,
            optional_str(&params, "approval_id"),
            "runtime.mode.set",
            agent_id,
        )?;
        let mode = required_str(&params, "runtime_mode")?;
        if !matches!(mode, "event_driven" | "continuous") {
            return Err(BtError::Validation(
                "runtime_mode must be event_driven or continuous".to_string(),
            ));
        }
        let state = if mode == "continuous" {
            "active"
        } else {
            "active"
        };
        db::set_agent_runtime_mode(&conn, agent_id, mode, Some(state), None, Utc::now())?;
        let agent = db::get_agent(&conn, agent_id)?
            .ok_or_else(|| BtError::NotFound(format!("agent {} not found", agent_id)))?;
        self.record_config_revision(
            &conn,
            &agent.company_id,
            "agent_runtime_mode",
            &json!({ "agent_id": agent_id, "runtime_mode": mode }),
            &actor.actor_id(),
        )?;
        Ok(json!({ "agent": agent }))
    }

    pub fn governance_approval_create(
        &self,
        actor: &Actor,
        params: Value,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "governance.approval.create")?;
        self.apply_write(actor, WriteOperation::ManageGovernance)?;
        let approval = GovernanceApproval {
            approval_id: format!("appr_{}", Uuid::new_v4().simple()),
            company_id: optional_str(&params, "company_id")
                .unwrap_or(DEFAULT_COMPANY_ID)
                .to_string(),
            subject_type: required_str(&params, "subject_type")?.to_string(),
            subject_id: required_str(&params, "subject_id")?.to_string(),
            action: required_str(&params, "action")?.to_string(),
            payload_json: params
                .get("payload_json")
                .cloned()
                .unwrap_or_else(|| json!({})),
            requested_by: actor.actor_id(),
            status: "pending".to_string(),
            reviewed_by: None,
            reviewed_at: None,
            created_at: Utc::now(),
        };
        let conn = self.open_conn()?;
        db::insert_governance_approval(&conn, &approval)?;
        Ok(json!({ "approval": approval }))
    }

    pub fn governance_approval_review(
        &self,
        actor: &Actor,
        params: Value,
    ) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "governance.approval.review")?;
        self.apply_write(actor, WriteOperation::ManageGovernance)?;
        let conn = self.open_conn()?;
        let approval_id = required_str(&params, "approval_id")?;
        let status = required_str(&params, "status")?;
        if !matches!(status, "approved" | "rejected") {
            return Err(BtError::Validation(
                "status must be approved or rejected".to_string(),
            ));
        }
        db::update_governance_approval(
            &conn,
            approval_id,
            status,
            Some(&actor.actor_id()),
            Some(Utc::now()),
        )?;
        let approval = db::get_governance_approval(&conn, approval_id)?
            .ok_or_else(|| BtError::NotFound(format!("approval {} not found", approval_id)))?;
        Ok(json!({ "approval": approval }))
    }

    pub fn governance_approval_list(
        &self,
        company_id: Option<&str>,
        status: Option<&str>,
        limit: usize,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let approvals = db::list_governance_approvals(&conn, company_id, status, limit)?;
        Ok(json!({ "approvals": approvals }))
    }

    pub fn config_revision_list(
        &self,
        company_id: &str,
        config_scope: Option<&str>,
        limit: usize,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let revisions = db::list_config_revisions(&conn, company_id, config_scope, limit)?;
        Ok(json!({ "revisions": revisions }))
    }

    pub fn config_revision_rollback(&self, actor: &Actor, params: Value) -> Result<Value, BtError> {
        self.require_operator_actor(actor, "config.revision.rollback")?;
        self.apply_write(actor, WriteOperation::ManageGovernance)?;
        let conn = self.open_conn()?;
        let revision_id = required_str(&params, "revision_id")?;
        let company_id = optional_str(&params, "company_id").unwrap_or(DEFAULT_COMPANY_ID);
        let revisions = db::list_config_revisions(&conn, company_id, None, 500)?;
        let revision = revisions
            .into_iter()
            .find(|row| row.revision_id == revision_id)
            .ok_or_else(|| BtError::NotFound(format!("revision {} not found", revision_id)))?;

        if revision.config_scope == "agent_runtime_mode" {
            let agent_id = revision
                .config_json
                .get("agent_id")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    BtError::Validation("agent_runtime_mode revision missing agent_id".to_string())
                })?;
            let runtime_mode = revision
                .config_json
                .get("runtime_mode")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    BtError::Validation(
                        "agent_runtime_mode revision missing runtime_mode".to_string(),
                    )
                })?;
            db::set_agent_runtime_mode(
                &conn,
                agent_id,
                runtime_mode,
                Some("active"),
                None,
                Utc::now(),
            )?;
        }

        self.record_config_revision(
            &conn,
            company_id,
            "rollback",
            &json!({
                "from_revision_id": revision_id,
                "config_scope": revision.config_scope,
                "config_json": revision.config_json,
            }),
            &actor.actor_id(),
        )?;
        Ok(json!({ "rolled_back_revision": revision_id, "config_scope": revision.config_scope }))
    }

    fn require_governance_approval(
        &self,
        conn: &rusqlite::Connection,
        approval_id: Option<&str>,
        action: &str,
        subject_id: &str,
    ) -> Result<(), BtError> {
        let Some(approval_id) = approval_id else {
            return Err(BtError::Forbidden(format!(
                "board approval required for action {} on {}",
                action, subject_id
            )));
        };
        let approval = db::get_governance_approval(conn, approval_id)?
            .ok_or_else(|| BtError::NotFound(format!("approval {} not found", approval_id)))?;
        if approval.status != "approved" {
            return Err(BtError::Forbidden(format!(
                "approval {} is not approved",
                approval_id
            )));
        }
        if approval.action != action {
            return Err(BtError::Forbidden(format!(
                "approval {} action mismatch: expected {}, got {}",
                approval_id, action, approval.action
            )));
        }
        if approval.subject_id != subject_id {
            return Err(BtError::Forbidden(format!(
                "approval {} subject mismatch: expected {}, got {}",
                approval_id, subject_id, approval.subject_id
            )));
        }
        Ok(())
    }

    fn record_config_revision(
        &self,
        conn: &rusqlite::Connection,
        company_id: &str,
        config_scope: &str,
        config_json: &Value,
        created_by: &str,
    ) -> Result<ConfigRevision, BtError> {
        let previous = db::latest_config_revision(conn, company_id, config_scope)?;
        let revision = ConfigRevision {
            revision_id: format!("cfgrev_{}", Uuid::new_v4().simple()),
            company_id: company_id.to_string(),
            config_scope: config_scope.to_string(),
            config_json: config_json.clone(),
            previous_revision_id: previous.map(|row| row.revision_id),
            created_by: created_by.to_string(),
            created_at: Utc::now(),
        };
        db::insert_config_revision(conn, &revision)?;
        Ok(revision)
    }

    pub fn task_create(
        &self,
        actor: &Actor,
        title: &str,
        doc_id: Option<&str>,
        due: Option<&str>,
        priority: Option<&str>,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;

        let conn = self.open_conn()?;
        let topic = if let Some(id) = doc_id {
            db::get_doc(&conn, id)?.map(|d| d.topic)
        } else {
            None
        };

        let due_at = if let Some(due) = due {
            Some(
                DateTime::parse_from_rfc3339(due)
                    .map(|d| d.with_timezone(&Utc))
                    .map_err(|_| BtError::Validation("due must be RFC3339".to_string()))?,
            )
        } else {
            None
        };

        let now = Utc::now();
        let has_active = db::get_active_task_for_doc(&conn, doc_id)?.is_some();
        let task = Task {
            id: format!("tsk_{}", Uuid::new_v4().simple()),
            title: title.to_string(),
            status: "open".to_string(),
            priority: priority.map(ToOwned::to_owned),
            due_at,
            topic,
            doc_id: doc_id.map(ToOwned::to_owned),
            created_at: now,
            updated_at: Some(now),
            completed_at: None,
            earliest_start_at: None,
            snooze_until: None,
            lease_owner: None,
            lease_expires_at: None,
            queue_lane: if has_active {
                "queued".to_string()
            } else {
                "active".to_string()
            },
            queue_order: Some(db::next_queue_order_for_doc(&conn, doc_id)?),
            success_criteria: Vec::new(),
            verification_hint: None,
            verification_summary: None,
            archived_at: None,
            merged_into_task_id: None,
            verified_by_run_id: None,
        };

        db::insert_task(&conn, &task)?;
        self.sync_task_markdown_files(actor)?;
        self.refresh_graph_projection()?;

        self.audit(
            actor,
            "task.create",
            &json!({ "title": title, "doc_id": doc_id, "due": due, "priority": priority }),
            doc_id,
            None,
            "ok",
            json!({ "task_id": task.id }),
        )?;

        Ok(json!({ "task": task }))
    }

    pub fn task_complete(&self, actor: &Actor, task_id: &str) -> Result<Value, BtError> {
        let out = self.task_verify_and_archive(
            actor,
            task_id,
            "Completed via legacy task.complete.",
            None,
        )?;

        self.audit(
            actor,
            "task.complete",
            &json!({ "task_id": task_id }),
            None,
            None,
            "ok",
            json!({}),
        )?;

        Ok(json!({
            "task_id": task_id,
            "completed": true,
            "task": out.get("task").cloned().unwrap_or(Value::Null),
            "next_active_task": out.get("next_active_task").cloned().unwrap_or(Value::Null),
        }))
    }

    pub fn task_list(
        &self,
        status: Option<&str>,
        topic: Option<&str>,
        doc_id: Option<&str>,
        lane: Option<&str>,
        include_archived: bool,
        limit: usize,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let tasks = db::list_tasks(
            &conn,
            status,
            topic,
            doc_id,
            lane,
            include_archived || lane == Some("archived"),
            limit,
        )?;
        Ok(json!({ "tasks": tasks }))
    }

    pub fn task_plan_sync_from_doc(&self, actor: &Actor, doc_id: &str) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;

        let conn = self.open_conn()?;
        let doc = db::get_doc(&conn, doc_id)?
            .ok_or_else(|| BtError::NotFound(format!("doc {} not found", doc_id)))?;
        if let Actor::Agent { .. } = actor {
            let matching_sessions = db::list_craftship_sessions(&conn, None, None, true, 200)?
                .into_iter()
                .filter(|session| {
                    session.doc_id.as_deref() == Some(doc_id)
                        || session.source_doc_id.as_deref() == Some(doc_id)
                })
                .collect::<Vec<_>>();
            if matching_sessions.is_empty() {
                return Err(BtError::Forbidden(
                    "agent task.plan.sync_from_doc is only allowed for craftship session docs or source docs"
                        .to_string(),
                ));
            }
            let mut allowed = false;
            for session in matching_sessions {
                if self
                    .require_team_lead_or_operator(
                        &conn,
                        actor,
                        &session.craftship_session_id,
                        "task.plan.sync_from_doc",
                    )
                    .is_ok()
                {
                    allowed = true;
                    break;
                }
            }
            if !allowed {
                return Err(BtError::Forbidden(
                    "lead authority required for agent task.plan.sync_from_doc".to_string(),
                ));
            }
        }
        let root = self.require_vault()?;
        let agent_path = fs_guard::safe_join(&root, Path::new(&doc.agent_path))?;
        let agent_content = fs::read_to_string(agent_path)?;
        let plan = parse_dome_task_plan(&agent_content)?.ok_or_else(|| {
            BtError::Validation("agent.md is missing a valid dome-task-plan block".to_string())
        })?;
        let DomeTaskPlan {
            version: plan_version,
            mode: plan_mode,
            tasks: mut plan_tasks,
        } = plan;
        let current_active = db::get_active_task_for_doc(&conn, Some(doc_id))?;
        let archived_tasks =
            db::list_tasks(&conn, None, None, Some(doc_id), Some("archived"), true, 500)?;
        let archived_titles = archived_tasks
            .iter()
            .map(|task| normalize_task_title(&task.title))
            .collect::<HashSet<_>>();
        plan_tasks.retain(|entry| !archived_titles.contains(&normalize_task_title(&entry.title)));

        if let Some(active_task) = &current_active {
            let active_index = plan_tasks
                .iter()
                .position(|entry| task_plan_entry_matches_active(entry, active_task))
                .ok_or_else(|| {
                    BtError::Validation(format!(
                        "active task {:?} is not present in dome-task-plan",
                        active_task.title
                    ))
                })?;
            plan_tasks.drain(0..=active_index);
        }

        let removed_queued_count = db::delete_queued_tasks_for_doc(&conn, Some(doc_id))?;
        let mut active_task = current_active.clone();
        let mut created_queued: Vec<Task> = Vec::new();
        let now = Utc::now();

        if active_task.is_none() {
            if let Some(first) = plan_tasks.first().cloned() {
                let created = self.build_planned_task(&doc, first, "active", now);
                db::insert_task(&conn, &created)?;
                active_task = Some(created);
                plan_tasks.remove(0);
            }
        }

        for entry in plan_tasks {
            let task = self.build_planned_task(&doc, entry, "queued", now);
            db::insert_task(&conn, &task)?;
            created_queued.push(task);
        }

        self.sync_task_markdown_files(actor)?;
        self.emit_event(
            actor,
            "task.plan_synced",
            Some(doc_id),
            None,
            json!({
                "doc_id": doc_id,
                "mode": plan_mode,
                "version": plan_version,
                "active_task_id": active_task.as_ref().map(|task| task.id.clone()),
                "queued_task_ids": created_queued.iter().map(|task| task.id.clone()).collect::<Vec<_>>(),
                "removed_queued_count": removed_queued_count,
                "active_preserved": current_active.is_some(),
            }),
            None,
        )?;
        if current_active.is_none() {
            if let Some(task) = &active_task {
                self.emit_event(
                    actor,
                    "task.activated",
                    task.doc_id.as_deref(),
                    None,
                    json!({
                        "task_id": task.id,
                        "doc_id": task.doc_id,
                        "source": "task_plan_sync",
                    }),
                    None,
                )?;
            }
        }

        self.audit(
            actor,
            "task.plan.sync_from_doc",
            &json!({ "doc_id": doc_id }),
            Some(doc_id),
            None,
            "ok",
            json!({
                "active_task_id": active_task.as_ref().map(|task| task.id.clone()),
                "queued_task_ids": created_queued.iter().map(|task| task.id.clone()).collect::<Vec<_>>(),
                "removed_queued_count": removed_queued_count,
            }),
        )?;

        Ok(json!({
            "doc_id": doc_id,
            "active_task": active_task,
            "queued_tasks": created_queued,
            "removed_queued_count": removed_queued_count,
        }))
    }

    pub fn task_remove(&self, actor: &Actor, task_id: &str) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let task = db::get_task(&conn, task_id)?
            .ok_or_else(|| BtError::NotFound(format!("task {} not found", task_id)))?;
        if task.queue_lane != "queued" {
            return Err(BtError::Validation(
                "only queued tasks can be removed".to_string(),
            ));
        }

        db::delete_task(&conn, task_id)?;
        self.sync_task_markdown_files(actor)?;
        self.emit_event(
            actor,
            "task.removed",
            task.doc_id.as_deref(),
            None,
            json!({
                "task_id": task.id,
                "doc_id": task.doc_id,
                "queue_order": task.queue_order,
            }),
            None,
        )?;
        self.audit(
            actor,
            "task.remove",
            &json!({ "task_id": task_id }),
            task.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "task_id": task_id, "removed": true }))
    }

    pub fn task_steer_into_active(&self, actor: &Actor, task_id: &str) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let task = db::get_task(&conn, task_id)?
            .ok_or_else(|| BtError::NotFound(format!("task {} not found", task_id)))?;
        if task.queue_lane != "queued" {
            return Err(BtError::Validation(
                "only queued tasks can be steered into the active task".to_string(),
            ));
        }
        let active_task =
            db::get_active_task_for_doc(&conn, task.doc_id.as_deref())?.ok_or_else(|| {
                BtError::Conflict("no active task exists for this dome note".to_string())
            })?;

        db::update_task_merge(&conn, task_id, &active_task.id, Utc::now())?;
        let merged_task = db::get_task(&conn, task_id)?
            .ok_or_else(|| BtError::NotFound(format!("task {} not found after merge", task_id)))?;

        self.sync_task_markdown_files(actor)?;
        self.emit_event(
            actor,
            "task.steered",
            merged_task.doc_id.as_deref(),
            None,
            json!({
                "task_id": merged_task.id,
                "doc_id": merged_task.doc_id,
                "merged_into_task_id": active_task.id,
            }),
            None,
        )?;
        self.audit(
            actor,
            "task.steer_into_active",
            &json!({ "task_id": task_id }),
            merged_task.doc_id.as_deref(),
            None,
            "ok",
            json!({ "merged_into_task_id": active_task.id }),
        )?;

        Ok(json!({
            "task": merged_task,
            "active_task": active_task,
        }))
    }

    pub fn task_verify_and_archive(
        &self,
        actor: &Actor,
        task_id: &str,
        verification_summary: &str,
        run_id: Option<&str>,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let summary = verification_summary.trim();
        if summary.is_empty() {
            return Err(BtError::Validation(
                "verification_summary is required".to_string(),
            ));
        }

        let conn = self.open_conn()?;
        let task = db::get_task(&conn, task_id)?
            .ok_or_else(|| BtError::NotFound(format!("task {} not found", task_id)))?;
        if task.queue_lane != "active" {
            return Err(BtError::Validation(
                "only active tasks can be verified and archived".to_string(),
            ));
        }
        if let Some(run_id) = run_id {
            let _ = db::get_run(&conn, run_id)?
                .ok_or_else(|| BtError::NotFound(format!("run {} not found", run_id)))?;
        }

        let now = Utc::now();
        db::archive_task(&conn, task_id, summary, run_id, now)?;
        let next_active = db::list_queued_tasks_for_doc(&conn, task.doc_id.as_deref())?
            .into_iter()
            .next();
        if let Some(next) = &next_active {
            db::activate_task(&conn, &next.id, now)?;
        }

        let archived_task = db::get_task(&conn, task_id)?.ok_or_else(|| {
            BtError::NotFound(format!("task {} not found after archive", task_id))
        })?;
        let activated_task = if let Some(next) = next_active {
            db::get_task(&conn, &next.id)?
        } else {
            None
        };

        self.sync_task_markdown_files(actor)?;
        self.emit_event(
            actor,
            "task.verified",
            archived_task.doc_id.as_deref(),
            run_id,
            json!({
                "task_id": archived_task.id,
                "doc_id": archived_task.doc_id,
                "verification_summary": summary,
                "run_id": run_id,
            }),
            None,
        )?;
        self.emit_event(
            actor,
            "task.archived",
            archived_task.doc_id.as_deref(),
            run_id,
            json!({
                "task_id": archived_task.id,
                "doc_id": archived_task.doc_id,
                "archived_at": archived_task.archived_at,
                "verified_by_run_id": archived_task.verified_by_run_id,
            }),
            None,
        )?;
        if let Some(next) = &activated_task {
            self.emit_event(
                actor,
                "task.activated",
                next.doc_id.as_deref(),
                None,
                json!({
                    "task_id": next.id,
                    "doc_id": next.doc_id,
                    "source": "verify_and_archive",
                }),
                None,
            )?;
        }
        self.audit(
            actor,
            "task.verify_and_archive",
            &json!({
                "task_id": task_id,
                "verification_summary": summary,
                "run_id": run_id,
            }),
            archived_task.doc_id.as_deref(),
            run_id,
            "ok",
            json!({
                "next_active_task_id": activated_task.as_ref().map(|task| task.id.clone()),
            }),
        )?;

        Ok(json!({
            "task": archived_task,
            "next_active_task": activated_task,
        }))
    }

    pub fn task_edit_handoff_create(&self, actor: &Actor, task_id: &str) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let task = db::get_task(&conn, task_id)?
            .ok_or_else(|| BtError::NotFound(format!("task {} not found", task_id)))?;
        if task.queue_lane != "queued" {
            return Err(BtError::Validation(
                "only queued tasks can be edited through a handoff".to_string(),
            ));
        }

        let handoff =
            if let Some(existing) = db::get_pending_task_edit_handoff_for_task(&conn, task_id)? {
                existing
            } else {
                let now = Utc::now();
                let created = TaskEditHandoff {
                    handoff_id: format!("th_{}", Uuid::new_v4().simple()),
                    task_id: task.id.clone(),
                    doc_id: task.doc_id.clone(),
                    status: "pending".to_string(),
                    created_by: actor.actor_id(),
                    created_at: now,
                    updated_at: now,
                    claimed_at: None,
                    claimed_by: None,
                    completed_at: None,
                    completed_by: None,
                };
                db::insert_task_edit_handoff(&conn, &created)?;
                self.emit_event(
                    actor,
                    "task.edit_handoff_created",
                    task.doc_id.as_deref(),
                    None,
                    json!({
                        "handoff_id": created.handoff_id,
                        "task_id": created.task_id,
                        "doc_id": created.doc_id,
                    }),
                    None,
                )?;
                created
            };

        self.audit(
            actor,
            "task.edit_handoff.create",
            &json!({ "task_id": task_id }),
            task.doc_id.as_deref(),
            None,
            "ok",
            json!({ "handoff_id": handoff.handoff_id }),
        )?;
        Ok(json!({ "handoff": handoff }))
    }

    pub fn task_edit_handoff_list(
        &self,
        status: Option<&str>,
        limit: usize,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let handoffs = db::list_task_edit_handoffs(&conn, status, limit)?;
        Ok(json!({ "handoffs": handoffs }))
    }

    pub fn task_edit_handoff_claim(
        &self,
        actor: &Actor,
        handoff_id: &str,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let handoff = db::get_task_edit_handoff(&conn, handoff_id)?.ok_or_else(|| {
            BtError::NotFound(format!("task edit handoff {} not found", handoff_id))
        })?;
        // Idempotent: if the same actor already claimed this handoff,
        // return the existing record (handles client-side timeout retries).
        if handoff.status == "claimed" {
            if handoff.claimed_by.as_deref() == Some(&actor.actor_id()) {
                return Ok(json!({ "handoff": handoff }));
            }
            return Err(BtError::Validation(
                "handoff is already claimed by another actor".to_string(),
            ));
        }
        if handoff.status != "pending" {
            return Err(BtError::Validation(
                "only pending task edit handoffs can be claimed".to_string(),
            ));
        }
        db::claim_task_edit_handoff(&conn, handoff_id, &actor.actor_id(), Utc::now())?;
        let claimed = db::get_task_edit_handoff(&conn, handoff_id)?.ok_or_else(|| {
            BtError::NotFound(format!("task edit handoff {} not found", handoff_id))
        })?;
        // No-refresh: status flip only, no graph topology change.
        self.emit_event_no_refresh(
            actor,
            "task.edit_handoff_claimed",
            claimed.doc_id.as_deref(),
            None,
            json!({
                "handoff_id": claimed.handoff_id,
                "task_id": claimed.task_id,
                "doc_id": claimed.doc_id,
                "claimed_by": claimed.claimed_by,
            }),
            None,
        )?;
        self.audit_no_refresh(
            actor,
            "task.edit_handoff.claim",
            &json!({ "handoff_id": handoff_id }),
            claimed.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "handoff": claimed }))
    }

    pub fn task_edit_handoff_complete(
        &self,
        actor: &Actor,
        handoff_id: &str,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let conn = self.open_conn()?;
        let handoff = db::get_task_edit_handoff(&conn, handoff_id)?.ok_or_else(|| {
            BtError::NotFound(format!("task edit handoff {} not found", handoff_id))
        })?;
        db::complete_task_edit_handoff(&conn, handoff_id, &actor.actor_id(), Utc::now())?;
        let completed = db::get_task_edit_handoff(&conn, handoff_id)?.ok_or_else(|| {
            BtError::NotFound(format!("task edit handoff {} not found", handoff_id))
        })?;
        // No-refresh: status flip only, no graph topology change.
        self.emit_event_no_refresh(
            actor,
            "task.edit_handoff_completed",
            completed.doc_id.as_deref(),
            None,
            json!({
                "handoff_id": completed.handoff_id,
                "task_id": completed.task_id,
                "doc_id": completed.doc_id,
            }),
            None,
        )?;
        self.audit_no_refresh(
            actor,
            "task.edit_handoff.complete",
            &json!({ "handoff_id": handoff_id }),
            handoff.doc_id.as_deref(),
            None,
            "ok",
            json!({}),
        )?;
        Ok(json!({ "handoff": completed }))
    }

    pub fn suggestion_create(
        &self,
        actor: &Actor,
        doc_id: &str,
        patch: Value,
        summary: &str,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::InternalBt)?;
        let _ = self
            .load_meta_by_doc(doc_id)?
            .ok_or_else(|| BtError::NotFound(format!("doc {} not found", doc_id)))?;

        let format = patch
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| BtError::Validation("patch.type is required".to_string()))?;

        if format != "unified_diff" && format != "ops" {
            return Err(BtError::Validation(
                "patch.type must be unified_diff|ops".to_string(),
            ));
        }

        if patch.get("value").is_none() {
            return Err(BtError::Validation("patch.value is required".to_string()));
        }

        let suggestion = Suggestion {
            id: format!("sug_{}", Uuid::new_v4().simple()),
            doc_id: doc_id.to_string(),
            format: format.to_string(),
            patch,
            summary: summary.to_string(),
            status: "pending".to_string(),
            created_by: actor.actor_id(),
            created_at: Utc::now(),
            applied_at: None,
            rejected_at: None,
        };

        let conn = self.open_conn()?;
        db::insert_suggestion(&conn, &suggestion)?;

        self.audit(
            actor,
            "suggestion.create",
            &json!({ "doc_id": doc_id, "summary": summary }),
            Some(doc_id),
            None,
            "ok",
            json!({ "suggestion_id": suggestion.id }),
        )?;

        Ok(json!({ "suggestion": suggestion }))
    }

    pub fn suggestion_list(
        &self,
        doc_id: Option<&str>,
        status: Option<&str>,
    ) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let rows = db::list_suggestions(&conn, doc_id, status)?;
        Ok(json!({ "suggestions": rows }))
    }

    pub fn suggestion_apply(&self, actor: &Actor, suggestion_id: &str) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let cfg = config::load_config(&root)?;
        if matches!(actor, Actor::Agent { .. }) && !cfg.allow_agent_apply_suggestions {
            return Err(BtError::Forbidden(
                "agent suggestion.apply disabled (set allow_agent_apply_suggestions=true)"
                    .to_string(),
            ));
        }

        self.apply_write(actor, WriteOperation::UpdateUserNote)?;

        let conn = self.open_conn()?;
        let suggestion = db::get_suggestion(&conn, suggestion_id)?
            .ok_or_else(|| BtError::NotFound(format!("suggestion {} not found", suggestion_id)))?;

        if suggestion.status != "pending" {
            return Err(BtError::Conflict(format!(
                "suggestion {} is already {}",
                suggestion_id, suggestion.status
            )));
        }

        let doc = db::get_doc(&conn, &suggestion.doc_id)?
            .ok_or_else(|| BtError::NotFound(format!("doc {} not found", suggestion.doc_id)))?;

        let user_path = fs_guard::safe_join(&root, Path::new(&doc.user_path))?;
        let agent_path = fs_guard::safe_join(&root, Path::new(&doc.agent_path))?;

        let _lock = fs_guard::acquire_doc_lock(&root, &doc.id, &actor.actor_id())?;

        let current = fs::read_to_string(&user_path)?;
        let next = match suggestion.format.as_str() {
            "unified_diff" => {
                let patch_text = suggestion
                    .patch
                    .get("value")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        BtError::Validation("unified_diff patch.value must be string".to_string())
                    })?;
                let patch = Patch::from_str(patch_text)
                    .map_err(|e| BtError::Validation(format!("invalid unified diff: {}", e)))?;
                apply(&current, &patch)
                    .map_err(|e| BtError::Validation(format!("patch apply failed: {}", e)))?
            }
            "ops" => {
                let ops = suggestion
                    .patch
                    .get("value")
                    .and_then(Value::as_array)
                    .ok_or_else(|| {
                        BtError::Validation("ops patch.value must be array".to_string())
                    })?;
                apply_ops_patch(&current, ops)?
            }
            _ => {
                return Err(BtError::Validation(
                    "unsupported suggestion format".to_string(),
                ))
            }
        };

        fs_guard::atomic_write(&root, &user_path, &next)?;

        let agent_content = fs::read_to_string(&agent_path)?;
        db::refresh_fts(&conn, &doc.id, &next, &agent_content)?;
        self.reindex_doc_embeddings(&conn, &doc.id, &next, &agent_content)?;
        db::set_suggestion_applied(&conn, suggestion_id, Utc::now())?;

        let mut meta = self
            .load_meta_by_doc(&doc.id)?
            .ok_or_else(|| BtError::NotFound(format!("meta for {} missing", doc.id)))?;
        meta.updated_at = Utc::now();
        self.save_meta(&meta)?;

        if matches!(actor, Actor::Agent { .. }) {
            config::save_config(&root, &cfg)?;
        }

        self.audit(
            actor,
            "suggestion.apply",
            &json!({ "suggestion_id": suggestion_id }),
            Some(&doc.id),
            None,
            "ok",
            json!({}),
        )?;

        Ok(json!({ "suggestion_id": suggestion_id, "applied": true }))
    }

    pub fn graph_links(&self, doc_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let links = db::graph_links(&conn, doc_id)?;
        Ok(json!({ "doc_id": doc_id, "links": links }))
    }

    pub fn graph_snapshot(
        &self,
        focus_node_id: Option<&str>,
        include_types: Option<&Value>,
        from: Option<&str>,
        to: Option<&str>,
        search: Option<&str>,
        max_nodes: Option<usize>,
        knowledge_scope: Option<&str>,
        project_id: Option<&str>,
        include_global: Option<bool>,
    ) -> Result<Value, BtError> {
        let (all_nodes, all_edges) = self.load_graph_records()?;
        let include_types = parse_graph_include_types(include_types);
        let scope_filter =
            KnowledgeScopeFilter::from_parts(knowledge_scope, project_id, include_global);
        let from = parse_optional_rfc3339(from, "from")?;
        let to = parse_optional_rfc3339(to, "to")?;
        let search = search
            .map(|value| value.trim().to_lowercase())
            .filter(|value| !value.is_empty());
        let max_nodes = max_nodes.unwrap_or(400).max(50);

        let mut visible_nodes = all_nodes
            .iter()
            .filter(|node| include_types.contains(node.kind.as_str()))
            .filter(|node| graph_node_within_time_window(node, from, to))
            .cloned()
            .collect::<Vec<_>>();

        if scope_filter.mode != "all" {
            let doc_scope_map = graph_doc_scope_map(&all_nodes);
            let direct_keep = visible_nodes
                .iter()
                .filter_map(|node| {
                    graph_node_matches_scope(node, &scope_filter, &doc_scope_map)
                        .and_then(|matches| matches.then(|| node.node_id.clone()))
                })
                .collect::<HashSet<_>>();
            let mut keep = direct_keep.clone();
            for edge in &all_edges {
                if direct_keep.contains(&edge.source_id) || direct_keep.contains(&edge.target_id) {
                    keep.insert(edge.source_id.clone());
                    keep.insert(edge.target_id.clone());
                }
            }
            visible_nodes.retain(|node| keep.contains(&node.node_id));
        }

        let visible_node_ids = visible_nodes
            .iter()
            .map(|node| node.node_id.clone())
            .collect::<HashSet<_>>();
        let mut visible_edges = all_edges
            .iter()
            .filter(|edge| {
                visible_node_ids.contains(&edge.source_id)
                    && visible_node_ids.contains(&edge.target_id)
            })
            .cloned()
            .collect::<Vec<_>>();

        if let Some(search) = &search {
            let matched = visible_nodes
                .iter()
                .filter(|node| node.search_text.to_lowercase().contains(search))
                .map(|node| node.node_id.clone())
                .collect::<HashSet<_>>();
            if matched.is_empty() {
                visible_nodes.clear();
                visible_edges.clear();
            } else {
                let neighbor_ids = visible_edges
                    .iter()
                    .filter(|edge| {
                        matched.contains(&edge.source_id) || matched.contains(&edge.target_id)
                    })
                    .flat_map(|edge| [edge.source_id.clone(), edge.target_id.clone()])
                    .collect::<HashSet<_>>();
                visible_nodes.retain(|node| {
                    matched.contains(&node.node_id) || neighbor_ids.contains(&node.node_id)
                });
                let keep = visible_nodes
                    .iter()
                    .map(|node| node.node_id.clone())
                    .collect::<HashSet<_>>();
                visible_edges.retain(|edge| {
                    keep.contains(&edge.source_id) && keep.contains(&edge.target_id)
                });
            }
        }

        if let Some(focus_node_id) = focus_node_id {
            let keep = graph_focus_neighborhood(focus_node_id, &visible_edges);
            if !keep.is_empty() {
                visible_nodes.retain(|node| keep.contains(&node.node_id));
                visible_edges.retain(|edge| {
                    keep.contains(&edge.source_id) && keep.contains(&edge.target_id)
                });
            }
        }

        if visible_nodes.len() > max_nodes {
            let pinned = focus_node_id
                .map(|value| value.to_string())
                .into_iter()
                .chain(search.as_ref().into_iter().flat_map(|query| {
                    visible_nodes
                        .iter()
                        .filter(move |node| node.search_text.to_lowercase().contains(query))
                        .map(|node| node.node_id.clone())
                        .collect::<Vec<_>>()
                }))
                .collect::<HashSet<_>>();
            visible_nodes.sort_by(graph_node_sort_key);
            let mut keep = pinned;
            for node in &visible_nodes {
                if keep.len() >= max_nodes {
                    break;
                }
                keep.insert(node.node_id.clone());
            }
            visible_nodes.retain(|node| keep.contains(&node.node_id));
            visible_edges
                .retain(|edge| keep.contains(&edge.source_id) && keep.contains(&edge.target_id));
        }

        let counts_by_kind = count_graph_kinds(&all_nodes);
        let visible_counts_by_kind = count_graph_kinds(&visible_nodes);
        let layout = graph_layout(&visible_nodes, &visible_edges);

        Ok(json!({
            "nodes": visible_nodes,
            "edges": visible_edges,
            "layout": layout,
            "stats": {
                "total_nodes": all_nodes.len(),
                "total_edges": all_edges.len(),
                "visible_nodes": visible_nodes.len(),
                "visible_edges": visible_edges.len(),
                "counts_by_kind": counts_by_kind,
                "visible_counts_by_kind": visible_counts_by_kind,
            },
            "available_types": GRAPH_ALL_NODE_TYPES,
            "default_include_types": GRAPH_DEFAULT_INCLUDE_TYPES,
            "hidden_by_default": ["artifact", "event"],
            "focus_node_id": focus_node_id,
            "knowledge_scope": scope_filter.mode,
            "project_id": scope_filter.project_id,
            "include_global": scope_filter.include_global,
        }))
    }

    pub fn graph_node_get(&self, node_id: &str) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let node = if let Some(node) = db::get_graph_node(&conn, node_id)? {
            node
        } else {
            self.refresh_graph_projection()?;
            let conn = self.open_conn()?;
            db::get_graph_node(&conn, node_id)?
                .ok_or_else(|| BtError::NotFound(format!("graph node {} not found", node_id)))?
        };

        let conn = self.open_conn()?;
        let edges = db::list_graph_edges_for_node(&conn, node_id)?;
        let neighbor_ids = edges
            .iter()
            .flat_map(|edge| [edge.source_id.clone(), edge.target_id.clone()])
            .filter(|value| value != node_id)
            .collect::<BTreeSet<_>>();
        let node_map = db::list_graph_nodes(&conn)?
            .into_iter()
            .map(|row| (row.node_id.clone(), row))
            .collect::<HashMap<_, _>>();
        let neighbors = neighbor_ids
            .into_iter()
            .filter_map(|neighbor_id| node_map.get(&neighbor_id).cloned())
            .collect::<Vec<_>>();

        Ok(json!({
            "node": node,
            "edges": edges,
            "neighbors": neighbors,
            "canonical_refs": graph_canonical_refs(&node),
            "inspector": node.payload,
        }))
    }

    pub fn agent_status(
        &self,
        limit: usize,
        knowledge_scope: Option<&str>,
        project_id: Option<&str>,
        include_global: Option<bool>,
    ) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let limit = limit.clamp(1, 200);
        let filter = KnowledgeScopeFilter::from_parts(knowledge_scope, project_id, include_global);
        let latest_dir = fs_guard::safe_join(&root, Path::new(".bt/status/claude/latest"))?;
        let mut statuses = Vec::new();
        if latest_dir.exists() {
            for entry in fs::read_dir(&latest_dir)? {
                let entry = entry?;
                let path = entry.path();
                if path.extension().and_then(|value| value.to_str()) != Some("json") {
                    continue;
                }
                let Ok(body) = fs::read_to_string(&path) else {
                    continue;
                };
                let Ok(mut value) = serde_json::from_str::<Value>(&body) else {
                    continue;
                };
                if let Some(obj) = value.as_object_mut() {
                    obj.insert(
                        "status_path".to_string(),
                        Value::String(
                            path.strip_prefix(&root)
                                .unwrap_or(&path)
                                .to_string_lossy()
                                .replace('\\', "/"),
                        ),
                    );
                }
                if !status_payload_matches_scope(&value, &filter) {
                    continue;
                }
                statuses.push(value);
            }
        }
        statuses.sort_by(|a, b| {
            let left = a
                .get("captured_at")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let right = b
                .get("captured_at")
                .and_then(Value::as_str)
                .unwrap_or_default();
            right.cmp(left)
        });
        statuses.truncate(limit);

        let conn = self.open_conn()?;
        let mut stmt = conn.prepare(
            r#"
            SELECT event_id, agent_name, session_id, project_id, event_kind,
                   context_id, node_id, reason, payload_json, created_at
            FROM agent_context_events
            ORDER BY created_at DESC
            LIMIT ?1
            "#,
        )?;
        let rows = stmt.query_map(params![limit as i64], |row| {
            let payload: String = row.get(8)?;
            Ok(json!({
                "event_id": row.get::<_, String>(0)?,
                "agent_name": row.get::<_, Option<String>>(1)?,
                "session_id": row.get::<_, Option<String>>(2)?,
                "project_id": row.get::<_, Option<String>>(3)?,
                "event_kind": row.get::<_, String>(4)?,
                "context_id": row.get::<_, Option<String>>(5)?,
                "node_id": row.get::<_, Option<String>>(6)?,
                "reason": row.get::<_, Option<String>>(7)?,
                "payload": serde_json::from_str::<Value>(&payload).unwrap_or(Value::Null),
                "created_at": row.get::<_, String>(9)?,
            }))
        })?;
        let mut context_events = Vec::new();
        for row in rows {
            let event = row?;
            if status_payload_matches_scope(&event, &filter) {
                context_events.push(event);
            }
        }

        let docs = db::list_docs(&conn, None)?
            .into_iter()
            .map(|doc| (doc.id.clone(), doc))
            .collect::<HashMap<_, _>>();
        let context_packs = db::list_context_packs(&conn, None, None, None, 25)?
            .into_iter()
            .filter(|pack| {
                if filter.mode == "all" {
                    return true;
                }
                let Some(doc_id) = pack.doc_id.as_deref() else {
                    return filter.include_global || filter.mode == "global";
                };
                docs.get(doc_id)
                    .map(|doc| filter.matches_doc(doc))
                    .unwrap_or(false)
            })
            .collect::<Vec<_>>();
        Ok(json!({
            "statuses": statuses,
            "context_events": context_events,
            "context_packs": context_packs,
            "status_source": ".bt/status/claude/latest",
            "knowledge_scope": filter.mode,
            "project_id": filter.project_id,
            "include_global": filter.include_global,
        }))
    }

    pub fn agent_context_event_record(
        &self,
        actor: &Actor,
        params: &Value,
    ) -> Result<Value, BtError> {
        self.apply_write(actor, WriteOperation::ManageContext)?;
        let event_kind = optional_str(params, "event_kind")
            .or_else(|| optional_str(params, "eventKind"))
            .unwrap_or("agent_used_context");
        if !matches!(event_kind, "agent_used_context" | "agent_skipped_context") {
            return Err(BtError::Validation(
                "event_kind must be agent_used_context or agent_skipped_context".to_string(),
            ));
        }
        let now = Utc::now();
        let event = AgentContextEventRecord {
            event_id: format!("ace_{}", Uuid::new_v4().simple()),
            agent_name: optional_str(params, "agent_name")
                .or_else(|| optional_str(params, "agentName"))
                .map(ToOwned::to_owned)
                .or_else(|| match actor {
                    Actor::Agent { token_id } => Some(token_id.clone()),
                    _ => None,
                }),
            session_id: optional_str(params, "session_id")
                .or_else(|| optional_str(params, "sessionId"))
                .map(ToOwned::to_owned),
            project_id: optional_str(params, "project_id")
                .or_else(|| optional_str(params, "projectId"))
                .map(ToOwned::to_owned),
            event_kind: event_kind.to_string(),
            context_id: optional_str(params, "context_id")
                .or_else(|| optional_str(params, "contextId"))
                .map(ToOwned::to_owned),
            node_id: optional_str(params, "node_id")
                .or_else(|| optional_str(params, "nodeId"))
                .map(ToOwned::to_owned),
            reason: optional_str(params, "reason").map(ToOwned::to_owned),
            payload_json: params.get("payload").cloned().unwrap_or(Value::Null),
            created_at: now,
        };
        let conn = self.open_conn()?;
        db::insert_agent_context_event(&conn, &event)?;
        Ok(json!({ "context_event": event }))
    }

    fn load_graph_records(&self) -> Result<(Vec<GraphNodeRecord>, Vec<GraphEdgeRecord>), BtError> {
        let conn = self.open_conn()?;
        let mut nodes = db::list_graph_nodes(&conn)?;
        let mut edges = db::list_graph_edges(&conn)?;
        if nodes.is_empty() && edges.is_empty() {
            self.refresh_graph_projection()?;
            let conn = self.open_conn()?;
            nodes = db::list_graph_nodes(&conn)?;
            edges = db::list_graph_edges(&conn)?;
        }
        Ok((nodes, edges))
    }

    fn refresh_graph_projection(&self) -> Result<(), BtError> {
        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        let cfg = config::load_config(&root)?;
        let (nodes, edges) = Self::build_graph_projection(&conn, &cfg.tokens)?;
        let result = db::replace_graph_projection(&conn, &nodes, &edges);
        if result.is_ok() {
            if let Ok(mut last) = self.last_graph_refresh.lock() {
                *last = Some(Instant::now());
            }
        }
        result
    }

    /// Debounced variant of `refresh_graph_projection`. Skips the rebuild
    /// if one completed within `GRAPH_REFRESH_THROTTLE` ago. Used on the
    /// `audit()` hot path where bursts of writes (e.g., the craftship
    /// launch chain) would otherwise each pay the full O(vault) rebuild
    /// cost. Callers that need an immediately-fresh projection should
    /// call `refresh_graph_projection` directly; the read path in
    /// `load_graph_records` already self-heals if the projection is empty.
    fn maybe_refresh_graph_projection(&self) -> Result<(), BtError> {
        let should_skip = self
            .last_graph_refresh
            .lock()
            .ok()
            .and_then(|guard| *guard)
            .map(|t| t.elapsed() < GRAPH_REFRESH_THROTTLE)
            .unwrap_or(false);
        if should_skip {
            return Ok(());
        }
        self.refresh_graph_projection()
    }

    fn build_graph_projection(
        conn: &rusqlite::Connection,
        tokens: &[TokenRecord],
    ) -> Result<(Vec<GraphNodeRecord>, Vec<GraphEdgeRecord>), BtError> {
        let docs = db::list_docs(conn, None)?;
        let metas = db::list_doc_meta(conn)?
            .into_iter()
            .map(|meta| (meta.doc_id.clone(), meta))
            .collect::<HashMap<_, _>>();
        let tasks = db::list_tasks(conn, None, None, None, None, true, 10_000)?;
        let runs = db::list_runs(conn, None, 10_000)?;
        let automations = db::list_automations(conn, None, None, 10_000)?;
        let shared_contexts = db::list_shared_contexts(conn)?;
        let brands = db::list_brands(conn)?;
        let adapters = db::list_adapters(conn)?;
        let companies = db::list_companies(conn)?;
        let agents = db::list_agents(conn, None)?;
        let goals = db::list_goals(conn, None, None)?;
        let tickets = db::list_tickets(conn, None, None)?;
        let plans = db::list_plans(conn, None, None, None, 10_000)?;
        let artifacts = db::list_all_run_artifacts(conn)?;
        let events = db::list_events_all(conn)?;
        let crafting_frameworks = db::list_crafting_frameworks(conn, false)?;
        let craftships = db::list_craftships(conn, true)?;
        let craftship_sessions = db::list_craftship_sessions(conn, None, None, true, 10_000)?;
        let context_packs = db::list_context_packs(conn, None, None, None, 10_000)?;
        let agent_context_events = db::list_agent_context_events(conn, 10_000)?;
        let context_sources_by_context = context_packs
            .iter()
            .map(|pack| {
                db::list_context_pack_sources(conn, &pack.context_id)
                    .map(|sources| (pack.context_id.clone(), sources))
            })
            .collect::<Result<HashMap<_, _>, _>>()?;

        let doc_map = docs
            .iter()
            .cloned()
            .map(|doc| (doc.id.clone(), doc))
            .collect::<HashMap<_, _>>();
        let mut doc_ref_map = HashMap::new();
        for doc in &docs {
            doc_ref_map.insert(doc.id.clone(), doc.id.clone());
            doc_ref_map.insert(format!("{}/{}", doc.topic, doc.slug), doc.id.clone());
            doc_ref_map.insert(format!("topics/{}/{}", doc.topic, doc.slug), doc.id.clone());
        }

        let mut agent_tokens = BTreeMap::<String, BTreeSet<String>>::new();
        for token in tokens {
            agent_tokens
                .entry(token.agent_name.clone())
                .or_default()
                .insert(token.token_id.clone());
        }
        let craftship_nodes_by_craftship = craftships
            .iter()
            .map(|craftship| {
                db::list_craftship_nodes(conn, &craftship.craftship_id)
                    .map(|nodes| (craftship.craftship_id.clone(), nodes))
            })
            .collect::<Result<HashMap<_, _>, _>>()?;
        let craftship_session_nodes_by_session = craftship_sessions
            .iter()
            .map(|session| {
                db::list_craftship_session_nodes(conn, &session.craftship_session_id).map(|nodes| {
                    let filtered: Vec<_> = nodes
                        .into_iter()
                        .filter(|n| !n.session_node_id.starts_with("cssn_req_"))
                        .collect();
                    (session.craftship_session_id.clone(), filtered)
                })
            })
            .collect::<Result<HashMap<_, _>, _>>()?;

        let mut nodes = BTreeMap::<String, GraphNodeRecord>::new();
        let mut edges = BTreeMap::<String, GraphEdgeRecord>::new();

        for doc in &docs {
            let meta = metas.get(&doc.id);
            let doc_node_id = format!("doc:{}", doc.id);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: doc_node_id.clone(),
                    kind: "doc".to_string(),
                    ref_id: doc.id.clone(),
                    label: doc.title.clone(),
                    secondary_label: Some(doc.topic.clone()),
                    group_key: format!("topic:{}", doc.topic),
                    search_text: format!(
                        "{} {} {} {} {}",
                        doc.title,
                        doc.topic,
                        doc.slug,
                        meta.map(|row| row.tags.join(" ")).unwrap_or_default(),
                        meta.and_then(|row| row.status.clone()).unwrap_or_default()
                    )
                    .to_lowercase(),
                    sort_time: Some(doc.updated_at),
                    payload: json!({
                        "doc_id": doc.id,
                        "topic": doc.topic,
                        "slug": doc.slug,
                        "title": doc.title,
                        "user_path": doc.user_path,
                        "agent_path": doc.agent_path,
                        "owner_scope": doc.owner_scope,
                        "project_id": doc.project_id,
                        "project_root": doc.project_root,
                        "knowledge_kind": doc.knowledge_kind,
                        "status": meta.and_then(|row| row.status.clone()),
                        "tags": meta.map(|row| row.tags.clone()).unwrap_or_default(),
                        "links_out": meta.map(|row| row.links_out.clone()).unwrap_or_default(),
                        "updated_at": doc.updated_at,
                    }),
                },
            );

            let topic_node_id = format!("topic:{}", doc.topic);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: topic_node_id.clone(),
                    kind: "topic".to_string(),
                    ref_id: doc.topic.clone(),
                    label: doc.topic.clone(),
                    secondary_label: Some("Topic".to_string()),
                    group_key: "topic".to_string(),
                    search_text: format!("{} topic", doc.topic).to_lowercase(),
                    sort_time: None,
                    payload: json!({ "topic": doc.topic }),
                },
            );
            upsert_graph_edge(
                &mut edges,
                GraphEdgeRecord {
                    edge_id: format!("belongs_to_topic:{}:{}", doc_node_id, topic_node_id),
                    kind: "belongs_to_topic".to_string(),
                    source_id: doc_node_id.clone(),
                    target_id: topic_node_id,
                    search_text: format!("{} belongs to {}", doc.title, doc.topic).to_lowercase(),
                    sort_time: Some(doc.updated_at),
                    payload: json!({ "doc_id": doc.id, "topic": doc.topic }),
                },
            );

            if let Some(meta) = meta {
                for tag in &meta.tags {
                    let tag_key = graph_key_segment(tag);
                    let tag_node_id = format!("tag:{}", tag_key);
                    upsert_graph_node(
                        &mut nodes,
                        GraphNodeRecord {
                            node_id: tag_node_id.clone(),
                            kind: "tag".to_string(),
                            ref_id: tag_key.clone(),
                            label: tag.clone(),
                            secondary_label: Some("Tag".to_string()),
                            group_key: "tag".to_string(),
                            search_text: format!("{} tag", tag).to_lowercase(),
                            sort_time: None,
                            payload: json!({ "tag": tag, "tag_key": tag_key }),
                        },
                    );
                    upsert_graph_edge(
                        &mut edges,
                        GraphEdgeRecord {
                            edge_id: format!("tagged:{}:{}", doc_node_id, tag_node_id),
                            kind: "tagged".to_string(),
                            source_id: doc_node_id.clone(),
                            target_id: tag_node_id,
                            search_text: format!("{} {}", doc.title, tag).to_lowercase(),
                            sort_time: Some(meta.updated_at),
                            payload: json!({ "doc_id": doc.id, "tag": tag }),
                        },
                    );
                }

                for link in &meta.links_out {
                    if let Some(target_doc_id) = resolve_graph_doc_ref(link, &doc_ref_map) {
                        if target_doc_id != doc.id {
                            let target_node_id = format!("doc:{}", target_doc_id);
                            upsert_graph_edge(
                                &mut edges,
                                GraphEdgeRecord {
                                    edge_id: format!(
                                        "references:{}:{}",
                                        doc_node_id, target_node_id
                                    ),
                                    kind: "references".to_string(),
                                    source_id: doc_node_id.clone(),
                                    target_id: target_node_id,
                                    search_text: format!("{} {}", doc.title, link).to_lowercase(),
                                    sort_time: Some(meta.updated_at),
                                    payload: json!({ "doc_id": doc.id, "raw_ref": link }),
                                },
                            );
                        }
                    }
                }
            }
        }

        for adapter in &adapters {
            let adapter_node_id = format!("adapter:{}", graph_key_segment(&adapter.adapter_kind));
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: adapter_node_id,
                    kind: "adapter".to_string(),
                    ref_id: adapter.adapter_kind.clone(),
                    label: adapter.display_name.clone(),
                    secondary_label: Some(adapter.adapter_kind.clone()),
                    group_key: "adapter".to_string(),
                    search_text: format!("{} {}", adapter.adapter_kind, adapter.display_name)
                        .to_lowercase(),
                    sort_time: Some(adapter.updated_at),
                    payload: json!({
                        "adapter_kind": adapter.adapter_kind,
                        "display_name": adapter.display_name,
                        "enabled": adapter.enabled,
                        "config_json": adapter.config_json,
                        "updated_at": adapter.updated_at,
                    }),
                },
            );
        }

        for brand in &brands {
            let brand_node_id = format!("brand:{}", graph_key_segment(&brand.brand_id));
            let adapter_node_id = format!("adapter:{}", graph_key_segment(&brand.adapter_kind));
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: brand_node_id.clone(),
                    kind: "brand".to_string(),
                    ref_id: brand.brand_id.clone(),
                    label: brand.label.clone(),
                    secondary_label: Some(brand.adapter_kind.clone()),
                    group_key: "brand".to_string(),
                    search_text: format!(
                        "{} {} {}",
                        brand.brand_id, brand.label, brand.adapter_kind
                    )
                    .to_lowercase(),
                    sort_time: Some(brand.updated_at),
                    payload: json!({
                        "brand_id": brand.brand_id,
                        "label": brand.label,
                        "adapter_kind": brand.adapter_kind,
                        "enabled": brand.enabled,
                        "metadata_json": brand.metadata_json,
                        "updated_at": brand.updated_at,
                    }),
                },
            );
            upsert_graph_edge(
                &mut edges,
                GraphEdgeRecord {
                    edge_id: format!("brand_uses_adapter:{}:{}", brand_node_id, adapter_node_id),
                    kind: "brand_uses_adapter".to_string(),
                    source_id: brand_node_id,
                    target_id: adapter_node_id,
                    search_text: format!("{} {}", brand.label, brand.adapter_kind).to_lowercase(),
                    sort_time: Some(brand.updated_at),
                    payload: json!({ "brand_id": brand.brand_id, "adapter_kind": brand.adapter_kind }),
                },
            );
        }

        for company in &companies {
            let company_node_id = format!("company:{}", graph_key_segment(&company.company_id));
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: company_node_id,
                    kind: "company".to_string(),
                    ref_id: company.company_id.clone(),
                    label: company.name.clone(),
                    secondary_label: Some("Company".to_string()),
                    group_key: "company".to_string(),
                    search_text: format!(
                        "{} {} {}",
                        company.company_id, company.name, company.mission
                    )
                    .to_lowercase(),
                    sort_time: Some(company.updated_at),
                    payload: json!({
                        "company_id": company.company_id,
                        "name": company.name,
                        "mission": company.mission,
                        "active": company.active,
                        "updated_at": company.updated_at,
                    }),
                },
            );
        }

        for agent in &agents {
            let agent_node_id = format!("agent:{}", graph_key_segment(&agent.agent_id));
            let company_node_id = format!("company:{}", graph_key_segment(&agent.company_id));
            let brand_node_id = format!("brand:{}", graph_key_segment(&agent.brand_id));
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: agent_node_id.clone(),
                    kind: "agent".to_string(),
                    ref_id: agent.agent_id.clone(),
                    label: agent.display_name.clone(),
                    secondary_label: Some(agent.role_title.clone()),
                    group_key: "agent".to_string(),
                    search_text: format!(
                        "{} {} {} {} {}",
                        agent.agent_id,
                        agent.display_name,
                        agent.role_title,
                        agent.brand_id,
                        agent.runtime_mode
                    )
                    .to_lowercase(),
                    sort_time: Some(agent.updated_at),
                    payload: json!({
                        "agent_id": agent.agent_id,
                        "display_name": agent.display_name,
                        "role_title": agent.role_title,
                        "role_description": agent.role_description,
                        "company_id": agent.company_id,
                        "manager_agent_id": agent.manager_agent_id,
                        "brand_id": agent.brand_id,
                        "adapter_kind": agent.adapter_kind,
                        "runtime_mode": agent.runtime_mode,
                        "budget_monthly_cap_usd": agent.budget_monthly_cap_usd,
                        "budget_warn_percent": agent.budget_warn_percent,
                        "state": agent.state,
                        "updated_at": agent.updated_at,
                    }),
                },
            );
            upsert_graph_edge(
                &mut edges,
                GraphEdgeRecord {
                    edge_id: format!("agent_in_company:{}:{}", agent_node_id, company_node_id),
                    kind: "agent_in_company".to_string(),
                    source_id: agent_node_id.clone(),
                    target_id: company_node_id,
                    search_text: format!("{} {}", agent.display_name, agent.company_id)
                        .to_lowercase(),
                    sort_time: Some(agent.updated_at),
                    payload: json!({ "agent_id": agent.agent_id, "company_id": agent.company_id }),
                },
            );
            upsert_graph_edge(
                &mut edges,
                GraphEdgeRecord {
                    edge_id: format!("agent_brand:{}:{}", agent_node_id, brand_node_id),
                    kind: "agent_brand".to_string(),
                    source_id: agent_node_id.clone(),
                    target_id: brand_node_id,
                    search_text: format!("{} {}", agent.display_name, agent.brand_id)
                        .to_lowercase(),
                    sort_time: Some(agent.updated_at),
                    payload: json!({ "agent_id": agent.agent_id, "brand_id": agent.brand_id }),
                },
            );
            if let Some(manager_agent_id) = &agent.manager_agent_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "reports_to:{}:agent:{}",
                            agent_node_id,
                            graph_key_segment(manager_agent_id)
                        ),
                        kind: "reports_to".to_string(),
                        source_id: agent_node_id.clone(),
                        target_id: format!("agent:{}", graph_key_segment(manager_agent_id)),
                        search_text: format!("{} {}", agent.display_name, manager_agent_id)
                            .to_lowercase(),
                        sort_time: Some(agent.updated_at),
                        payload: json!({ "agent_id": agent.agent_id, "manager_agent_id": manager_agent_id }),
                    },
                );
            }
        }

        for goal in &goals {
            let goal_node_id = format!("goal:{}", goal.goal_id);
            let company_node_id = format!("company:{}", graph_key_segment(&goal.company_id));
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: goal_node_id.clone(),
                    kind: "goal".to_string(),
                    ref_id: goal.goal_id.clone(),
                    label: goal.title.clone(),
                    secondary_label: Some(goal.kind.clone()),
                    group_key: format!("company:{}", goal.company_id),
                    search_text: format!("{} {} {}", goal.title, goal.description, goal.status)
                        .to_lowercase(),
                    sort_time: Some(goal.updated_at),
                    payload: json!({
                        "goal_id": goal.goal_id,
                        "company_id": goal.company_id,
                        "parent_goal_id": goal.parent_goal_id,
                        "kind": goal.kind,
                        "title": goal.title,
                        "description": goal.description,
                        "status": goal.status,
                        "owner_agent_id": goal.owner_agent_id,
                        "updated_at": goal.updated_at,
                    }),
                },
            );
            upsert_graph_edge(
                &mut edges,
                GraphEdgeRecord {
                    edge_id: format!("goal_in_company:{}:{}", goal_node_id, company_node_id),
                    kind: "goal_in_company".to_string(),
                    source_id: goal_node_id.clone(),
                    target_id: company_node_id,
                    search_text: goal.title.to_lowercase(),
                    sort_time: Some(goal.updated_at),
                    payload: json!({ "goal_id": goal.goal_id, "company_id": goal.company_id }),
                },
            );
            if let Some(parent_goal_id) = &goal.parent_goal_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("goal_parent:{}:goal:{}", goal_node_id, parent_goal_id),
                        kind: "goal_parent".to_string(),
                        source_id: goal_node_id.clone(),
                        target_id: format!("goal:{}", parent_goal_id),
                        search_text: format!("{} {}", goal.title, parent_goal_id).to_lowercase(),
                        sort_time: Some(goal.updated_at),
                        payload: json!({ "goal_id": goal.goal_id, "parent_goal_id": parent_goal_id }),
                    },
                );
            }
            if let Some(owner_agent_id) = &goal.owner_agent_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "goal_owner:{}:agent:{}",
                            goal_node_id,
                            graph_key_segment(owner_agent_id)
                        ),
                        kind: "goal_owner".to_string(),
                        source_id: goal_node_id.clone(),
                        target_id: format!("agent:{}", graph_key_segment(owner_agent_id)),
                        search_text: format!("{} {}", goal.title, owner_agent_id).to_lowercase(),
                        sort_time: Some(goal.updated_at),
                        payload: json!({ "goal_id": goal.goal_id, "owner_agent_id": owner_agent_id }),
                    },
                );
            }
        }

        for ticket in &tickets {
            let ticket_node_id = format!("ticket:{}", ticket.ticket_id);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: ticket_node_id.clone(),
                    kind: "ticket".to_string(),
                    ref_id: ticket.ticket_id.clone(),
                    label: ticket.title.clone(),
                    secondary_label: Some(ticket.status.clone()),
                    group_key: format!("company:{}", ticket.company_id),
                    search_text: format!(
                        "{} {} {}",
                        ticket.title,
                        ticket.status,
                        ticket.priority.clone().unwrap_or_default()
                    )
                    .to_lowercase(),
                    sort_time: Some(ticket.updated_at),
                    payload: json!({
                        "ticket_id": ticket.ticket_id,
                        "company_id": ticket.company_id,
                        "goal_id": ticket.goal_id,
                        "task_id": ticket.task_id,
                        "title": ticket.title,
                        "status": ticket.status,
                        "priority": ticket.priority,
                        "assigned_agent_id": ticket.assigned_agent_id,
                        "current_run_id": ticket.current_run_id,
                        "plan_required": ticket.plan_required,
                        "plan_id": ticket.plan_id,
                        "updated_at": ticket.updated_at,
                    }),
                },
            );
            if let Some(goal_id) = &ticket.goal_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("ticket_goal:{}:goal:{}", ticket_node_id, goal_id),
                        kind: "ticket_goal".to_string(),
                        source_id: ticket_node_id.clone(),
                        target_id: format!("goal:{}", goal_id),
                        search_text: format!("{} {}", ticket.title, goal_id).to_lowercase(),
                        sort_time: Some(ticket.updated_at),
                        payload: json!({ "ticket_id": ticket.ticket_id, "goal_id": goal_id }),
                    },
                );
            }
            if let Some(task_id) = &ticket.task_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("ticket_task:{}:task:{}", ticket_node_id, task_id),
                        kind: "ticket_task".to_string(),
                        source_id: ticket_node_id.clone(),
                        target_id: format!("task:{}", task_id),
                        search_text: format!("{} {}", ticket.title, task_id).to_lowercase(),
                        sort_time: Some(ticket.updated_at),
                        payload: json!({ "ticket_id": ticket.ticket_id, "task_id": task_id }),
                    },
                );
            }
            if let Some(run_id) = &ticket.current_run_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("ticket_run:{}:run:{}", ticket_node_id, run_id),
                        kind: "ticket_run".to_string(),
                        source_id: ticket_node_id.clone(),
                        target_id: format!("run:{}", run_id),
                        search_text: format!("{} {}", ticket.title, run_id).to_lowercase(),
                        sort_time: Some(ticket.updated_at),
                        payload: json!({ "ticket_id": ticket.ticket_id, "run_id": run_id }),
                    },
                );
            }
            if let Some(plan_id) = &ticket.plan_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("ticket_plan:{}:plan:{}", ticket_node_id, plan_id),
                        kind: "ticket_plan".to_string(),
                        source_id: ticket_node_id.clone(),
                        target_id: format!("plan:{}", plan_id),
                        search_text: format!("{} {}", ticket.title, plan_id).to_lowercase(),
                        sort_time: Some(ticket.updated_at),
                        payload: json!({ "ticket_id": ticket.ticket_id, "plan_id": plan_id }),
                    },
                );
            }
        }

        for plan in &plans {
            let plan_node_id = format!("plan:{}", plan.plan_id);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: plan_node_id.clone(),
                    kind: "plan".to_string(),
                    ref_id: plan.plan_id.clone(),
                    label: plan.plan_id.clone(),
                    secondary_label: Some(plan.status.clone()),
                    group_key: format!("company:{}", plan.company_id),
                    search_text: format!("{} {} {}", plan.plan_id, plan.status, plan.plan_path)
                        .to_lowercase(),
                    sort_time: Some(plan.updated_at),
                    payload: json!({
                        "plan_id": plan.plan_id,
                        "company_id": plan.company_id,
                        "ticket_id": plan.ticket_id,
                        "task_id": plan.task_id,
                        "agent_id": plan.agent_id,
                        "status": plan.status,
                        "plan_path": plan.plan_path,
                        "latest_revision": plan.latest_revision,
                        "submitted_by": plan.submitted_by,
                        "approved_by": plan.approved_by,
                        "approved_at": plan.approved_at,
                        "review_note": plan.review_note,
                        "updated_at": plan.updated_at,
                    }),
                },
            );
            if let Some(ticket_id) = &plan.ticket_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("plan_ticket:{}:ticket:{}", plan_node_id, ticket_id),
                        kind: "plan_ticket".to_string(),
                        source_id: plan_node_id.clone(),
                        target_id: format!("ticket:{}", ticket_id),
                        search_text: format!("{} {}", plan.plan_id, ticket_id).to_lowercase(),
                        sort_time: Some(plan.updated_at),
                        payload: json!({ "plan_id": plan.plan_id, "ticket_id": ticket_id }),
                    },
                );
            }
            if let Some(task_id) = &plan.task_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("plan_task:{}:task:{}", plan_node_id, task_id),
                        kind: "plan_task".to_string(),
                        source_id: plan_node_id.clone(),
                        target_id: format!("task:{}", task_id),
                        search_text: format!("{} {}", plan.plan_id, task_id).to_lowercase(),
                        sort_time: Some(plan.updated_at),
                        payload: json!({ "plan_id": plan.plan_id, "task_id": task_id }),
                    },
                );
            }
            if let Some(agent_id) = &plan.agent_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "plan_agent:{}:agent:{}",
                            plan_node_id,
                            graph_key_segment(agent_id)
                        ),
                        kind: "plan_agent".to_string(),
                        source_id: plan_node_id.clone(),
                        target_id: format!("agent:{}", graph_key_segment(agent_id)),
                        search_text: format!("{} {}", plan.plan_id, agent_id).to_lowercase(),
                        sort_time: Some(plan.updated_at),
                        payload: json!({ "plan_id": plan.plan_id, "agent_id": agent_id }),
                    },
                );
            }
        }

        let context_map = shared_contexts
            .iter()
            .cloned()
            .map(|row| (row.context_key.clone(), row))
            .collect::<HashMap<_, _>>();

        for shared in &shared_contexts {
            let context_node_id = format!("shared_context:{}", shared.context_key);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: context_node_id,
                    kind: "shared_context".to_string(),
                    ref_id: shared.context_key.clone(),
                    label: shared.context_key.clone(),
                    secondary_label: Some("Shared Context".to_string()),
                    group_key: "shared_context".to_string(),
                    search_text: shared.context_key.to_lowercase(),
                    sort_time: Some(shared.updated_at),
                    payload: json!({
                        "context_key": shared.context_key,
                        "automation_id": shared.automation_id,
                        "latest_run_id": shared.latest_run_id,
                        "latest_occurrence_id": shared.latest_occurrence_id,
                        "artifact_path": shared.artifact_path,
                        "state_json": shared.state_json,
                        "updated_at": shared.updated_at,
                    }),
                },
            );
        }

        for task in &tasks {
            let topic = task
                .topic
                .clone()
                .or_else(|| {
                    task.doc_id
                        .as_ref()
                        .and_then(|doc_id| doc_map.get(doc_id).map(|doc| doc.topic.clone()))
                })
                .unwrap_or_else(|| "tasks".to_string());
            let task_node_id = format!("task:{}", task.id);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: task_node_id.clone(),
                    kind: "task".to_string(),
                    ref_id: task.id.clone(),
                    label: task.title.clone(),
                    secondary_label: Some(task.queue_lane.clone()),
                    group_key: format!("topic:{}", topic),
                    search_text: format!(
                        "{} {} {} {} {} {} {}",
                        task.title,
                        task.status,
                        task.queue_lane,
                        task.priority.clone().unwrap_or_default(),
                        topic,
                        task.success_criteria.join(" "),
                        task.verification_summary.clone().unwrap_or_default(),
                    )
                    .to_lowercase(),
                    sort_time: task
                        .archived_at
                        .or(task.updated_at)
                        .or(Some(task.created_at)),
                    payload: json!({
                        "task_id": task.id,
                        "title": task.title,
                        "status": task.status,
                        "priority": task.priority,
                        "topic": task.topic,
                        "doc_id": task.doc_id,
                        "created_at": task.created_at,
                        "updated_at": task.updated_at,
                        "completed_at": task.completed_at,
                        "queue_lane": task.queue_lane,
                        "queue_order": task.queue_order,
                        "success_criteria": task.success_criteria,
                        "verification_hint": task.verification_hint,
                        "verification_summary": task.verification_summary,
                        "archived_at": task.archived_at,
                        "merged_into_task_id": task.merged_into_task_id,
                        "verified_by_run_id": task.verified_by_run_id,
                    }),
                },
            );
            if let Some(doc_id) = &task.doc_id {
                let doc_node_id = format!("doc:{}", doc_id);
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("task_for_doc:{}:{}", task_node_id, doc_node_id),
                        kind: "task_for_doc".to_string(),
                        source_id: task_node_id.clone(),
                        target_id: doc_node_id,
                        search_text: format!("{} {}", task.title, doc_id).to_lowercase(),
                        sort_time: task.updated_at.or(Some(task.created_at)),
                        payload: json!({ "task_id": task.id, "doc_id": doc_id }),
                    },
                );
            }
            if let Some(merged_into_task_id) = &task.merged_into_task_id {
                let target_task_node_id = format!("task:{}", merged_into_task_id);
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "merged_into_task:{}:{}",
                            task_node_id, target_task_node_id
                        ),
                        kind: "merged_into_task".to_string(),
                        source_id: task_node_id.clone(),
                        target_id: target_task_node_id,
                        search_text: format!("{} {}", task.title, merged_into_task_id)
                            .to_lowercase(),
                        sort_time: task.updated_at.or(Some(task.created_at)),
                        payload: json!({
                            "task_id": task.id,
                            "merged_into_task_id": merged_into_task_id,
                        }),
                    },
                );
            }
            if let Some(run_id) = &task.verified_by_run_id {
                let run_node_id = format!("run:{}", run_id);
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("verified_by_run:{}:{}", task_node_id, run_node_id),
                        kind: "verified_by_run".to_string(),
                        source_id: task_node_id.clone(),
                        target_id: run_node_id.clone(),
                        search_text: format!("{} {}", task.title, run_id).to_lowercase(),
                        sort_time: task
                            .archived_at
                            .or(task.updated_at)
                            .or(Some(task.created_at)),
                        payload: json!({
                            "task_id": task.id,
                            "run_id": run_id,
                        }),
                    },
                );
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("task_verified_by_run:{}:{}", task_node_id, run_node_id),
                        kind: "task_verified_by_run".to_string(),
                        source_id: task_node_id.clone(),
                        target_id: run_node_id,
                        search_text: format!("{} {}", task.title, run_id).to_lowercase(),
                        sort_time: task
                            .archived_at
                            .or(task.updated_at)
                            .or(Some(task.created_at)),
                        payload: json!({
                            "task_id": task.id,
                            "run_id": run_id,
                            "layer": "DETERMINISTIC",
                            "confidence": 1.0,
                        }),
                    },
                );
            }
        }

        for automation in &automations {
            let group_key = automation
                .doc_id
                .as_ref()
                .and_then(|doc_id| {
                    doc_map
                        .get(doc_id)
                        .map(|doc| format!("topic:{}", doc.topic))
                })
                .unwrap_or_else(|| "automation".to_string());
            let automation_node_id = format!("automation:{}", automation.id);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: automation_node_id.clone(),
                    kind: "automation".to_string(),
                    ref_id: automation.id.clone(),
                    label: automation.title.clone(),
                    secondary_label: Some(automation.executor_kind.clone()),
                    group_key,
                    search_text: format!(
                        "{} {} {} {}",
                        automation.title,
                        automation.executor_kind,
                        automation.schedule_kind,
                        automation.shared_context_key.clone().unwrap_or_default()
                    )
                    .to_lowercase(),
                    sort_time: Some(automation.updated_at),
                    payload: json!({
                        "automation_id": automation.id,
                        "title": automation.title,
                        "executor_kind": automation.executor_kind,
                        "prompt_template": automation.prompt_template,
                        "doc_id": automation.doc_id,
                        "task_id": automation.task_id,
                        "shared_context_key": automation.shared_context_key,
                        "schedule_kind": automation.schedule_kind,
                        "enabled": automation.enabled,
                        "updated_at": automation.updated_at,
                    }),
                },
            );
            if let Some(doc_id) = &automation.doc_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("automation_for_doc:{}:doc:{}", automation.id, doc_id),
                        kind: "automation_for_doc".to_string(),
                        source_id: automation_node_id.clone(),
                        target_id: format!("doc:{}", doc_id),
                        search_text: format!("{} {}", automation.title, doc_id).to_lowercase(),
                        sort_time: Some(automation.updated_at),
                        payload: json!({ "automation_id": automation.id, "doc_id": doc_id }),
                    },
                );
            }
            if let Some(task_id) = &automation.task_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("automation_for_task:{}:task:{}", automation.id, task_id),
                        kind: "automation_for_task".to_string(),
                        source_id: automation_node_id.clone(),
                        target_id: format!("task:{}", task_id),
                        search_text: format!("{} {}", automation.title, task_id).to_lowercase(),
                        sort_time: Some(automation.updated_at),
                        payload: json!({ "automation_id": automation.id, "task_id": task_id }),
                    },
                );
            }
            if let Some(context_key) = &automation.shared_context_key {
                let shared = context_map.get(context_key);
                let context_node_id = format!("shared_context:{}", context_key);
                upsert_graph_node(
                    &mut nodes,
                    GraphNodeRecord {
                        node_id: context_node_id.clone(),
                        kind: "shared_context".to_string(),
                        ref_id: context_key.clone(),
                        label: context_key.clone(),
                        secondary_label: Some("Shared Context".to_string()),
                        group_key: "shared_context".to_string(),
                        search_text: format!("{} {}", context_key, automation.title).to_lowercase(),
                        sort_time: shared.map(|row| row.updated_at),
                        payload: json!({
                            "context_key": context_key,
                            "automation_id": shared.and_then(|row| row.automation_id.clone()).or_else(|| Some(automation.id.clone())),
                            "latest_run_id": shared.and_then(|row| row.latest_run_id.clone()),
                            "latest_occurrence_id": shared.and_then(|row| row.latest_occurrence_id.clone()),
                            "artifact_path": shared.and_then(|row| row.artifact_path.clone()),
                            "state_json": shared.map(|row| row.state_json.clone()).unwrap_or(Value::Null),
                            "updated_at": shared.map(|row| row.updated_at),
                        }),
                    },
                );
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("uses_context:{}:{}", automation_node_id, context_node_id),
                        kind: "uses_context".to_string(),
                        source_id: automation_node_id.clone(),
                        target_id: context_node_id,
                        search_text: format!("{} {}", automation.title, context_key).to_lowercase(),
                        sort_time: shared
                            .map(|row| row.updated_at)
                            .or(Some(automation.updated_at)),
                        payload: json!({ "automation_id": automation.id, "context_key": context_key }),
                    },
                );
            }
        }

        for run in &runs {
            let run_node_id = format!("run:{}", run.id);
            let resolved_agent_name = run
                .agent_name
                .as_ref()
                .or(run.openclaw_agent_name.as_ref())
                .cloned()
                .unwrap_or_default();
            let group_key = run
                .doc_id
                .as_ref()
                .and_then(|doc_id| {
                    doc_map
                        .get(doc_id)
                        .map(|doc| format!("topic:{}", doc.topic))
                })
                .unwrap_or_else(|| "run".to_string());
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: run_node_id.clone(),
                    kind: "run".to_string(),
                    ref_id: run.id.clone(),
                    label: run.summary.clone(),
                    secondary_label: Some(run.status.clone()),
                    group_key,
                    search_text: format!(
                        "{} {} {} {} {}",
                        run.summary,
                        run.status,
                        run.source,
                        resolved_agent_name,
                        run.agent_brand.clone().unwrap_or_default()
                    )
                    .to_lowercase(),
                    sort_time: run.ended_at.or(run.started_at).or(Some(run.created_at)),
                    payload: json!({
                        "run_id": run.id,
                        "source": run.source,
                        "status": run.status,
                        "summary": run.summary,
                        "automation_id": run.automation_id,
                        "occurrence_id": run.occurrence_id,
                        "task_id": run.task_id,
                        "doc_id": run.doc_id,
                        "agent_brand": run.agent_brand,
                        "agent_name": run.agent_name,
                        "agent_session_id": run.agent_session_id,
                        "adapter_kind": run.adapter_kind,
                        "craftship_session_id": run.craftship_session_id,
                        "craftship_session_node_id": run.craftship_session_node_id,
                        "company_id": run.company_id,
                        "agent_id": run.agent_id,
                        "goal_id": run.goal_id,
                        "ticket_id": run.ticket_id,
                        "openclaw_session_id": run.openclaw_session_id,
                        "openclaw_agent_name": run.openclaw_agent_name,
                        "created_at": run.created_at,
                        "started_at": run.started_at,
                        "ended_at": run.ended_at,
                    }),
                },
            );
            if let Some(doc_id) = &run.doc_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("run_for_doc:{}:doc:{}", run.id, doc_id),
                        kind: "run_for_doc".to_string(),
                        source_id: run_node_id.clone(),
                        target_id: format!("doc:{}", doc_id),
                        search_text: format!("{} {}", run.summary, doc_id).to_lowercase(),
                        sort_time: run.ended_at.or(run.started_at).or(Some(run.created_at)),
                        payload: json!({ "run_id": run.id, "doc_id": doc_id }),
                    },
                );
            }
            if let Some(craftship_session_id) = &run.craftship_session_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "craftship_session_run:{}:run:{}",
                            craftship_session_id, run.id
                        ),
                        kind: "craftship_session_run".to_string(),
                        source_id: format!("craftship_session:{}", craftship_session_id),
                        target_id: run_node_id.clone(),
                        search_text: format!("{} {}", craftship_session_id, run.summary)
                            .to_lowercase(),
                        sort_time: run.ended_at.or(run.started_at).or(Some(run.created_at)),
                        payload: json!({
                            "craftship_session_id": craftship_session_id,
                            "run_id": run.id,
                        }),
                    },
                );
            }
            if let Some(craftship_session_node_id) = &run.craftship_session_node_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "craftship_session_node_run_link:{}:run:{}",
                            craftship_session_node_id, run.id
                        ),
                        kind: "craftship_session_node_run_link".to_string(),
                        source_id: format!("craftship_session_node:{}", craftship_session_node_id),
                        target_id: run_node_id.clone(),
                        search_text: format!("{} {}", craftship_session_node_id, run.summary)
                            .to_lowercase(),
                        sort_time: run.ended_at.or(run.started_at).or(Some(run.created_at)),
                        payload: json!({
                            "craftship_session_node_id": craftship_session_node_id,
                            "run_id": run.id,
                        }),
                    },
                );
            }
            if let Some(task_id) = &run.task_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("run_for_task:{}:task:{}", run.id, task_id),
                        kind: "run_for_task".to_string(),
                        source_id: run_node_id.clone(),
                        target_id: format!("task:{}", task_id),
                        search_text: format!("{} {}", run.summary, task_id).to_lowercase(),
                        sort_time: run.ended_at.or(run.started_at).or(Some(run.created_at)),
                        payload: json!({ "run_id": run.id, "task_id": task_id }),
                    },
                );
            }
            if let Some(automation_id) = &run.automation_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "run_from_automation:{}:automation:{}",
                            run.id, automation_id
                        ),
                        kind: "run_from_automation".to_string(),
                        source_id: run_node_id.clone(),
                        target_id: format!("automation:{}", automation_id),
                        search_text: format!("{} {}", run.summary, automation_id).to_lowercase(),
                        sort_time: run.ended_at.or(run.started_at).or(Some(run.created_at)),
                        payload: json!({ "run_id": run.id, "automation_id": automation_id }),
                    },
                );
            }
            if let Some(agent_name) = run.agent_name.as_ref().or(run.openclaw_agent_name.as_ref()) {
                agent_tokens.entry(agent_name.clone()).or_default();
                let agent_node_id = if let Some(agent_id) = &run.agent_id {
                    format!("agent:{}", graph_key_segment(agent_id))
                } else {
                    format!("agent:{}", graph_key_segment(agent_name))
                };
                upsert_graph_node(
                    &mut nodes,
                    GraphNodeRecord {
                        node_id: agent_node_id.clone(),
                        kind: "agent".to_string(),
                        ref_id: run.agent_id.clone().unwrap_or_else(|| agent_name.clone()),
                        label: agent_name.clone(),
                        secondary_label: Some("Agent".to_string()),
                        group_key: "agent".to_string(),
                        search_text: format!("{} agent", agent_name).to_lowercase(),
                        sort_time: Some(run.created_at),
                        payload: json!({
                            "agent_id": run.agent_id,
                            "agent_name": agent_name,
                            "token_ids": agent_tokens
                                .get(agent_name)
                                .map(|rows| rows.iter().cloned().collect::<Vec<_>>())
                                .unwrap_or_default(),
                        }),
                    },
                );
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("emitted_by_agent:{}:{}", agent_node_id, run_node_id),
                        kind: "emitted_by_agent".to_string(),
                        source_id: agent_node_id.clone(),
                        target_id: run_node_id.clone(),
                        search_text: format!("{} {}", agent_name, run.summary).to_lowercase(),
                        sort_time: Some(run.created_at),
                        payload: json!({ "agent_name": agent_name, "run_id": run.id }),
                    },
                );
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "event_emitted_by_agent:{}:{}",
                            agent_node_id, run_node_id
                        ),
                        kind: "event_emitted_by_agent".to_string(),
                        source_id: agent_node_id,
                        target_id: run_node_id.clone(),
                        search_text: format!("{} {}", agent_name, run.summary).to_lowercase(),
                        sort_time: Some(run.created_at),
                        payload: json!({
                            "agent_name": agent_name,
                            "run_id": run.id,
                            "emitted_kind": "run",
                            "layer": "DETERMINISTIC",
                            "confidence": 1.0,
                        }),
                    },
                );
            }
        }

        for artifact in &artifacts {
            let artifact_node_id = format!("artifact:{}", artifact.id);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: artifact_node_id.clone(),
                    kind: "artifact".to_string(),
                    ref_id: artifact.id.clone(),
                    label: artifact
                        .path
                        .clone()
                        .unwrap_or_else(|| artifact.kind.clone()),
                    secondary_label: Some(artifact.kind.clone()),
                    group_key: "artifact".to_string(),
                    search_text: format!(
                        "{} {} {}",
                        artifact.kind,
                        artifact.path.clone().unwrap_or_default(),
                        artifact.run_id
                    )
                    .to_lowercase(),
                    sort_time: Some(artifact.created_at),
                    payload: json!({
                        "artifact_id": artifact.id,
                        "run_id": artifact.run_id,
                        "kind": artifact.kind,
                        "path": artifact.path,
                        "content_inline": artifact.content_inline,
                        "sha256": artifact.sha256,
                        "meta_json": artifact.meta_json,
                        "created_at": artifact.created_at,
                    }),
                },
            );
            upsert_graph_edge(
                &mut edges,
                GraphEdgeRecord {
                    edge_id: format!("artifact_of_run:{}:run:{}", artifact.id, artifact.run_id),
                    kind: "artifact_of_run".to_string(),
                    source_id: artifact_node_id,
                    target_id: format!("run:{}", artifact.run_id),
                    search_text: format!("{} {}", artifact.kind, artifact.run_id).to_lowercase(),
                    sort_time: Some(artifact.created_at),
                    payload: json!({ "artifact_id": artifact.id, "run_id": artifact.run_id }),
                },
            );
        }

        for event in &events {
            let event_node_id = format!("event:{}", event.event_id);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: event_node_id.clone(),
                    kind: "event".to_string(),
                    ref_id: event.event_id.to_string(),
                    label: event.r#type.clone(),
                    secondary_label: Some(event.actor_type.clone()),
                    group_key: format!("event:{}", event.r#type),
                    search_text: format!(
                        "{} {} {} {}",
                        event.r#type,
                        event.actor_type,
                        event.actor_id,
                        event
                            .payload
                            .get("action")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                    )
                    .to_lowercase(),
                    sort_time: Some(event.ts),
                    payload: json!({
                        "event_id": event.event_id,
                        "type": event.r#type,
                        "actor_type": event.actor_type,
                        "actor_id": event.actor_id,
                        "doc_id": event.doc_id,
                        "run_id": event.run_id,
                        "dedupe_key": event.dedupe_key,
                        "payload": event.payload,
                        "ts": event.ts,
                    }),
                },
            );
            if let Some(doc_id) = &event.doc_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("event_for_doc:{}:doc:{}", event.event_id, doc_id),
                        kind: "event_for_doc".to_string(),
                        source_id: event_node_id.clone(),
                        target_id: format!("doc:{}", doc_id),
                        search_text: format!("{} {}", event.r#type, doc_id).to_lowercase(),
                        sort_time: Some(event.ts),
                        payload: json!({ "event_id": event.event_id, "doc_id": doc_id }),
                    },
                );
            }
            if let Some(run_id) = &event.run_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("event_for_run:{}:run:{}", event.event_id, run_id),
                        kind: "event_for_run".to_string(),
                        source_id: event_node_id.clone(),
                        target_id: format!("run:{}", run_id),
                        search_text: format!("{} {}", event.r#type, run_id).to_lowercase(),
                        sort_time: Some(event.ts),
                        payload: json!({ "event_id": event.event_id, "run_id": run_id }),
                    },
                );
            }
            if event.actor_type == "agent" {
                let agent_name = tokens
                    .iter()
                    .find(|token| token.token_id == event.actor_id)
                    .map(|token| token.agent_name.clone())
                    .unwrap_or_else(|| event.actor_id.clone());
                agent_tokens
                    .entry(agent_name.clone())
                    .or_default()
                    .insert(event.actor_id.clone());
                let agent_node_id = format!("agent:{}", graph_key_segment(&agent_name));
                upsert_graph_node(
                    &mut nodes,
                    GraphNodeRecord {
                        node_id: agent_node_id.clone(),
                        kind: "agent".to_string(),
                        ref_id: agent_name.clone(),
                        label: agent_name.clone(),
                        secondary_label: Some("Agent".to_string()),
                        group_key: "agent".to_string(),
                        search_text: format!("{} agent", agent_name).to_lowercase(),
                        sort_time: Some(event.ts),
                        payload: json!({
                            "agent_name": agent_name,
                            "token_ids": agent_tokens
                                .get(&agent_name)
                                .map(|rows| rows.iter().cloned().collect::<Vec<_>>())
                                .unwrap_or_default(),
                        }),
                    },
                );
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("emitted_by_agent:{}:{}", agent_node_id, event_node_id),
                        kind: "emitted_by_agent".to_string(),
                        source_id: agent_node_id.clone(),
                        target_id: event_node_id,
                        search_text: format!("{} {}", agent_name, event.r#type).to_lowercase(),
                        sort_time: Some(event.ts),
                        payload: json!({ "agent_name": agent_name, "event_id": event.event_id }),
                    },
                );
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "event_emitted_by_agent:{}:event:{}",
                            agent_node_id, event.event_id
                        ),
                        kind: "event_emitted_by_agent".to_string(),
                        source_id: agent_node_id,
                        target_id: format!("event:{}", event.event_id),
                        search_text: format!("{} {}", agent_name, event.r#type).to_lowercase(),
                        sort_time: Some(event.ts),
                        payload: json!({
                            "agent_name": agent_name,
                            "event_id": event.event_id,
                            "emitted_kind": "event",
                            "layer": "DETERMINISTIC",
                            "confidence": 1.0,
                        }),
                    },
                );
            }
        }

        for framework in &crafting_frameworks {
            let framework_node_id = format!("framework:{}", framework.framework_id);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: framework_node_id,
                    kind: "framework".to_string(),
                    ref_id: framework.framework_id.clone(),
                    label: framework.name.clone(),
                    secondary_label: Some("Crafted Framework".to_string()),
                    group_key: "framework".to_string(),
                    search_text: format!(
                        "{} {} {} {}",
                        framework.name,
                        framework.custom_instruction,
                        framework.enhancement_version,
                        framework.chain_of_knowledge.focus_mode
                    )
                    .to_lowercase(),
                    sort_time: Some(framework.updated_at),
                    payload: json!({
                        "framework_id": framework.framework_id,
                        "name": framework.name,
                        "custom_instruction": framework.custom_instruction,
                        "enhanced_instruction": framework.enhanced_instruction,
                        "chain_of_thought": framework.chain_of_thought,
                        "chain_of_knowledge": framework.chain_of_knowledge,
                        "enhancement_version": framework.enhancement_version,
                        "updated_at": framework.updated_at,
                    }),
                },
            );
        }

        for pack in &context_packs {
            let context_node_id = format!("context_pack:{}", pack.context_id);
            let scoped_doc = pack.doc_id.as_ref().and_then(|doc_id| doc_map.get(doc_id));
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: context_node_id.clone(),
                    kind: "context_pack".to_string(),
                    ref_id: pack.context_id.clone(),
                    label: format!("Context {}", pack.context_id),
                    secondary_label: Some(pack.brand.clone()),
                    group_key: format!("brand:{}", pack.brand),
                    search_text: format!(
                        "{} {} {} {}",
                        pack.context_id,
                        pack.brand,
                        pack.session_id.clone().unwrap_or_default(),
                        pack.doc_id.clone().unwrap_or_default()
                    )
                    .to_lowercase(),
                    sort_time: Some(pack.created_at),
                    payload: json!({
                        "context_id": pack.context_id,
                        "brand": pack.brand,
                        "session_id": pack.session_id,
                        "doc_id": pack.doc_id,
                        "owner_scope": scoped_doc.map(|doc| doc.owner_scope.clone()),
                        "project_id": scoped_doc.and_then(|doc| doc.project_id.clone()),
                        "project_root": scoped_doc.and_then(|doc| doc.project_root.clone()),
                        "knowledge_kind": scoped_doc.map(|doc| doc.knowledge_kind.clone()),
                        "status": pack.status,
                        "source_hash": pack.source_hash,
                        "token_estimate": pack.token_estimate,
                        "citation_count": pack.citation_count,
                        "unresolved_citation_count": pack.unresolved_citation_count,
                        "previous_context_id": pack.previous_context_id,
                        "manifest_path": pack.manifest_path,
                        "summary_path": pack.summary_path,
                        "created_at": pack.created_at,
                        "superseded_at": pack.superseded_at,
                    }),
                },
            );
            if let Some(doc_id) = &pack.doc_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!("context_pack_doc:{}:doc:{}", pack.context_id, doc_id),
                        kind: "context_pack_doc".to_string(),
                        source_id: context_node_id.clone(),
                        target_id: format!("doc:{}", doc_id),
                        search_text: format!("{} {}", pack.context_id, doc_id).to_lowercase(),
                        sort_time: Some(pack.created_at),
                        payload: json!({ "context_id": pack.context_id, "doc_id": doc_id }),
                    },
                );
            }
            if let Some(sources) = context_sources_by_context.get(&pack.context_id) {
                for source in sources {
                    let target_id = match source.source_kind.as_str() {
                        "doc" => source
                            .source_ref
                            .strip_prefix("doc:")
                            .map(|id| format!("doc:{}", id)),
                        "run" => source
                            .source_ref
                            .strip_prefix("run:")
                            .map(|id| format!("run:{}", id)),
                        "run_artifact" => source
                            .source_ref
                            .strip_prefix("artifact:")
                            .map(|id| format!("artifact:{}", id)),
                        "previous_pack" => source
                            .source_ref
                            .strip_prefix("context:")
                            .map(|id| format!("context_pack:{}", id)),
                        _ => None,
                    };
                    if let Some(target_id) = target_id {
                        upsert_graph_edge(
                            &mut edges,
                            GraphEdgeRecord {
                                edge_id: format!(
                                    "context_pack_contains:{}:{}:{}",
                                    pack.context_id, source.source_kind, source.source_ref
                                ),
                                kind: "context_pack_contains".to_string(),
                                source_id: context_node_id.clone(),
                                target_id,
                                search_text: format!(
                                    "{} {} {}",
                                    pack.context_id, source.source_kind, source.source_ref
                                )
                                .to_lowercase(),
                                sort_time: Some(pack.created_at),
                                payload: json!({
                                    "context_id": pack.context_id,
                                    "source_kind": source.source_kind,
                                    "source_ref": source.source_ref,
                                    "source_path": source.source_path,
                                    "source_rank": source.source_rank,
                                    "source_hash": source.source_hash,
                                    "locator": source.locator_json,
                                    "layer": "DETERMINISTIC",
                                    "confidence": 1.0,
                                }),
                            },
                        );
                    }
                }
            }
            if let Some(previous_context_id) = &pack.previous_context_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "context_pack_previous:{}:context_pack:{}",
                            pack.context_id, previous_context_id
                        ),
                        kind: "context_pack_previous".to_string(),
                        source_id: context_node_id.clone(),
                        target_id: format!("context_pack:{}", previous_context_id),
                        search_text: format!("{} {}", pack.context_id, previous_context_id)
                            .to_lowercase(),
                        sort_time: Some(pack.created_at),
                        payload: json!({
                            "context_id": pack.context_id,
                            "previous_context_id": previous_context_id,
                        }),
                    },
                );
            }
        }

        for event in &agent_context_events {
            let event_node_id = format!("context_event:{}", event.event_id);
            let agent_name = event
                .agent_name
                .clone()
                .unwrap_or_else(|| "unknown-agent".to_string());
            let agent_node_id = format!("agent:{}", graph_key_segment(&agent_name));
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: event_node_id.clone(),
                    kind: "context_event".to_string(),
                    ref_id: event.event_id.clone(),
                    label: event.event_kind.clone(),
                    secondary_label: event.agent_name.clone(),
                    group_key: format!("agent:{}", graph_key_segment(&agent_name)),
                    search_text: format!(
                        "{} {} {} {}",
                        event.event_kind,
                        agent_name,
                        event.context_id.clone().unwrap_or_default(),
                        event.reason.clone().unwrap_or_default()
                    )
                    .to_lowercase(),
                    sort_time: Some(event.created_at),
                    payload: json!({
                        "event_id": event.event_id,
                        "agent_name": event.agent_name,
                        "session_id": event.session_id,
                        "project_id": event.project_id,
                        "event_kind": event.event_kind,
                        "context_id": event.context_id,
                        "node_id": event.node_id,
                        "reason": event.reason,
                        "payload": event.payload_json,
                        "created_at": event.created_at,
                    }),
                },
            );
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: agent_node_id.clone(),
                    kind: "agent".to_string(),
                    ref_id: agent_name.clone(),
                    label: agent_name.clone(),
                    secondary_label: Some("Agent".to_string()),
                    group_key: "agent".to_string(),
                    search_text: format!("{} agent", agent_name).to_lowercase(),
                    sort_time: Some(event.created_at),
                    payload: json!({
                        "agent_name": agent_name.clone(),
                        "token_ids": agent_tokens
                            .get(&agent_name)
                            .map(|rows| rows.iter().cloned().collect::<Vec<_>>())
                            .unwrap_or_default(),
                    }),
                },
            );

            let target_id = event
                .node_id
                .clone()
                .or_else(|| {
                    event
                        .context_id
                        .as_ref()
                        .map(|id| format!("context_pack:{}", id))
                })
                .unwrap_or_else(|| event_node_id.clone());
            upsert_graph_edge(
                &mut edges,
                GraphEdgeRecord {
                    edge_id: format!("{}:{}:{}", event.event_kind, agent_node_id, target_id),
                    kind: event.event_kind.clone(),
                    source_id: agent_node_id,
                    target_id,
                    search_text: format!(
                        "{} {} {}",
                        event.event_kind,
                        event.agent_name.clone().unwrap_or_default(),
                        event.reason.clone().unwrap_or_default()
                    )
                    .to_lowercase(),
                    sort_time: Some(event.created_at),
                    payload: json!({
                        "event_id": event.event_id,
                        "context_id": event.context_id,
                        "node_id": event.node_id,
                        "reason": event.reason,
                        "layer": "DETERMINISTIC",
                        "confidence": 1.0,
                    }),
                },
            );
        }

        for craftship in &craftships {
            let craftship_node_id = format!("craftship:{}", craftship.craftship_id);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: craftship_node_id.clone(),
                    kind: "craftship".to_string(),
                    ref_id: craftship.craftship_id.clone(),
                    label: craftship.name.clone(),
                    secondary_label: Some(craftship.mode.clone()),
                    group_key: "craftship".to_string(),
                    search_text: format!(
                        "{} {} {}",
                        craftship.name, craftship.necessity, craftship.mode
                    )
                    .to_lowercase(),
                    sort_time: Some(craftship.updated_at),
                    payload: json!({
                        "craftship_id": craftship.craftship_id,
                        "name": craftship.name,
                        "necessity": craftship.necessity,
                        "mode": craftship.mode,
                        "archived": craftship.archived,
                        "created_at": craftship.created_at,
                        "updated_at": craftship.updated_at,
                    }),
                },
            );

            if let Some(craftship_nodes) = craftship_nodes_by_craftship.get(&craftship.craftship_id)
            {
                for node in craftship_nodes {
                    if let Some(framework_id) = &node.framework_id {
                        upsert_graph_edge(
                            &mut edges,
                            GraphEdgeRecord {
                                edge_id: format!(
                                    "craftship_framework:{}:{}",
                                    craftship.craftship_id, node.node_id
                                ),
                                kind: "craftship_framework".to_string(),
                                source_id: craftship_node_id.clone(),
                                target_id: format!("framework:{}", framework_id),
                                search_text: format!(
                                    "{} {} {}",
                                    craftship.name, node.label, framework_id
                                )
                                .to_lowercase(),
                                sort_time: Some(craftship.updated_at),
                                payload: json!({
                                    "craftship_id": craftship.craftship_id,
                                    "node_id": node.node_id,
                                    "node_label": node.label,
                                    "framework_id": framework_id,
                                }),
                            },
                        );
                    }
                }
            }
        }

        for session in &craftship_sessions {
            let session_node_id = format!("craftship_session:{}", session.craftship_session_id);
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: session_node_id.clone(),
                    kind: "craftship_session".to_string(),
                    ref_id: session.craftship_session_id.clone(),
                    label: session.name.clone(),
                    secondary_label: Some(session.status.clone()),
                    group_key: format!("craftship:{}", session.craftship_id),
                    search_text: format!(
                        "{} {} {} {}",
                        session.name, session.status, session.runtime_brand, session.craftship_id
                    )
                    .to_lowercase(),
                    sort_time: Some(session.updated_at),
                    payload: json!({
                        "craftship_session_id": session.craftship_session_id,
                        "craftship_id": session.craftship_id,
                        "name": session.name,
                        "status": session.status,
                        "launch_mode": session.launch_mode,
                        "runtime_brand": session.runtime_brand,
                        "doc_id": session.doc_id,
                        "source_doc_id": session.source_doc_id,
                        "last_context_pack_id": session.last_context_pack_id,
                        "created_at": session.created_at,
                        "updated_at": session.updated_at,
                    }),
                },
            );
            upsert_graph_edge(
                &mut edges,
                GraphEdgeRecord {
                    edge_id: format!(
                        "craftship_session_template:{}:{}",
                        session.craftship_session_id, session.craftship_id
                    ),
                    kind: "craftship_session_template".to_string(),
                    source_id: session_node_id.clone(),
                    target_id: format!("craftship:{}", session.craftship_id),
                    search_text: format!("{} {}", session.name, session.craftship_id)
                        .to_lowercase(),
                    sort_time: Some(session.updated_at),
                    payload: json!({
                        "craftship_session_id": session.craftship_session_id,
                        "craftship_id": session.craftship_id,
                    }),
                },
            );
            if let Some(doc_id) = &session.doc_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "craftship_session_doc:{}:doc:{}",
                            session.craftship_session_id, doc_id
                        ),
                        kind: "craftship_session_doc".to_string(),
                        source_id: session_node_id.clone(),
                        target_id: format!("doc:{}", doc_id),
                        search_text: format!("{} {}", session.name, doc_id).to_lowercase(),
                        sort_time: Some(session.updated_at),
                        payload: json!({
                            "craftship_session_id": session.craftship_session_id,
                            "doc_id": doc_id,
                        }),
                    },
                );
            }
            if let Some(source_doc_id) = &session.source_doc_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "craftship_session_source_doc:{}:doc:{}",
                            session.craftship_session_id, source_doc_id
                        ),
                        kind: "craftship_session_source_doc".to_string(),
                        source_id: session_node_id.clone(),
                        target_id: format!("doc:{}", source_doc_id),
                        search_text: format!("{} {}", session.name, source_doc_id).to_lowercase(),
                        sort_time: Some(session.updated_at),
                        payload: json!({
                            "craftship_session_id": session.craftship_session_id,
                            "source_doc_id": source_doc_id,
                        }),
                    },
                );
            }
            if let Some(context_id) = &session.last_context_pack_id {
                upsert_graph_edge(
                    &mut edges,
                    GraphEdgeRecord {
                        edge_id: format!(
                            "craftship_session_context:{}:context_pack:{}",
                            session.craftship_session_id, context_id
                        ),
                        kind: "craftship_session_context".to_string(),
                        source_id: session_node_id.clone(),
                        target_id: format!("context_pack:{}", context_id),
                        search_text: format!("{} {}", session.name, context_id).to_lowercase(),
                        sort_time: Some(session.updated_at),
                        payload: json!({
                            "craftship_session_id": session.craftship_session_id,
                            "context_id": context_id,
                        }),
                    },
                );
            }

            if let Some(session_nodes) =
                craftship_session_nodes_by_session.get(&session.craftship_session_id)
            {
                for node in session_nodes {
                    let session_child_node_id =
                        format!("craftship_session_node:{}", node.session_node_id);
                    upsert_graph_node(
                        &mut nodes,
                        GraphNodeRecord {
                            node_id: session_child_node_id.clone(),
                            kind: "craftship_session_node".to_string(),
                            ref_id: node.session_node_id.clone(),
                            label: node.label.clone(),
                            secondary_label: Some(node.status.clone()),
                            group_key: format!("craftship_session:{}", node.craftship_session_id),
                            search_text: format!(
                                "{} {} {}",
                                node.label,
                                node.status,
                                node.framework_id.clone().unwrap_or_default()
                            )
                            .to_lowercase(),
                            sort_time: Some(node.updated_at),
                            payload: json!({
                                "session_node_id": node.session_node_id,
                                "craftship_session_id": node.craftship_session_id,
                                "template_node_id": node.template_node_id,
                                "parent_session_node_id": node.parent_session_node_id,
                                "label": node.label,
                                "framework_id": node.framework_id,
                                "terminal_ref": node.terminal_ref,
                                "run_id": node.run_id,
                                "status": node.status,
                                "sort_order": node.sort_order,
                                "created_at": node.created_at,
                                "updated_at": node.updated_at,
                            }),
                        },
                    );
                    upsert_graph_edge(
                        &mut edges,
                        GraphEdgeRecord {
                            edge_id: format!(
                                "craftship_session_has_node:{}:{}",
                                session.craftship_session_id, node.session_node_id
                            ),
                            kind: "craftship_session_has_node".to_string(),
                            source_id: session_node_id.clone(),
                            target_id: session_child_node_id.clone(),
                            search_text: format!("{} {}", session.name, node.label).to_lowercase(),
                            sort_time: Some(node.updated_at),
                            payload: json!({
                                "craftship_session_id": session.craftship_session_id,
                                "session_node_id": node.session_node_id,
                            }),
                        },
                    );
                    if let Some(parent_session_node_id) = &node.parent_session_node_id {
                        upsert_graph_edge(
                            &mut edges,
                            GraphEdgeRecord {
                                edge_id: format!(
                                    "craftship_session_node_parent:{}:{}",
                                    node.session_node_id, parent_session_node_id
                                ),
                                kind: "craftship_session_node_parent".to_string(),
                                source_id: session_child_node_id.clone(),
                                target_id: format!(
                                    "craftship_session_node:{}",
                                    parent_session_node_id
                                ),
                                search_text: format!("{} {}", node.label, parent_session_node_id)
                                    .to_lowercase(),
                                sort_time: Some(node.updated_at),
                                payload: json!({
                                    "session_node_id": node.session_node_id,
                                    "parent_session_node_id": parent_session_node_id,
                                }),
                            },
                        );
                    }
                    if let Some(framework_id) = &node.framework_id {
                        upsert_graph_edge(
                            &mut edges,
                            GraphEdgeRecord {
                                edge_id: format!(
                                    "craftship_session_node_framework:{}:{}",
                                    node.session_node_id, framework_id
                                ),
                                kind: "craftship_session_node_framework".to_string(),
                                source_id: session_child_node_id.clone(),
                                target_id: format!("framework:{}", framework_id),
                                search_text: format!("{} {}", node.label, framework_id)
                                    .to_lowercase(),
                                sort_time: Some(node.updated_at),
                                payload: json!({
                                    "session_node_id": node.session_node_id,
                                    "framework_id": framework_id,
                                }),
                            },
                        );
                    }
                    if let Some(run_id) = &node.run_id {
                        upsert_graph_edge(
                            &mut edges,
                            GraphEdgeRecord {
                                edge_id: format!(
                                    "craftship_session_node_run:{}:run:{}",
                                    node.session_node_id, run_id
                                ),
                                kind: "craftship_session_node_run".to_string(),
                                source_id: session_child_node_id,
                                target_id: format!("run:{}", run_id),
                                search_text: format!("{} {}", node.label, run_id).to_lowercase(),
                                sort_time: Some(node.updated_at),
                                payload: json!({
                                    "session_node_id": node.session_node_id,
                                    "run_id": run_id,
                                }),
                            },
                        );
                    }
                }
            }
        }

        for (agent_name, token_ids) in agent_tokens {
            let agent_node_id = format!("agent:{}", graph_key_segment(&agent_name));
            upsert_graph_node(
                &mut nodes,
                GraphNodeRecord {
                    node_id: agent_node_id,
                    kind: "agent".to_string(),
                    ref_id: agent_name.clone(),
                    label: agent_name.clone(),
                    secondary_label: Some("Agent".to_string()),
                    group_key: "agent".to_string(),
                    search_text: format!("{} agent", agent_name).to_lowercase(),
                    sort_time: None,
                    payload: json!({
                        "agent_name": agent_name,
                        "token_ids": token_ids.into_iter().collect::<Vec<_>>(),
                    }),
                },
            );
        }

        Ok((
            nodes.into_values().collect::<Vec<_>>(),
            edges.into_values().collect::<Vec<_>>(),
        ))
    }

    pub fn audit_tail(&self, since: Option<&str>, limit: usize) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let rows = db::tail_audit(&conn, since, limit)?;
        Ok(json!({ "entries": rows }))
    }

    pub fn events_tail(&self, after_event_id: Option<i64>, limit: usize) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let rows = db::tail_events(&conn, after_event_id, limit)?;
        Ok(json!({ "events": rows }))
    }

    pub fn events_latest(&self, limit: usize) -> Result<Value, BtError> {
        let conn = self.open_conn()?;
        let rows = db::list_events_latest(&conn, limit)?;
        Ok(json!({ "events": rows }))
    }

    pub fn events_subscribe(&self, filters: Value) -> Result<Value, BtError> {
        // NOTE: This is currently a handshake-only subscription descriptor.
        // Reliable consumption should use `events.tail` with a persisted cursor.
        Ok(json!({
            "subscription_id": format!("sub_{}", Uuid::new_v4().simple()),
            "filters": filters,
            "event_method": "event.notify",
            "tail_method": "events.tail",
            "cursor_field": "afterEventId"
        }))
    }

    pub fn auth_agent_validate(&self, raw_token: &str) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let mut cfg = config::load_config(&root)?;
        let token = config::authenticate_token(&mut cfg, raw_token)?;
        config::save_config(&root, &cfg)?;

        Ok(json!({
            "token_id": token.token_id,
            "agent_name": token.agent_name,
            "caps": token.caps,
        }))
    }

    pub fn token_create(&self, agent_name: &str, caps: Vec<String>) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let mut cfg = config::load_config(&root)?;
        let (raw, token) = config::create_token(&mut cfg, agent_name, caps);
        config::save_config(&root, &cfg)?;
        // Debounced: token_create is on the craftship launch hot path
        // (called per-node). The unconditional O(vault) rebuild was
        // causing `bt-core RPC timeout for token.create`.
        self.maybe_refresh_graph_projection()?;
        Ok(json!({
            "token": raw,
            "token_id": token.token_id,
            "agent_name": token.agent_name,
            "caps": token.caps,
        }))
    }

    pub fn token_rotate(&self, token_id: &str) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let mut cfg = config::load_config(&root)?;
        let (raw, token) = config::rotate_token(&mut cfg, token_id)?;
        config::save_config(&root, &cfg)?;
        self.maybe_refresh_graph_projection()?;
        Ok(json!({
            "token": raw,
            "token_id": token.token_id,
        }))
    }

    pub fn token_revoke(&self, token_id: &str) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let mut cfg = config::load_config(&root)?;
        config::revoke_token(&mut cfg, token_id)?;
        config::save_config(&root, &cfg)?;
        self.maybe_refresh_graph_projection()?;
        Ok(json!({ "token_id": token_id, "revoked": true }))
    }

    pub fn token_list(&self) -> Result<Value, BtError> {
        let root = self.require_vault()?;
        let cfg = config::load_config(&root)?;
        let tokens = cfg
            .tokens
            .into_iter()
            .map(|t| {
                json!({
                    "token_id": t.token_id,
                    "agent_name": t.agent_name,
                    "caps": t.caps,
                    "created_at": t.created_at,
                    "last_used_at": t.last_used_at,
                    "revoked": t.revoked,
                })
            })
            .collect::<Vec<_>>();

        Ok(json!({ "tokens": tokens }))
    }

    fn sync_task_markdown_files(&self, actor: &Actor) -> Result<(), BtError> {
        self.apply_write(actor, WriteOperation::UpdateTasksMirror)?;
        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        let tasks = db::list_tasks(&conn, None, None, None, None, true, 1000)?;
        let active_and_queued = tasks
            .iter()
            .filter(|task| task.queue_lane == "active" || task.queue_lane == "queued")
            .collect::<Vec<_>>();
        let archived = tasks
            .iter()
            .filter(|task| task.queue_lane == "archived")
            .collect::<Vec<_>>();

        let mut tasks_out = String::from("# Tasks\n\n## Active\n\n");
        let active_tasks = active_and_queued
            .iter()
            .filter(|task| task.queue_lane == "active")
            .collect::<Vec<_>>();
        if active_tasks.is_empty() {
            tasks_out.push_str("_No active tasks._\n");
        } else {
            for task in active_tasks {
                tasks_out.push_str(&format_task_markdown(task));
                tasks_out.push('\n');
            }
        }

        tasks_out.push_str("\n## Queued\n\n");
        let queued_tasks = active_and_queued
            .iter()
            .filter(|task| task.queue_lane == "queued")
            .collect::<Vec<_>>();
        if queued_tasks.is_empty() {
            tasks_out.push_str("_No queued tasks._\n");
        } else {
            for task in queued_tasks {
                tasks_out.push_str(&format_task_markdown(task));
                tasks_out.push('\n');
            }
        }

        let tasks_path = fs_guard::safe_join(&root, Path::new("tasks.md"))?;
        fs_guard::atomic_write(&root, &tasks_path, &tasks_out)?;

        let mut archive_out = String::from("# Task Archive\n\n");
        if archived.is_empty() {
            archive_out.push_str("_No archived tasks._\n");
        } else {
            for task in archived {
                archive_out.push_str(&format_archived_task_markdown(task));
                archive_out.push('\n');
            }
        }

        let archive_path = fs_guard::safe_join(&root, Path::new("task_archive.md"))?;
        fs_guard::atomic_write(&root, &archive_path, &archive_out)?;
        Ok(())
    }

    fn build_planned_task(
        &self,
        doc: &DocRecord,
        entry: DomeTaskPlanEntry,
        queue_lane: &str,
        created_at: DateTime<Utc>,
    ) -> Task {
        Task {
            id: format!("tsk_{}", Uuid::new_v4().simple()),
            title: entry.title.trim().to_string(),
            status: "open".to_string(),
            priority: entry
                .priority
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty()),
            due_at: None,
            topic: Some(doc.topic.clone()),
            doc_id: Some(doc.id.clone()),
            created_at,
            updated_at: Some(created_at),
            completed_at: None,
            earliest_start_at: None,
            snooze_until: None,
            lease_owner: None,
            lease_expires_at: None,
            queue_lane: queue_lane.to_string(),
            queue_order: Some(entry.order),
            success_criteria: entry
                .success_criteria
                .into_iter()
                .map(|item| item.trim().to_string())
                .filter(|item| !item.is_empty())
                .collect(),
            verification_hint: entry
                .verification_hint
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty()),
            verification_summary: None,
            archived_at: None,
            merged_into_task_id: None,
            verified_by_run_id: None,
        }
    }

    fn normalize_brand_id(value: &str) -> String {
        value
            .trim()
            .to_ascii_lowercase()
            .chars()
            .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '_' })
            .collect::<String>()
            .trim_matches('_')
            .to_string()
    }

    fn file_modified_at(path: &Path) -> Option<DateTime<Utc>> {
        fs::metadata(path)
            .ok()
            .and_then(|meta| meta.modified().ok())
            .map(DateTime::<Utc>::from)
    }

    fn planning_status_for_doc(&self, root: &Path, doc: &DocRecord) -> Result<Value, BtError> {
        let user_path = fs_guard::safe_join(root, Path::new(&doc.user_path))?;
        let agent_path = fs_guard::safe_join(root, Path::new(&doc.agent_path))?;
        let agent_content = fs::read_to_string(&agent_path).unwrap_or_default();

        let user_updated_at = Self::file_modified_at(&user_path).unwrap_or(doc.updated_at);
        let agent_updated_at = Self::file_modified_at(&agent_path).unwrap_or(doc.updated_at);

        let (state, reason, has_agent_plan, error_detail) =
            match parse_dome_task_plan(&agent_content) {
                Ok(Some(_)) if user_updated_at > agent_updated_at => {
                    ("needs_plan", "user_note_newer_than_agent_plan", true, None)
                }
                Ok(Some(_)) => ("ready", "fresh_agent_plan", true, None),
                Ok(None) => ("needs_plan", "missing_agent_plan", false, None),
                Err(err) => (
                    "needs_plan",
                    "invalid_agent_plan",
                    false,
                    Some(err.to_string()),
                ),
            };

        Ok(json!({
            "state": state,
            "reason": reason,
            "has_agent_plan": has_agent_plan,
            "user_updated_at": user_updated_at,
            "agent_updated_at": agent_updated_at,
            "error_detail": error_detail,
        }))
    }

    fn append_context_doc_sources(
        &self,
        conn: &rusqlite::Connection,
        root: &Path,
        target_doc_id: &str,
        sources: &mut Vec<ContextSourceItem>,
        seen: &mut HashSet<String>,
        rank: &mut i64,
        resolved_doc_ids: &mut BTreeSet<String>,
    ) -> Result<(), BtError> {
        let Some(doc) = db::get_doc(conn, target_doc_id)? else {
            return Ok(());
        };
        resolved_doc_ids.insert(doc.id.clone());

        let mut push = |source: ContextSourceItem| {
            if seen.insert(source.source_ref.clone()) {
                sources.push(source);
            }
        };

        let user_path = fs_guard::safe_join(root, Path::new(&doc.user_path))?;
        if user_path.exists() {
            *rank += 1;
            let body = fs::read_to_string(&user_path)?;
            push(ContextSourceItem {
                source_kind: "doc_user".to_string(),
                source_ref: format!("doc:{}:user", doc.id),
                source_path: Some(doc.user_path.clone()),
                title: format!("User note for {}", doc.title),
                body: body.clone(),
                hash: Self::sha(&body),
                rank: *rank,
                locator_json: json!({
                    "doc_id": doc.id,
                    "scope": "user",
                    "topic": doc.topic,
                    "slug": doc.slug,
                    "title": doc.title,
                }),
            });
        }

        let agent_path = fs_guard::safe_join(root, Path::new(&doc.agent_path))?;
        if agent_path.exists() {
            *rank += 1;
            let body = fs::read_to_string(&agent_path)?;
            push(ContextSourceItem {
                source_kind: "doc_agent".to_string(),
                source_ref: format!("doc:{}:agent", doc.id),
                source_path: Some(doc.agent_path.clone()),
                title: format!("Agent note for {}", doc.title),
                body: body.clone(),
                hash: Self::sha(&body),
                rank: *rank,
                locator_json: json!({
                    "doc_id": doc.id,
                    "scope": "agent",
                    "topic": doc.topic,
                    "slug": doc.slug,
                    "title": doc.title,
                }),
            });
        }

        if let Some(meta) = self.load_meta_by_doc(&doc.id)? {
            *rank += 1;
            let body = serde_json::to_string_pretty(&meta)
                .map_err(|e| BtError::Validation(e.to_string()))?;
            push(ContextSourceItem {
                source_kind: "doc_meta".to_string(),
                source_ref: format!("doc:{}:meta", doc.id),
                source_path: Some(format!("topics/{}/{}/meta.json", doc.topic, doc.slug)),
                title: format!("Metadata for {}", doc.title),
                body: body.clone(),
                hash: Self::sha(&body),
                rank: *rank,
                locator_json: json!({
                    "doc_id": doc.id,
                    "tags": meta.tags,
                    "links_out": meta.links_out,
                    "status": meta.status,
                }),
            });
        }

        Ok(())
    }

    fn push_context_source(
        sources: &mut Vec<ContextSourceItem>,
        seen: &mut HashSet<String>,
        source: ContextSourceItem,
    ) {
        if seen.insert(source.source_ref.clone()) {
            sources.push(source);
        }
    }

    fn collect_context_sources(
        &self,
        conn: &rusqlite::Connection,
        session_id: Option<&str>,
        doc_id: Option<&str>,
    ) -> Result<(Vec<ContextSourceItem>, Option<String>), BtError> {
        let root = self.require_vault()?;
        let mut sources = Vec::new();
        let mut seen = HashSet::new();
        let mut rank = 0_i64;
        let mut resolved_doc_ids = BTreeSet::new();

        if let Some(doc_id) = doc_id {
            self.append_context_doc_sources(
                conn,
                &root,
                doc_id,
                &mut sources,
                &mut seen,
                &mut rank,
                &mut resolved_doc_ids,
            )?;
        }

        let filtered_runs = db::list_runs(conn, None, 30)?
            .into_iter()
            .filter(|run| {
                let session_match = session_id.map(|value| {
                    run.agent_session_id.as_deref() == Some(value)
                        || run.openclaw_session_id.as_deref() == Some(value)
                        || run.craftship_session_id.as_deref() == Some(value)
                        || run.craftship_session_node_id.as_deref() == Some(value)
                });
                let doc_match = doc_id.map(|value| run.doc_id.as_deref() == Some(value));

                session_match.unwrap_or(false)
                    || doc_match.unwrap_or(false)
                    || (session_id.is_none() && doc_id.is_some() && run.doc_id.as_deref() == doc_id)
            })
            .take(20)
            .collect::<Vec<_>>();

        for run in filtered_runs {
            if let Some(run_doc_id) = &run.doc_id {
                resolved_doc_ids.insert(run_doc_id.clone());
            }

            rank += 1;
            let body = format!(
                "Summary: {}\nStatus: {}\nSource: {}\nStarted: {}\nEnded: {}\nError: {}\nSession: {}\n",
                run.summary,
                run.status,
                run.source,
                run.started_at.map(|row| row.to_rfc3339()).unwrap_or_default(),
                run.ended_at.map(|row| row.to_rfc3339()).unwrap_or_default(),
                run.error_message.clone().unwrap_or_default(),
                run.agent_session_id
                    .clone()
                    .or(run.openclaw_session_id.clone())
                    .unwrap_or_default(),
            );
            Self::push_context_source(
                &mut sources,
                &mut seen,
                ContextSourceItem {
                    source_kind: "run".to_string(),
                    source_ref: format!("run:{}", run.id),
                    source_path: None,
                    title: format!("Run {}", run.id),
                    body: body.clone(),
                    hash: Self::sha(&body),
                    rank,
                    locator_json: json!({
                        "run_id": run.id,
                        "status": run.status,
                        "source": run.source,
                        "doc_id": run.doc_id,
                        "agent_brand": run.agent_brand,
                        "agent_name": run.agent_name,
                        "agent_session_id": run.agent_session_id,
                        "craftship_session_id": run.craftship_session_id,
                        "craftship_session_node_id": run.craftship_session_node_id,
                    }),
                },
            );

            for artifact in db::list_run_artifacts(conn, &run.id)?.into_iter().take(4) {
                let text = if let Some(content_inline) = artifact.content_inline.clone() {
                    Some(content_inline)
                } else if let Some(path) = artifact.path.clone() {
                    let full_path = fs_guard::safe_join(&root, Path::new(&path))?;
                    if full_path.exists() {
                        Some(fs::read_to_string(full_path)?)
                    } else {
                        None
                    }
                } else {
                    None
                };
                let Some(text) = text else {
                    continue;
                };
                rank += 1;
                Self::push_context_source(
                    &mut sources,
                    &mut seen,
                    ContextSourceItem {
                        source_kind: "run_artifact".to_string(),
                        source_ref: format!("artifact:{}", artifact.id),
                        source_path: artifact.path.clone(),
                        title: format!("Artifact {} for run {}", artifact.kind, run.id),
                        body: text.clone(),
                        hash: Self::sha(&text),
                        rank,
                        locator_json: json!({
                            "artifact_id": artifact.id,
                            "run_id": run.id,
                            "kind": artifact.kind,
                            "craftship_session_id": run.craftship_session_id,
                            "craftship_session_node_id": run.craftship_session_node_id,
                        }),
                    },
                );
            }
        }

        if doc_id.is_none() && resolved_doc_ids.len() == 1 {
            if let Some(resolved) = resolved_doc_ids.iter().next().cloned() {
                self.append_context_doc_sources(
                    conn,
                    &root,
                    &resolved,
                    &mut sources,
                    &mut seen,
                    &mut rank,
                    &mut resolved_doc_ids,
                )?;
            }
        }

        for resolved_doc_id in &resolved_doc_ids {
            let links = db::graph_links(conn, resolved_doc_id)?;
            if links.is_empty() {
                continue;
            }
            rank += 1;
            let body = links
                .iter()
                .map(|row| {
                    format!(
                        "- {} [{}]",
                        row.get("to").and_then(Value::as_str).unwrap_or(""),
                        row.get("kind").and_then(Value::as_str).unwrap_or("link")
                    )
                })
                .collect::<Vec<_>>()
                .join("\n");
            Self::push_context_source(
                &mut sources,
                &mut seen,
                ContextSourceItem {
                    source_kind: "graph_context".to_string(),
                    source_ref: format!("graph:doc:{}", resolved_doc_id),
                    source_path: None,
                    title: format!("Graph context for doc {}", resolved_doc_id),
                    body: format!("# Touched Files And Docs\n\n{}", body),
                    hash: Self::sha(&body),
                    rank,
                    locator_json: json!({
                        "doc_id": resolved_doc_id,
                        "links": links,
                    }),
                },
            );
        }

        let task_doc_filter = if doc_id.is_some() {
            doc_id.map(ToOwned::to_owned)
        } else if resolved_doc_ids.len() == 1 {
            resolved_doc_ids.iter().next().cloned()
        } else {
            None
        };
        let tasks = db::list_tasks(
            conn,
            None,
            None,
            task_doc_filter.as_deref(),
            None,
            false,
            20,
        )?;
        for task in tasks {
            rank += 1;
            let body = format!(
                "Title: {}\nStatus: {}\nQueue lane: {}\nPriority: {}\nDue: {}\nSuccess criteria: {}\nVerification hint: {}\n",
                task.title,
                task.status,
                task.queue_lane,
                task.priority.clone().unwrap_or_default(),
                task.due_at.map(|row| row.to_rfc3339()).unwrap_or_default(),
                task.success_criteria.join(" | "),
                task.verification_hint.clone().unwrap_or_default(),
            );
            Self::push_context_source(
                &mut sources,
                &mut seen,
                ContextSourceItem {
                    source_kind: "task".to_string(),
                    source_ref: format!("task:{}", task.id),
                    source_path: Some("tasks.md".to_string()),
                    title: task.title.clone(),
                    body: body.clone(),
                    hash: Self::sha(&body),
                    rank,
                    locator_json: json!({
                        "task_id": task.id,
                        "status": task.status,
                        "queue_lane": task.queue_lane,
                        "doc_id": task.doc_id,
                    }),
                },
            );
        }

        let resolved_doc_id = doc_id.map(ToOwned::to_owned).or_else(|| {
            if resolved_doc_ids.len() == 1 {
                resolved_doc_ids.iter().next().cloned()
            } else {
                None
            }
        });

        Ok((sources, resolved_doc_id))
    }

    fn build_structured_context_summary(
        &self,
        sources: &[ContextSourceItem],
        doc_id: Option<&str>,
    ) -> Result<(Value, usize), BtError> {
        let mut goals = Vec::new();
        let mut decisions = Vec::new();
        let mut constraints = Vec::new();
        let mut open_questions = Vec::new();
        let mut touched_files_docs = Vec::new();
        let mut commands_checks = Vec::new();
        let mut failures = Vec::new();
        let mut next_actions = Vec::new();

        let mut seen_goals = HashSet::new();
        let mut seen_decisions = HashSet::new();
        let mut seen_constraints = HashSet::new();
        let mut seen_questions = HashSet::new();
        let mut seen_touched = HashSet::new();
        let mut seen_commands = HashSet::new();
        let mut seen_failures = HashSet::new();
        let mut seen_next = HashSet::new();
        let source_refs = sources
            .iter()
            .map(|row| row.source_ref.clone())
            .collect::<HashSet<_>>();

        for source in sources {
            for item in Self::extract_heading_bullets(&source.body, &["goal", "goals"]) {
                Self::push_context_statement(&mut goals, &mut seen_goals, item, &source.source_ref);
            }
            for item in Self::extract_prefixed_statements(&source.body, &["Goal:"]) {
                Self::push_context_statement(&mut goals, &mut seen_goals, item, &source.source_ref);
            }
            for item in Self::extract_heading_bullets(&source.body, &["decision", "decisions"]) {
                Self::push_context_statement(
                    &mut decisions,
                    &mut seen_decisions,
                    item,
                    &source.source_ref,
                );
            }
            for item in Self::extract_prefixed_statements(&source.body, &["Decision:"]) {
                Self::push_context_statement(
                    &mut decisions,
                    &mut seen_decisions,
                    item,
                    &source.source_ref,
                );
            }
            for item in Self::extract_heading_bullets(&source.body, &["constraint", "constraints"])
            {
                Self::push_context_statement(
                    &mut constraints,
                    &mut seen_constraints,
                    item,
                    &source.source_ref,
                );
            }
            for item in Self::extract_prefixed_statements(&source.body, &["Constraint:"]) {
                Self::push_context_statement(
                    &mut constraints,
                    &mut seen_constraints,
                    item,
                    &source.source_ref,
                );
            }
            for item in Self::extract_heading_bullets(
                &source.body,
                &["open questions", "questions", "question"],
            ) {
                Self::push_context_statement(
                    &mut open_questions,
                    &mut seen_questions,
                    item,
                    &source.source_ref,
                );
            }
            for item in Self::extract_prefixed_statements(&source.body, &["Question:"]) {
                Self::push_context_statement(
                    &mut open_questions,
                    &mut seen_questions,
                    item,
                    &source.source_ref,
                );
            }
            for item in Self::extract_heading_bullets(
                &source.body,
                &["next actions", "next action", "todo", "todos", "actions"],
            ) {
                Self::push_context_statement(
                    &mut next_actions,
                    &mut seen_next,
                    item,
                    &source.source_ref,
                );
            }
            for item in Self::extract_prefixed_statements(&source.body, &["Next:", "TODO:"]) {
                Self::push_context_statement(
                    &mut next_actions,
                    &mut seen_next,
                    item,
                    &source.source_ref,
                );
            }

            if let Some(path) = &source.source_path {
                Self::push_context_statement(
                    &mut touched_files_docs,
                    &mut seen_touched,
                    path.clone(),
                    &source.source_ref,
                );
            }
            if let Some(links_out) = source
                .locator_json
                .get("links_out")
                .and_then(Value::as_array)
            {
                for link in links_out.iter().filter_map(Value::as_str) {
                    Self::push_context_statement(
                        &mut touched_files_docs,
                        &mut seen_touched,
                        link.to_string(),
                        &source.source_ref,
                    );
                }
            }

            if source.source_kind == "task" {
                Self::push_context_statement(
                    &mut next_actions,
                    &mut seen_next,
                    source.title.clone(),
                    &source.source_ref,
                );
                if source
                    .locator_json
                    .get("queue_lane")
                    .and_then(Value::as_str)
                    == Some("active")
                {
                    Self::push_context_statement(
                        &mut goals,
                        &mut seen_goals,
                        source.title.clone(),
                        &source.source_ref,
                    );
                }
            }

            if source.source_kind == "run" {
                let status = source
                    .locator_json
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                Self::push_context_statement(
                    &mut commands_checks,
                    &mut seen_commands,
                    format!("{} [{}]", source.title, status),
                    &source.source_ref,
                );
                if matches!(status, "failed" | "canceled") {
                    Self::push_context_statement(
                        &mut failures,
                        &mut seen_failures,
                        source.title.clone(),
                        &source.source_ref,
                    );
                }
            }

            if source.source_kind == "run_artifact"
                && source.locator_json.get("kind").and_then(Value::as_str) == Some("stderr")
                && !source.body.trim().is_empty()
            {
                Self::push_context_statement(
                    &mut failures,
                    &mut seen_failures,
                    format!("stderr captured for {}", source.title),
                    &source.source_ref,
                );
            }
        }

        if goals.is_empty() {
            if let Some(doc_id) = doc_id {
                let fallback_citation = format!("doc:{}:agent", doc_id);
                if source_refs.contains(&fallback_citation) {
                    Self::push_context_statement(
                        &mut goals,
                        &mut seen_goals,
                        format!("Continue work for doc {}", doc_id),
                        &fallback_citation,
                    );
                }
            }
        }

        let summary = json!({
            "goals": Self::statements_to_values(&goals),
            "decisions": Self::statements_to_values(&decisions),
            "constraints": Self::statements_to_values(&constraints),
            "open_questions": Self::statements_to_values(&open_questions),
            "touched_files_docs": Self::statements_to_values(&touched_files_docs),
            "commands_checks_run": Self::statements_to_values(&commands_checks),
            "failures": Self::statements_to_values(&failures),
            "next_actions": Self::statements_to_values(&next_actions),
        });
        let citation_count = [
            &goals,
            &decisions,
            &constraints,
            &open_questions,
            &touched_files_docs,
            &commands_checks,
            &failures,
            &next_actions,
        ]
        .into_iter()
        .flat_map(|rows| rows.iter())
        .map(|row| row.citations.len())
        .sum();

        Ok((summary, citation_count))
    }

    fn build_context_summary_markdown(
        &self,
        context_id: &str,
        brand: &str,
        session_id: Option<&str>,
        doc_id: Option<&str>,
        structured_summary: &Value,
        sources: &[ContextSourceItem],
    ) -> String {
        let mut out = Vec::new();
        out.push(format!("# Context Pack {}\n", context_id));
        out.push(format!("- Brand: `{}`", brand));
        if let Some(session_id) = session_id {
            out.push(format!("- Session: `{}`", session_id));
        }
        if let Some(doc_id) = doc_id {
            out.push(format!("- Doc: `{}`", doc_id));
        }

        for (title, key) in [
            ("Goals", "goals"),
            ("Decisions", "decisions"),
            ("Constraints", "constraints"),
            ("Open Questions", "open_questions"),
            ("Touched Files And Docs", "touched_files_docs"),
            ("Commands And Checks", "commands_checks_run"),
            ("Failures", "failures"),
            ("Next Actions", "next_actions"),
        ] {
            out.push(format!("\n## {}\n", title));
            let rows = structured_summary
                .get(key)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if rows.is_empty() {
                out.push("- None captured.".to_string());
                continue;
            }
            for row in rows {
                let text = row.get("text").and_then(Value::as_str).unwrap_or("");
                let citations = row
                    .get("citations")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join(", ")
                    })
                    .unwrap_or_default();
                out.push(format!("- {} [{}]", text, citations));
            }
        }

        out.push("\n## Sources\n".to_string());
        for source in sources {
            out.push(format!(
                "- `{}`: {}",
                source.source_ref,
                source
                    .source_path
                    .clone()
                    .unwrap_or_else(|| source.title.clone())
            ));
        }

        out.join("\n")
    }

    fn build_context_brand_view(
        &self,
        brand: &str,
        context_id: &str,
        summary_markdown: &str,
    ) -> String {
        format!(
            "# {} View\n\nRead `{}` first. Then use this compact context. Expand cited sources only if needed.\n\nPack: `{}`\n\n{}",
            Self::brand_display_name(brand),
            Self::brand_instruction_file(brand),
            context_id,
            summary_markdown
        )
    }

    fn extract_heading_bullets(body: &str, headings: &[&str]) -> Vec<String> {
        let wanted = headings
            .iter()
            .map(|row| row.to_ascii_lowercase())
            .collect::<HashSet<_>>();
        let mut current_heading: Option<String> = None;
        let mut out = Vec::new();

        for raw_line in body.lines() {
            let line = raw_line.trim();
            if line.starts_with('#') {
                current_heading = Some(line.trim_start_matches('#').trim().to_ascii_lowercase());
                continue;
            }

            let in_target_heading = current_heading
                .as_ref()
                .map(|row| wanted.iter().any(|wanted| row.contains(wanted)))
                .unwrap_or(false);
            if !in_target_heading {
                continue;
            }

            let bullet = if let Some(stripped) = line.strip_prefix("- ") {
                Some(stripped)
            } else if let Some(stripped) = line.strip_prefix("* ") {
                Some(stripped)
            } else if line
                .chars()
                .next()
                .map(|ch| ch.is_ascii_digit())
                .unwrap_or(false)
                && line.contains(". ")
            {
                line.split_once(". ").map(|(_, stripped)| stripped)
            } else {
                None
            };

            if let Some(bullet) = bullet {
                let text = bullet.trim();
                if !text.is_empty() {
                    out.push(text.to_string());
                }
            }
        }

        out
    }

    fn extract_prefixed_statements(body: &str, prefixes: &[&str]) -> Vec<String> {
        let mut out = Vec::new();
        for raw_line in body.lines() {
            let line = raw_line.trim();
            for prefix in prefixes {
                if let Some(stripped) = line.strip_prefix(prefix) {
                    let text = stripped.trim();
                    if !text.is_empty() {
                        out.push(text.to_string());
                    }
                }
            }
        }
        out
    }

    fn push_context_statement(
        target: &mut Vec<ContextStatement>,
        seen: &mut HashSet<String>,
        text: String,
        citation: &str,
    ) {
        let normalized = text.trim().to_string();
        if normalized.is_empty() || !seen.insert(normalized.clone()) {
            return;
        }
        target.push(ContextStatement {
            text: normalized,
            citations: vec![citation.to_string()],
        });
    }

    fn statements_to_values(statements: &[ContextStatement]) -> Vec<Value> {
        statements
            .iter()
            .map(|row| {
                json!({
                    "text": row.text,
                    "citations": row.citations,
                })
            })
            .collect()
    }

    fn truncate_text(value: &str, max_chars: usize) -> String {
        if value.chars().count() <= max_chars {
            return value.to_string();
        }
        value.chars().take(max_chars).collect::<String>()
    }

    fn load_meta_by_doc(&self, doc_id: &str) -> Result<Option<DocMeta>, BtError> {
        let conn = self.open_conn()?;
        let doc = db::get_doc(&conn, doc_id)?;
        let Some(doc) = doc else {
            return Ok(None);
        };

        let root = self.require_vault()?;
        let meta_path = fs_guard::safe_join(
            &root,
            Path::new(&format!("topics/{}/{}/meta.json", doc.topic, doc.slug)),
        )?;
        if !meta_path.exists() {
            return Ok(None);
        }
        let raw = fs::read_to_string(meta_path)?;
        let meta: DocMeta =
            serde_json::from_str(&raw).map_err(|e| BtError::Validation(e.to_string()))?;
        Ok(Some(meta))
    }

    fn save_meta(&self, meta: &DocMeta) -> Result<(), BtError> {
        let root = self.require_vault()?;
        let conn = self.open_conn()?;
        let doc = db::get_doc(&conn, &meta.id.to_string())?
            .ok_or_else(|| BtError::NotFound(format!("doc {} not found", meta.id)))?;

        let meta_path = fs_guard::safe_join(
            &root,
            Path::new(&format!("topics/{}/{}/meta.json", doc.topic, doc.slug)),
        )?;
        let payload =
            serde_json::to_string_pretty(meta).map_err(|e| BtError::Validation(e.to_string()))?;
        fs_guard::atomic_write(&root, &meta_path, &payload)?;
        db::upsert_doc_meta(
            &conn,
            &meta.id.to_string(),
            &meta.tags,
            &meta.links_out,
            meta.status.as_deref(),
            meta.updated_at,
        )?;
        db::upsert_links(&conn, &meta.id.to_string(), &meta.links_out)?;

        Ok(())
    }

    pub fn apply_write(&self, actor: &Actor, op: WriteOperation) -> Result<(), BtError> {
        if let Actor::Agent { .. } = actor {
            match op {
                WriteOperation::UpdateAgentNote
                | WriteOperation::DeleteAgentContent
                | WriteOperation::UpdateTasksMirror
                | WriteOperation::CreateRun
                | WriteOperation::UpdateRun
                | WriteOperation::AttachRunArtifact
                | WriteOperation::ManageContext
                | WriteOperation::ManageContractsReport
                | WriteOperation::ManageContracts
                | WriteOperation::InternalBt => Ok(()),
                WriteOperation::ManageAutomation
                | WriteOperation::ManageCrafting
                | WriteOperation::ManageRegistry
                | WriteOperation::ManageOrg
                | WriteOperation::ManageGoal
                | WriteOperation::ManageTicket
                | WriteOperation::ManageBudget
                | WriteOperation::ManagePlan
                | WriteOperation::ManageGovernance
                | WriteOperation::ManageRuntime
                | WriteOperation::ManageWorker
                | WriteOperation::ViewMonitor => Err(BtError::Forbidden(
                    "ERR_AGENT_FORBIDDEN_OPERATOR_SURFACE".to_string(),
                )),
                WriteOperation::BootstrapRuntime => Err(BtError::Forbidden(
                    "ERR_AGENT_FORBIDDEN_RUNTIME_BOOTSTRAP".to_string(),
                )),
                WriteOperation::UpdateMeta { fields } => {
                    let allowed: HashSet<&str> = ["tags", "links_out", "status", "updated_at"]
                        .into_iter()
                        .collect();
                    for field in fields {
                        if !allowed.contains(field.as_str()) {
                            return Err(BtError::Forbidden(format!(
                                "ERR_AGENT_FORBIDDEN_META_FIELD: {}",
                                field
                            )));
                        }
                    }
                    Ok(())
                }
                WriteOperation::RenameDocument { title_only } => {
                    if title_only {
                        Ok(())
                    } else {
                        Err(BtError::Forbidden(
                            "ERR_AGENT_FORBIDDEN_PATH_MUTATION".to_string(),
                        ))
                    }
                }
                WriteOperation::UpdateUserNote => Err(BtError::Forbidden(
                    "ERR_AGENT_FORBIDDEN_USER_NOTE_WRITE".to_string(),
                )),
                WriteOperation::CreateDocument
                | WriteOperation::CreateTopic
                | WriteOperation::DeleteDocument => Err(BtError::Forbidden(
                    "ERR_AGENT_FORBIDDEN_PATH_WRITE".to_string(),
                )),
            }
        } else {
            Ok(())
        }
    }

    fn audit(
        &self,
        actor: &Actor,
        action: &str,
        args: &Value,
        doc_id: Option<&str>,
        run_id: Option<&str>,
        result: &str,
        details: Value,
    ) -> Result<(), BtError> {
        let root = self.require_vault()?;
        let mut h = Sha256::new();
        h.update(args.to_string().as_bytes());
        let args_hash = hex::encode(h.finalize());

        let entry = AuditEntry {
            ts: Utc::now(),
            actor_type: actor.actor_type().to_string(),
            actor_id: actor.actor_id(),
            action: action.to_string(),
            args_hash: args_hash.clone(),
            doc_id: doc_id.map(ToOwned::to_owned),
            run_id: run_id.map(ToOwned::to_owned),
            result: result.to_string(),
            details,
        };

        fs_guard::rotate_audit_if_needed(&root)?;
        let audit_path = fs_guard::safe_join(&root, Path::new(".bt/audit.log"))?;
        let line = serde_json::to_string(&entry).map_err(|e| BtError::Validation(e.to_string()))?;

        // O(1) append. The previous implementation read the entire audit
        // log into memory and rewrote it on every call, which was
        // O(audit_log_size²) over the lifetime of a daemon. That pattern
        // was the root cause of the recurring `crafting.craftship.session.launch`
        // RPC timeout — the launch handler issues multiple audit writes and
        // the per-write cost climbed until the 45-second client timeout
        // fired. See `operations/quality/2026-04-08-rpc-latency-hardening.md`.
        fs_guard::append_log_line(&root, &audit_path, &line)?;

        let conn = self.open_conn()?;
        db::insert_audit(&conn, &entry)?;

        // Also emit a durable event for connectors (at-least-once; consumers should dedupe by event_id).
        // For normal audited operations we do not set dedupe_key (reserved for idempotent emissions like scheduler).
        let payload = json!({
            "action": action,
            "args": args,
            "args_hash": args_hash,
            "doc_id": doc_id,
            "run_id": run_id,
            "result": result,
            "details": entry.details,
        });
        let _event_id = db::insert_event(
            &conn,
            action,
            &entry.actor_type,
            &entry.actor_id,
            doc_id,
            run_id,
            &payload,
            None,
        )?;

        // Debounced: the full O(vault) graph projection rebuild happens
        // at most once per `GRAPH_REFRESH_THROTTLE`, not on every audit.
        // Load-side `load_graph_records` self-heals if the projection is
        // stale, so bounded staleness here is safe for correctness.
        self.maybe_refresh_graph_projection()?;

        Ok(())
    }

    /// Audit without triggering a graph projection rebuild. Use on
    /// write-hot-path handlers whose mutations do not alter graph
    /// structure (e.g. handoff status flips). The graph catches up on
    /// the next throttled refresh or on-demand read via
    /// `load_graph_records` self-heal.
    /// See `operations/quality/2026-04-08-rpc-latency-hardening.md`.
    fn audit_no_refresh(
        &self,
        actor: &Actor,
        action: &str,
        args: &Value,
        doc_id: Option<&str>,
        run_id: Option<&str>,
        result: &str,
        details: Value,
    ) -> Result<(), BtError> {
        let root = self.require_vault()?;
        let mut h = Sha256::new();
        h.update(args.to_string().as_bytes());
        let args_hash = hex::encode(h.finalize());

        let entry = AuditEntry {
            ts: Utc::now(),
            actor_type: actor.actor_type().to_string(),
            actor_id: actor.actor_id(),
            action: action.to_string(),
            args_hash: args_hash.clone(),
            doc_id: doc_id.map(ToOwned::to_owned),
            run_id: run_id.map(ToOwned::to_owned),
            result: result.to_string(),
            details,
        };

        fs_guard::rotate_audit_if_needed(&root)?;
        let audit_path = fs_guard::safe_join(&root, Path::new(".bt/audit.log"))?;
        let line = serde_json::to_string(&entry).map_err(|e| BtError::Validation(e.to_string()))?;
        fs_guard::append_log_line(&root, &audit_path, &line)?;

        let conn = self.open_conn()?;
        db::insert_audit(&conn, &entry)?;

        let payload = json!({
            "action": action,
            "args": args,
            "args_hash": args_hash,
            "doc_id": doc_id,
            "run_id": run_id,
            "result": result,
            "details": entry.details,
        });
        let _event_id = db::insert_event(
            &conn,
            action,
            &entry.actor_type,
            &entry.actor_id,
            doc_id,
            run_id,
            &payload,
            None,
        )?;

        // Intentionally NO graph refresh here — callers use this variant
        // specifically because they are on the handoff hot path and their
        // mutations do not change graph topology.

        Ok(())
    }

    // ==========================================================================
    // Contracts service (System A)
    // ==========================================================================

    // ==========================================================================
    // (contracts + pre_work + craftship-session-launch machinery removed in H2)
    // ==========================================================================
}

fn parse_string_list(value: &Value, field: &str) -> Result<Vec<String>, BtError> {
    let list = value
        .as_array()
        .ok_or_else(|| BtError::Validation(format!("{} must be an array of strings", field)))?;
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for item in list {
        let entry = item
            .as_str()
            .ok_or_else(|| BtError::Validation(format!("{} must contain only strings", field)))?
            .trim()
            .to_string();
        if entry.is_empty() {
            continue;
        }
        let key = entry.to_lowercase();
        if seen.insert(key) {
            out.push(entry);
        }
    }
    Ok(out)
}

fn parse_dome_task_plan(content: &str) -> Result<Option<DomeTaskPlan>, BtError> {
    let mut in_block = false;
    let mut block = String::new();

    for line in content.lines() {
        if !in_block {
            if line.trim() == format!("```{}", DOME_TASK_PLAN_BLOCK) {
                in_block = true;
            }
            continue;
        }

        if line.trim() == "```" {
            let mut plan: DomeTaskPlan = serde_json::from_str(&block).map_err(|err| {
                BtError::Validation(format!("invalid dome-task-plan JSON: {}", err))
            })?;
            if plan.version.trim() != "v1" {
                return Err(BtError::Validation(
                    "dome-task-plan version must be v1".to_string(),
                ));
            }
            if plan.mode.trim() != "steer_queue" {
                return Err(BtError::Validation(
                    "dome-task-plan mode must be steer_queue".to_string(),
                ));
            }

            let mut seen_orders = HashSet::new();
            for entry in &mut plan.tasks {
                entry.title = entry.title.trim().to_string();
                if entry.title.is_empty() {
                    return Err(BtError::Validation(
                        "dome-task-plan tasks must have a title".to_string(),
                    ));
                }
                if entry.order <= 0 {
                    return Err(BtError::Validation(
                        "dome-task-plan task order must be greater than 0".to_string(),
                    ));
                }
                if !seen_orders.insert(entry.order) {
                    return Err(BtError::Validation(
                        "dome-task-plan task order values must be unique".to_string(),
                    ));
                }
            }

            plan.tasks.sort_by_key(|entry| entry.order);
            return Ok(Some(plan));
        }

        block.push_str(line);
        block.push('\n');
    }

    if in_block {
        return Err(BtError::Validation(
            "dome-task-plan block is missing a closing fence".to_string(),
        ));
    }

    Ok(None)
}

fn normalize_unique_trimmed_strings(values: Vec<String>) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for value in values {
        let trimmed = value.trim().to_string();
        if trimmed.is_empty() {
            continue;
        }
        let key = trimmed.to_lowercase();
        if seen.insert(key) {
            out.push(trimmed);
        }
    }
    out
}

fn parse_dome_craftship_plan(content: &str) -> Result<Option<DomeCraftshipPlan>, BtError> {
    let mut in_block = false;
    let mut block = String::new();

    for line in content.lines() {
        if !in_block {
            if line.trim() == format!("```{}", DOME_CRAFTSHIP_PLAN_BLOCK) {
                in_block = true;
            }
            continue;
        }

        if line.trim() == "```" {
            let mut plan: DomeCraftshipPlan = serde_json::from_str(&block).map_err(|err| {
                BtError::Validation(format!("invalid dome-craftship-plan JSON: {}", err))
            })?;
            if plan.version.trim() != "v1" {
                return Err(BtError::Validation(
                    "dome-craftship-plan version must be v1".to_string(),
                ));
            }
            if plan.mode.trim() != "task_order_dispatch" {
                return Err(BtError::Validation(
                    "dome-craftship-plan mode must be task_order_dispatch".to_string(),
                ));
            }
            plan.craftship_id = plan.craftship_id.trim().to_string();
            if plan.craftship_id.is_empty() {
                return Err(BtError::Validation(
                    "dome-craftship-plan craftship_id is required".to_string(),
                ));
            }

            let mut seen_orders = HashSet::new();
            for step in &mut plan.steps {
                step.task_title = step.task_title.trim().to_string();
                if step.task_title.is_empty() {
                    return Err(BtError::Validation(
                        "dome-craftship-plan steps must have a task_title".to_string(),
                    ));
                }
                if step.task_order <= 0 {
                    return Err(BtError::Validation(
                        "dome-craftship-plan task_order must be greater than 0".to_string(),
                    ));
                }
                if !seen_orders.insert(step.task_order) {
                    return Err(BtError::Validation(
                        "dome-craftship-plan task_order values must be unique".to_string(),
                    ));
                }

                let mut seen_assignments = HashSet::new();
                for assignment in &mut step.assignments {
                    assignment.template_node_id = assignment.template_node_id.trim().to_string();
                    assignment.title = assignment.title.trim().to_string();
                    assignment.description_md = assignment.description_md.trim().to_string();
                    assignment.success_criteria = normalize_unique_trimmed_strings(std::mem::take(
                        &mut assignment.success_criteria,
                    ));
                    assignment.verification_hint = assignment
                        .verification_hint
                        .take()
                        .map(|value| value.trim().to_string())
                        .filter(|value| !value.is_empty());

                    if assignment.template_node_id.is_empty() {
                        return Err(BtError::Validation(
                            "dome-craftship-plan assignments must have a template_node_id"
                                .to_string(),
                        ));
                    }
                    if assignment.title.is_empty() {
                        return Err(BtError::Validation(
                            "dome-craftship-plan assignments must have a title".to_string(),
                        ));
                    }
                    if assignment.description_md.is_empty() {
                        return Err(BtError::Validation(
                            "dome-craftship-plan assignments must have description_md".to_string(),
                        ));
                    }

                    let assignment_key = format!(
                        "{}::{}",
                        assignment.template_node_id.to_lowercase(),
                        normalize_task_title(&assignment.title)
                    );
                    if !seen_assignments.insert(assignment_key) {
                        return Err(BtError::Validation(
                            "dome-craftship-plan assignments must be unique per template_node_id and title"
                                .to_string(),
                        ));
                    }
                }
            }

            plan.steps.sort_by_key(|step| step.task_order);
            return Ok(Some(plan));
        }

        block.push_str(line);
        block.push('\n');
    }

    if in_block {
        return Err(BtError::Validation(
            "dome-craftship-plan block is missing a closing fence".to_string(),
        ));
    }

    Ok(None)
}

fn task_plan_entry_matches_active(entry: &DomeTaskPlanEntry, task: &Task) -> bool {
    normalize_task_title(&entry.title) == normalize_task_title(&task.title)
}

fn normalize_task_title(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_lowercase()
}

fn format_task_markdown(task: &Task) -> String {
    let mut line = format!("- {}", task.title);
    if let Some(doc_id) = &task.doc_id {
        line.push_str(&format!(" _(doc: {})_", doc_id));
    }
    if let Some(priority) = &task.priority {
        line.push_str(&format!(" _(priority: {})_", priority));
    }
    if let Some(queue_order) = task.queue_order {
        line.push_str(&format!(" _(order: {})_", queue_order));
    }
    if !task.success_criteria.is_empty() {
        line.push_str(&format!(
            "\n  - success: {}",
            task.success_criteria.join("; ")
        ));
    }
    if let Some(verification_hint) = &task.verification_hint {
        line.push_str(&format!("\n  - verify: {}", verification_hint));
    }
    line
}

fn format_archived_task_markdown(task: &Task) -> String {
    let mut line = format!("- [x] {}", task.title);
    if let Some(doc_id) = &task.doc_id {
        line.push_str(&format!(" _(doc: {})_", doc_id));
    }
    if let Some(priority) = &task.priority {
        line.push_str(&format!(" _(priority: {})_", priority));
    }
    if let Some(archived_at) = task.archived_at {
        line.push_str(&format!(" _(archived_at: {})_", archived_at.to_rfc3339()));
    }
    if let Some(run_id) = &task.verified_by_run_id {
        line.push_str(&format!(" _(run: {})_", run_id));
    }
    if let Some(summary) = &task.verification_summary {
        line.push_str(&format!("\n  - verification: {}", summary));
    }
    line
}

fn graph_key_segment(value: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in value.trim().to_lowercase().chars() {
        let normalized = if ch.is_ascii_alphanumeric() { ch } else { '-' };
        if normalized == '-' {
            if !last_dash && !out.is_empty() {
                out.push(normalized);
            }
            last_dash = true;
        } else {
            out.push(normalized);
            last_dash = false;
        }
    }
    out.trim_matches('-').to_string()
}

fn parse_graph_include_types(value: Option<&Value>) -> HashSet<&'static str> {
    let requested = value
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(Value::as_str)
                .collect::<HashSet<_>>()
        })
        .unwrap_or_default();
    if requested.is_empty() {
        return GRAPH_DEFAULT_INCLUDE_TYPES.iter().copied().collect();
    }
    GRAPH_ALL_NODE_TYPES
        .iter()
        .copied()
        .filter(|kind| requested.contains(kind))
        .collect()
}

fn graph_node_within_time_window(
    node: &GraphNodeRecord,
    from: Option<DateTime<Utc>>,
    to: Option<DateTime<Utc>>,
) -> bool {
    if !matches!(
        node.kind.as_str(),
        "run"
            | "shared_context"
            | "context_pack"
            | "context_event"
            | "artifact"
            | "event"
            | "craftship"
            | "craftship_session"
            | "craftship_session_node"
    ) {
        return true;
    }
    let Some(ts) = node.sort_time else {
        return true;
    };
    if let Some(from) = from {
        if ts < from {
            return false;
        }
    }
    if let Some(to) = to {
        if ts > to {
            return false;
        }
    }
    true
}

fn graph_doc_scope_map(
    nodes: &[GraphNodeRecord],
) -> HashMap<String, (String, Option<String>)> {
    nodes
        .iter()
        .filter(|node| node.kind == "doc")
        .map(|node| {
            let owner_scope = node
                .payload
                .get("owner_scope")
                .and_then(Value::as_str)
                .unwrap_or("global")
                .to_string();
            let project_id = node
                .payload
                .get("project_id")
                .and_then(Value::as_str)
                .map(str::to_string);
            (node.ref_id.clone(), (owner_scope, project_id))
        })
        .collect()
}

fn graph_node_matches_scope(
    node: &GraphNodeRecord,
    filter: &KnowledgeScopeFilter,
    doc_scope_map: &HashMap<String, (String, Option<String>)>,
) -> Option<bool> {
    let mut owner_scope = node
        .payload
        .get("owner_scope")
        .and_then(Value::as_str)
        .map(str::to_string);
    let mut project_id = node
        .payload
        .get("project_id")
        .and_then(Value::as_str)
        .map(str::to_string);

    if owner_scope.is_none() {
        if let Some(doc_id) = node.payload.get("doc_id").and_then(Value::as_str) {
            if let Some((scope, project)) = doc_scope_map.get(doc_id) {
                owner_scope = Some(scope.clone());
                project_id = project.clone();
            }
        }
    }

    if owner_scope.is_none() && project_id.is_some() {
        owner_scope = Some("project".to_string());
    }

    owner_scope.map(|scope| {
        KnowledgeScopeFilter::matches_parts(
            &filter.mode,
            filter.project_id.as_deref(),
            filter.include_global,
            &scope,
            project_id.as_deref(),
        )
    })
}

fn status_payload_matches_scope(value: &Value, filter: &KnowledgeScopeFilter) -> bool {
    if filter.mode == "all" || filter.mode == "global" {
        return true;
    }
    let project_id = value
        .get("project_id")
        .or_else(|| value.get("projectId"))
        .and_then(Value::as_str);
    match project_id {
        Some(id) => filter.project_id.as_deref() == Some(id),
        None => filter.include_global,
    }
}

fn graph_focus_neighborhood(focus_node_id: &str, edges: &[GraphEdgeRecord]) -> HashSet<String> {
    let mut keep = HashSet::from([focus_node_id.to_string()]);
    for edge in edges {
        if edge.source_id == focus_node_id || edge.target_id == focus_node_id {
            keep.insert(edge.source_id.clone());
            keep.insert(edge.target_id.clone());
        }
    }
    keep
}

fn graph_kind_priority(kind: &str) -> usize {
    match kind {
        "doc" => 0,
        "topic" => 1,
        "tag" => 2,
        "task" => 3,
        "automation" => 4,
        "run" => 5,
        "shared_context" => 6,
        "context_pack" => 7,
        "context_event" => 8,
        "framework" => 9,
        "craftship" => 10,
        "craftship_session" => 11,
        "craftship_session_node" => 12,
        "agent" => 13,
        "artifact" => 14,
        "event" => 15,
        _ => 15,
    }
}

fn graph_node_sort_key(left: &GraphNodeRecord, right: &GraphNodeRecord) -> Ordering {
    graph_kind_priority(&left.kind)
        .cmp(&graph_kind_priority(&right.kind))
        .then_with(|| right.sort_time.cmp(&left.sort_time))
        .then_with(|| left.label.to_lowercase().cmp(&right.label.to_lowercase()))
}

fn count_graph_kinds(nodes: &[GraphNodeRecord]) -> BTreeMap<String, usize> {
    let mut counts = BTreeMap::new();
    for node in nodes {
        *counts.entry(node.kind.clone()).or_insert(0) += 1;
    }
    counts
}

fn graph_layout(nodes: &[GraphNodeRecord], edges: &[GraphEdgeRecord]) -> Value {
    let mut groups = BTreeMap::<String, Vec<&GraphNodeRecord>>::new();
    for node in nodes {
        groups.entry(node.group_key.clone()).or_default().push(node);
    }

    let group_count = groups.len().max(1) as f64;
    let graph_radius = 420.0_f64.max(group_count * 72.0);
    let mut node_positions = serde_json::Map::new();
    let mut clusters = Vec::new();

    for (group_index, (group_key, mut group_nodes)) in groups.into_iter().enumerate() {
        group_nodes.sort_by(|a, b| graph_node_sort_key(a, b));
        let angle = 2.0 * std::f64::consts::PI * (group_index as f64) / group_count;
        let center_x = angle.cos() * graph_radius;
        let center_y = angle.sin() * graph_radius;
        let node_count = group_nodes.len().max(1) as f64;
        let local_radius = 52.0_f64.max(node_count.sqrt() * 44.0);
        clusters.push(json!({
            "group_key": group_key,
            "x": center_x,
            "y": center_y,
            "count": group_nodes.len(),
        }));

        for (node_index, node) in group_nodes.into_iter().enumerate() {
            let local_angle = 2.0 * std::f64::consts::PI * (node_index as f64) / node_count;
            let rank_weight = match node.kind.as_str() {
                "doc" | "context_pack" | "task" => 1.2,
                "topic" | "agent" | "run" => 1.0,
                _ => 0.82,
            };
            node_positions.insert(
                node.node_id.clone(),
                json!({
                    "x": center_x + local_angle.cos() * local_radius,
                    "y": center_y + local_angle.sin() * local_radius,
                    "rank": rank_weight,
                    "cluster": group_key,
                }),
            );
        }
    }

    json!({
        "engine": "bt-core-radial-stable-v1",
        "nodes": node_positions,
        "clusters": clusters,
        "edge_count": edges.len(),
    })
}

fn upsert_graph_node(nodes: &mut BTreeMap<String, GraphNodeRecord>, node: GraphNodeRecord) {
    nodes.insert(node.node_id.clone(), node);
}

fn upsert_graph_edge(edges: &mut BTreeMap<String, GraphEdgeRecord>, edge: GraphEdgeRecord) {
    edges.insert(edge.edge_id.clone(), edge);
}

fn resolve_graph_doc_ref(raw: &str, doc_ref_map: &HashMap<String, String>) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    doc_ref_map
        .get(trimmed)
        .cloned()
        .or_else(|| doc_ref_map.get(trimmed.trim_start_matches('/')).cloned())
}

fn graph_canonical_refs(node: &GraphNodeRecord) -> Value {
    let payload = &node.payload;
    match node.kind.as_str() {
        "doc" => json!({
            "doc_id": payload.get("doc_id"),
            "topic": payload.get("topic"),
            "slug": payload.get("slug"),
        }),
        "task" => json!({
            "task_id": payload.get("task_id"),
            "doc_id": payload.get("doc_id"),
        }),
        "automation" => json!({
            "automation_id": payload.get("automation_id"),
            "doc_id": payload.get("doc_id"),
            "task_id": payload.get("task_id"),
            "shared_context_key": payload.get("shared_context_key"),
        }),
        "run" => json!({
            "run_id": payload.get("run_id"),
            "doc_id": payload.get("doc_id"),
            "task_id": payload.get("task_id"),
            "automation_id": payload.get("automation_id"),
            "craftship_session_id": payload.get("craftship_session_id"),
            "craftship_session_node_id": payload.get("craftship_session_node_id"),
        }),
        "shared_context" => json!({
            "context_key": payload.get("context_key"),
            "automation_id": payload.get("automation_id"),
            "latest_run_id": payload.get("latest_run_id"),
        }),
        "context_pack" => json!({
            "context_id": payload.get("context_id"),
            "session_id": payload.get("session_id"),
            "doc_id": payload.get("doc_id"),
            "brand": payload.get("brand"),
        }),
        "context_event" => json!({
            "event_id": payload.get("event_id"),
            "context_id": payload.get("context_id"),
            "node_id": payload.get("node_id"),
            "event_kind": payload.get("event_kind"),
        }),
        "artifact" => json!({
            "artifact_id": payload.get("artifact_id"),
            "run_id": payload.get("run_id"),
            "path": payload.get("path"),
        }),
        "event" => json!({
            "event_id": payload.get("event_id"),
            "doc_id": payload.get("doc_id"),
            "run_id": payload.get("run_id"),
        }),
        "topic" => json!({ "topic": payload.get("topic") }),
        "tag" => json!({ "tag": payload.get("tag") }),
        "agent" => json!({
            "agent_name": payload.get("agent_name"),
            "token_ids": payload.get("token_ids"),
        }),
        "framework" => json!({
            "framework_id": payload.get("framework_id"),
            "name": payload.get("name"),
            "enhancement_version": payload.get("enhancement_version"),
        }),
        "craftship" => json!({
            "craftship_id": payload.get("craftship_id"),
            "mode": payload.get("mode"),
        }),
        "craftship_session" => json!({
            "craftship_session_id": payload.get("craftship_session_id"),
            "craftship_id": payload.get("craftship_id"),
            "doc_id": payload.get("doc_id"),
            "last_context_pack_id": payload.get("last_context_pack_id"),
        }),
        "craftship_session_node" => json!({
            "session_node_id": payload.get("session_node_id"),
            "craftship_session_id": payload.get("craftship_session_id"),
            "framework_id": payload.get("framework_id"),
            "run_id": payload.get("run_id"),
        }),
        "company" => json!({
            "company_id": payload.get("company_id"),
            "name": payload.get("name"),
        }),
        "goal" => json!({
            "goal_id": payload.get("goal_id"),
            "company_id": payload.get("company_id"),
            "parent_goal_id": payload.get("parent_goal_id"),
        }),
        "ticket" => json!({
            "ticket_id": payload.get("ticket_id"),
            "goal_id": payload.get("goal_id"),
            "task_id": payload.get("task_id"),
            "plan_id": payload.get("plan_id"),
        }),
        "plan" => json!({
            "plan_id": payload.get("plan_id"),
            "ticket_id": payload.get("ticket_id"),
            "task_id": payload.get("task_id"),
        }),
        "brand" => json!({
            "brand_id": payload.get("brand_id"),
            "adapter_kind": payload.get("adapter_kind"),
        }),
        "adapter" => json!({
            "adapter_kind": payload.get("adapter_kind"),
        }),
        _ => Value::Null,
    }
}

#[cfg(test)]
mod scoped_knowledge_tests {
    use super::*;
    use rusqlite::params;
    use std::{fs, path::Path, path::PathBuf};

    fn doc(owner_scope: &str, project_id: Option<&str>) -> DocRecord {
        DocRecord {
            id: "doc".to_string(),
            topic: "topic".to_string(),
            slug: "slug".to_string(),
            title: "Title".to_string(),
            user_path: "topics/topic/slug/user.md".to_string(),
            agent_path: "topics/topic/slug/agent.md".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            owner_scope: owner_scope.to_string(),
            project_id: project_id.map(str::to_string),
            project_root: None,
            knowledge_kind: "knowledge".to_string(),
        }
    }

    #[test]
    fn merged_project_scope_includes_global_and_matching_project() {
        let filter = KnowledgeScopeFilter::from_parts(Some("merged"), Some("p1"), None);
        assert!(filter.matches_doc(&doc("global", None)));
        assert!(filter.matches_doc(&doc("project", Some("p1"))));
        assert!(!filter.matches_doc(&doc("project", Some("p2"))));
    }

    #[test]
    fn global_scope_hides_project_docs() {
        let filter = KnowledgeScopeFilter::from_parts(Some("global"), Some("p1"), None);
        assert!(filter.matches_doc(&doc("global", None)));
        assert!(!filter.matches_doc(&doc("project", Some("p1"))));
    }

    fn temp_vault(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "tado-bt-core-{}-{}",
            label,
            uuid::Uuid::new_v4().simple()
        ))
    }

    fn ui_actor() -> Actor {
        Actor::UserUi {
            session_id: "test-ui".to_string(),
        }
    }

    #[test]
    fn doc_delete_removes_doc_rows_chunks_and_files() {
        let vault = temp_vault("doc-delete");
        let service = CoreService::new();
        service.open_vault(&vault).unwrap();
        let actor = ui_actor();

        let created = service
            .knowledge_register(
                &actor,
                "Delete me",
                "Body to index",
                "global",
                None,
                None,
                Some("topic-a"),
                Some("knowledge"),
                Some("user"),
            )
            .unwrap();
        let doc_id = created
            .get("doc")
            .and_then(|value| value.get("id"))
            .and_then(Value::as_str)
            .unwrap()
            .to_string();

        let conn = service.open_conn().unwrap();
        let user_path: String = conn
            .query_row(
                "SELECT user_path FROM docs WHERE id = ?1",
                params![&doc_id],
                |row| row.get(0),
            )
            .unwrap();
        let chunk_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM note_chunks WHERE doc_id = ?1",
                params![&doc_id],
                |row| row.get(0),
            )
            .unwrap();
        assert!(chunk_count > 0);
        drop(conn);

        let doc_dir = vault
            .join(Path::new(&user_path))
            .parent()
            .unwrap()
            .to_path_buf();
        assert!(doc_dir.exists());

        let deleted = service.doc_delete(&actor, &doc_id).unwrap();
        assert_eq!(deleted.get("deleted").and_then(Value::as_bool), Some(true));
        let warnings = deleted
            .get("warnings")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        assert!(
            warnings.is_empty(),
            "unexpected delete warnings: {:?}",
            warnings
        );

        let conn = service.open_conn().unwrap();
        assert!(db::get_doc(&conn, &doc_id).unwrap().is_none());
        let meta_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM doc_meta WHERE doc_id = ?1",
                params![&doc_id],
                |row| row.get(0),
            )
            .unwrap();
        let chunk_count_after: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM note_chunks WHERE doc_id = ?1",
                params![&doc_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(meta_count, 0);
        assert_eq!(chunk_count_after, 0);
        assert!(!doc_dir.exists());

        let _ = fs::remove_dir_all(&vault);
    }

    #[test]
    fn parse_actor_accepts_legacy_user_ui_shape() {
        let params = json!({
            "actor": {
                "type": "user_ui",
                "sessionId": "tado-ui",
            }
        });

        assert_eq!(
            parse_actor(&params).unwrap(),
            Actor::UserUi {
                session_id: "tado-ui".to_string(),
            }
        );
    }
}

fn parse_actor(params: &Value) -> Result<Actor, BtError> {
    if let Some(actor) = params.get("actor") {
        if let Ok(parsed) = serde_json::from_value(actor.clone()) {
            return Ok(parsed);
        }
        parse_actor_aliases(actor)
    } else {
        Ok(Actor::CliUser)
    }
}

fn parse_actor_aliases(actor: &Value) -> Result<Actor, BtError> {
    let kind = actor
        .get("kind")
        .or_else(|| actor.get("type"))
        .and_then(Value::as_str)
        .ok_or_else(|| BtError::Validation("invalid actor payload: missing actor kind".to_string()))?;

    match kind {
        "user_ui" => {
            let session_id = actor
                .get("session_id")
                .or_else(|| actor.get("sessionId"))
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    BtError::Validation(
                        "invalid actor payload: user_ui requires session_id".to_string(),
                    )
                })?;
            Ok(Actor::UserUi {
                session_id: session_id.to_string(),
            })
        }
        "agent" => {
            let token_id = actor
                .get("token_id")
                .or_else(|| actor.get("tokenId"))
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    BtError::Validation(
                        "invalid actor payload: agent requires token_id".to_string(),
                    )
                })?;
            Ok(Actor::Agent {
                token_id: token_id.to_string(),
            })
        }
        "cli_user" => Ok(Actor::CliUser),
        "system" => {
            let component = actor
                .get("component")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    BtError::Validation(
                        "invalid actor payload: system requires component".to_string(),
                    )
                })?;
            Ok(Actor::System {
                component: component.to_string(),
            })
        }
        other => Err(BtError::Validation(format!(
            "invalid actor payload: unsupported actor kind {}",
            other
        ))),
    }
}

fn required_str<'a>(params: &'a Value, key: &str) -> Result<&'a str, BtError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| BtError::Validation(format!("{} is required", key)))
}

fn optional_str<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str)
}

fn optional_bool(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(Value::as_bool)
}

fn optional_string_value(params: &Value, key: &str) -> Option<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn parse_required_rfc3339(value: &str, key: &str) -> Result<DateTime<Utc>, BtError> {
    DateTime::parse_from_rfc3339(value)
        .map(|d| d.with_timezone(&Utc))
        .map_err(|_| BtError::Validation(format!("{} must be RFC3339", key)))
}

fn parse_optional_rfc3339(
    value: Option<&str>,
    key: &str,
) -> Result<Option<DateTime<Utc>>, BtError> {
    value
        .map(|raw| parse_required_rfc3339(raw, key))
        .transpose()
}

#[derive(Debug, Serialize, Deserialize)]
struct OpsPatch {
    op: String,
    start: usize,
    end: Option<usize>,
    text: Option<String>,
}

fn apply_ops_patch(current: &str, ops: &[Value]) -> Result<String, BtError> {
    let mut output = current.to_string();
    for op_raw in ops {
        let op: OpsPatch = serde_json::from_value(op_raw.clone())
            .map_err(|e| BtError::Validation(format!("invalid ops patch item: {}", e)))?;

        if op.start > output.len() || !output.is_char_boundary(op.start) {
            return Err(BtError::Validation(
                "ops patch start index out of bounds".to_string(),
            ));
        }

        match op.op.as_str() {
            "insert" => {
                let text = op.text.unwrap_or_default();
                output.insert_str(op.start, &text);
            }
            "delete" => {
                let end = op
                    .end
                    .ok_or_else(|| BtError::Validation("delete op requires end".to_string()))?;
                if end > output.len() || end < op.start || !output.is_char_boundary(end) {
                    return Err(BtError::Validation(
                        "ops patch end index out of bounds".to_string(),
                    ));
                }
                output.replace_range(op.start..end, "");
            }
            "replace" => {
                let end = op
                    .end
                    .ok_or_else(|| BtError::Validation("replace op requires end".to_string()))?;
                if end > output.len() || end < op.start || !output.is_char_boundary(end) {
                    return Err(BtError::Validation(
                        "ops patch end index out of bounds".to_string(),
                    ));
                }
                let text = op.text.unwrap_or_default();
                output.replace_range(op.start..end, &text);
            }
            _ => {
                return Err(BtError::Validation(format!("unsupported op {}", op.op)));
            }
        }
    }

    Ok(output)
}
