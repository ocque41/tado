use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Actor {
    UserUi { session_id: String },
    Agent { token_id: String },
    CliUser,
    System { component: String },
}

impl Actor {
    pub fn actor_type(&self) -> &'static str {
        match self {
            Actor::UserUi { .. } => "user_ui",
            Actor::Agent { .. } => "agent",
            Actor::CliUser => "cli_user",
            Actor::System { .. } => "system",
        }
    }

    pub fn actor_id(&self) -> String {
        match self {
            Actor::UserUi { session_id } => session_id.clone(),
            Actor::Agent { token_id } => token_id.clone(),
            Actor::CliUser => "cli".to_string(),
            Actor::System { component } => component.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairPaths {
    pub user_path: String,
    pub agent_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocMeta {
    pub id: Uuid,
    pub title: String,
    pub topic: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub tags: Vec<String>,
    pub links_out: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    pub pair: PairPaths,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    pub title: String,
    pub status: String,
    pub priority: Option<String>,
    pub due_at: Option<DateTime<Utc>>,
    pub topic: Option<String>,
    pub doc_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,

    // Scheduling / automation groundwork
    pub earliest_start_at: Option<DateTime<Utc>>,
    pub snooze_until: Option<DateTime<Utc>>,

    // Worker lease
    pub lease_owner: Option<String>,
    pub lease_expires_at: Option<DateTime<Utc>>,

    // Dome queue / verification model
    pub queue_lane: String,
    pub queue_order: Option<i64>,
    #[serde(default)]
    pub success_criteria: Vec<String>,
    pub verification_hint: Option<String>,
    pub verification_summary: Option<String>,
    pub archived_at: Option<DateTime<Utc>>,
    pub merged_into_task_id: Option<String>,
    pub verified_by_run_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskEditHandoff {
    pub handoff_id: String,
    pub task_id: String,
    pub doc_id: Option<String>,
    pub status: String,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub claimed_at: Option<DateTime<Utc>>,
    pub claimed_by: Option<String>,
    pub completed_at: Option<DateTime<Utc>>,
    pub completed_by: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocPlanHandoff {
    pub handoff_id: String,
    pub doc_id: String,
    pub status: String,
    pub reason: String,
    pub requested_user_updated_at: DateTime<Utc>,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub claimed_at: Option<DateTime<Utc>>,
    pub claimed_by: Option<String>,
    pub completed_at: Option<DateTime<Utc>>,
    pub completed_by: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunRecord {
    pub id: String,
    pub source: String,
    pub status: String,
    pub summary: String,
    pub automation_id: Option<String>,
    pub occurrence_id: Option<String>,
    pub task_id: Option<String>,
    pub doc_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub ended_at: Option<DateTime<Utc>>,
    pub error_kind: Option<String>,
    pub error_message: Option<String>,
    pub agent_brand: Option<String>,
    pub agent_name: Option<String>,
    pub agent_session_id: Option<String>,
    pub adapter_kind: Option<String>,
    pub craftship_session_id: Option<String>,
    pub craftship_session_node_id: Option<String>,
    pub company_id: Option<String>,
    pub agent_id: Option<String>,
    pub goal_id: Option<String>,
    pub ticket_id: Option<String>,

    // Deprecated aliases kept for OpenClaw compatibility during migration.
    pub openclaw_session_id: Option<String>,
    pub openclaw_agent_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunArtifact {
    pub id: String,
    pub run_id: String,
    pub kind: String,
    pub path: Option<String>,
    pub content_inline: Option<String>,
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub meta_json: Option<serde_json::Value>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationRecord {
    pub id: String,
    pub executor_kind: String,
    pub executor_config_json: serde_json::Value,
    pub title: String,
    pub prompt_template: String,
    pub doc_id: Option<String>,
    pub task_id: Option<String>,
    pub shared_context_key: Option<String>,
    pub schedule_kind: String,
    pub schedule_json: serde_json::Value,
    pub retry_policy_json: serde_json::Value,
    pub concurrency_policy: String,
    pub timezone: String,
    pub enabled: bool,
    pub company_id: Option<String>,
    pub goal_id: Option<String>,
    pub brand_id: Option<String>,
    pub adapter_kind: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub paused_at: Option<DateTime<Utc>>,
    pub last_planned_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationOccurrence {
    pub id: String,
    pub automation_id: String,
    pub attempt: i64,
    pub trigger_reason: String,
    pub planned_at: DateTime<Utc>,
    pub ready_at: Option<DateTime<Utc>>,
    pub leased_at: Option<DateTime<Utc>>,
    pub started_at: Option<DateTime<Utc>>,
    pub finished_at: Option<DateTime<Utc>>,
    pub status: String,
    pub dedupe_key: String,
    pub lease_owner: Option<String>,
    pub lease_expires_at: Option<DateTime<Utc>>,
    pub last_heartbeat_at: Option<DateTime<Utc>>,
    pub run_id: Option<String>,
    pub failure_kind: Option<String>,
    pub failure_message: Option<String>,
    pub retry_count: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerCursor {
    pub worker_id: String,
    pub consumer_group: String,
    pub executor_kind: String,
    pub last_event_id: i64,
    pub last_heartbeat_at: DateTime<Utc>,
    pub status: String,
    pub lease_count: i64,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunEvaluation {
    pub run_id: String,
    pub quality_score: f64,
    pub completion_class: String,
    pub intervention_count: i64,
    pub retry_count: i64,
    pub lateness_seconds: i64,
    pub evaluated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SharedContextRecord {
    pub context_key: String,
    pub automation_id: Option<String>,
    pub latest_run_id: Option<String>,
    pub latest_occurrence_id: Option<String>,
    pub state_json: serde_json::Value,
    pub artifact_path: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextPackRecord {
    pub context_id: String,
    pub brand: String,
    pub session_id: Option<String>,
    pub doc_id: Option<String>,
    pub status: String,
    pub source_hash: String,
    pub token_estimate: i64,
    pub citation_count: i64,
    pub unresolved_citation_count: i64,
    pub previous_context_id: Option<String>,
    pub manifest_path: String,
    pub summary_path: String,
    pub created_at: DateTime<Utc>,
    pub superseded_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextPackSourceRecord {
    pub id: Option<i64>,
    pub context_id: String,
    pub source_kind: String,
    pub source_ref: String,
    pub source_path: Option<String>,
    pub source_hash: String,
    pub source_rank: i64,
    pub locator_json: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentContextEventRecord {
    pub event_id: String,
    pub agent_name: Option<String>,
    pub session_id: Option<String>,
    pub project_id: Option<String>,
    pub event_kind: String,
    pub context_id: Option<String>,
    pub node_id: Option<String>,
    pub reason: Option<String>,
    pub payload_json: serde_json::Value,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChainOfThoughtConfig {
    pub autonomy_level: String,
    pub workflow_order: String,
    pub priority_focus: String,
    pub planning_depth: String,
    pub research_preference: String,
    #[serde(default = "default_chain_of_thought_set_pillar")]
    pub set_pillar: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChainOfKnowledgeConfig {
    pub focus_mode: String,
    pub allowed_knowledge: Vec<String>,
    pub blocked_knowledge: Vec<String>,
}

fn default_chain_of_thought_set_pillar() -> String {
    "knowledge_notes_calendar".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CraftingFramework {
    pub framework_id: String,
    pub name: String,
    pub custom_instruction: String,
    pub enhanced_instruction: String,
    pub chain_of_thought: ChainOfThoughtConfig,
    pub chain_of_knowledge: ChainOfKnowledgeConfig,
    pub archived: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub enhancement_version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Craftship {
    pub craftship_id: String,
    pub name: String,
    pub necessity: String,
    pub mode: String,
    pub archived: bool,
    /// When true, `craftship_session_launch` synthesizes a Required-Steps
    /// agent that receives the required-steps payload first and dispatches
    /// the synthesized plan to the Lead agent via acpx. When false, the
    /// Lead agent receives the prompt directly with an "analyze `user.md`
    /// first" preamble prepended.
    pub required_agent_enabled: bool,
    /// Brand of the Required-Steps agent. Restricted to the three brands
    /// validated by `validate_required_agent_brand`: codex, claude_code,
    /// openclaw. Kept even when `required_agent_enabled == false` so the
    /// user's selection survives toggle cycles.
    pub required_agent_brand: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CraftshipNode {
    pub node_id: String,
    pub craftship_id: String,
    pub parent_node_id: Option<String>,
    pub label: String,
    pub node_kind: String,
    pub framework_id: Option<String>,
    pub brand_id: Option<String>,
    pub sort_order: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CraftshipSession {
    pub craftship_session_id: String,
    pub craftship_id: String,
    pub name: String,
    pub status: String,
    pub launch_mode: String,
    pub runtime_brand: String,
    pub doc_id: Option<String>,
    pub source_doc_id: Option<String>,
    pub last_context_pack_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CraftshipSessionNode {
    pub session_node_id: String,
    pub craftship_session_id: String,
    pub template_node_id: Option<String>,
    pub parent_session_node_id: Option<String>,
    pub label: String,
    pub framework_id: Option<String>,
    pub brand_id: Option<String>,
    pub terminal_ref: Option<String>,
    pub run_id: Option<String>,
    pub worktree_path: Option<String>,
    pub branch_name: Option<String>,
    pub event_cursor: Option<i64>,
    pub presence: Option<String>,
    pub agent_name: Option<String>,
    pub agent_token_id: Option<String>,
    pub status: String,
    pub sort_order: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CraftshipTeamWorkItem {
    pub work_item_id: String,
    pub craftship_session_id: String,
    pub source_task_id: Option<String>,
    pub created_by_session_node_id: Option<String>,
    pub assigned_session_node_id: Option<String>,
    pub status: String,
    pub title: String,
    pub description_md: Option<String>,
    #[serde(default)]
    pub success_criteria: Vec<String>,
    pub verification_hint: Option<String>,
    pub result_summary: Option<String>,
    pub worktree_ref: Option<String>,
    pub branch_name: Option<String>,
    #[serde(default)]
    pub changed_files: Vec<String>,
    pub commit_hash: Option<String>,
    pub claimed_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CraftshipTeamMessage {
    pub message_id: String,
    pub craftship_session_id: String,
    pub sender_session_node_id: Option<String>,
    pub message_kind: String,
    pub subject: Option<String>,
    pub body_md: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CraftshipTeamMessageReceipt {
    pub receipt_id: String,
    pub message_id: String,
    pub recipient_session_node_id: String,
    pub state: String,
    pub delivered_at: Option<DateTime<Utc>>,
    pub acknowledged_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CraftshipTeamInboxEntry {
    pub message: CraftshipTeamMessage,
    pub receipt: CraftshipTeamMessageReceipt,
    pub sender_label: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BrandRecord {
    pub brand_id: String,
    pub label: String,
    pub adapter_kind: String,
    pub enabled: bool,
    pub metadata_json: serde_json::Value,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdapterRecord {
    pub adapter_kind: String,
    pub display_name: String,
    pub enabled: bool,
    pub config_json: serde_json::Value,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompanyRecord {
    pub company_id: String,
    pub name: String,
    pub mission: String,
    pub active: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentRecord {
    pub agent_id: String,
    pub company_id: String,
    pub display_name: String,
    pub role_title: String,
    pub role_description: String,
    pub manager_agent_id: Option<String>,
    pub brand_id: String,
    pub adapter_kind: String,
    pub runtime_mode: String,
    pub budget_monthly_cap_usd: f64,
    pub budget_warn_percent: f64,
    pub state: String,
    pub policy_json: serde_json::Value,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub paused_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GoalRecord {
    pub goal_id: String,
    pub company_id: String,
    pub parent_goal_id: Option<String>,
    pub kind: String,
    pub title: String,
    pub description: String,
    pub status: String,
    pub owner_agent_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TicketRecord {
    pub ticket_id: String,
    pub company_id: String,
    pub goal_id: Option<String>,
    pub task_id: Option<String>,
    pub title: String,
    pub status: String,
    pub priority: Option<String>,
    pub assigned_agent_id: Option<String>,
    pub current_run_id: Option<String>,
    pub plan_required: bool,
    pub plan_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TicketThreadMessage {
    pub message_id: String,
    pub ticket_id: String,
    pub run_id: Option<String>,
    pub actor_type: String,
    pub actor_id: String,
    pub body_md: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TicketDecision {
    pub decision_id: String,
    pub ticket_id: String,
    pub run_id: Option<String>,
    pub decision_type: String,
    pub decision_text: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TicketToolTrace {
    pub trace_id: String,
    pub ticket_id: String,
    pub run_id: Option<String>,
    pub tool_name: String,
    pub input_json: serde_json::Value,
    pub output_json: serde_json::Value,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BudgetUsageEntry {
    pub usage_id: String,
    pub company_id: String,
    pub agent_id: String,
    pub run_id: Option<String>,
    pub month_key: String,
    pub usd_cost: f64,
    pub source: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BudgetOverrideRecord {
    pub override_id: String,
    pub company_id: String,
    pub agent_id: String,
    pub reason: String,
    pub approved_by: String,
    pub active: bool,
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanRecord {
    pub plan_id: String,
    pub company_id: String,
    pub ticket_id: Option<String>,
    pub task_id: Option<String>,
    pub agent_id: Option<String>,
    pub status: String,
    pub plan_path: String,
    pub latest_revision: i64,
    pub submitted_by: Option<String>,
    pub approved_by: Option<String>,
    pub approved_at: Option<DateTime<Utc>>,
    pub review_note: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanRevisionRecord {
    pub revision_id: String,
    pub plan_id: String,
    pub revision_number: i64,
    pub file_path: String,
    pub content_md: String,
    pub submitted_by: String,
    pub submitted_at: DateTime<Utc>,
    pub review_status: String,
    pub review_comment: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GovernanceApproval {
    pub approval_id: String,
    pub company_id: String,
    pub subject_type: String,
    pub subject_id: String,
    pub action: String,
    pub payload_json: serde_json::Value,
    pub requested_by: String,
    pub status: String,
    pub reviewed_by: Option<String>,
    pub reviewed_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigRevision {
    pub revision_id: String,
    pub company_id: String,
    pub config_scope: String,
    pub config_json: serde_json::Value,
    pub previous_revision_id: Option<String>,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Suggestion {
    pub id: String,
    pub doc_id: String,
    pub format: String,
    pub patch: serde_json::Value,
    pub summary: String,
    pub status: String,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
    pub applied_at: Option<DateTime<Utc>>,
    pub rejected_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenRecord {
    pub token_id: String,
    pub agent_name: String,
    pub token_hash: String,
    pub token_salt: String,
    pub caps: Vec<String>,
    pub created_at: DateTime<Utc>,
    pub last_used_at: Option<DateTime<Utc>>,
    pub revoked: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VaultCraftingConfig {
    #[serde(default)]
    pub default_craftship_id: Option<String>,
}

impl Default for VaultCraftingConfig {
    fn default() -> Self {
        Self {
            default_craftship_id: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VaultConfig {
    #[serde(default = "default_config_schema_version")]
    pub schema_version: u32,
    #[serde(default)]
    pub allow_agent_apply_suggestions: bool,
    #[serde(default)]
    pub tokens: Vec<TokenRecord>,
    #[serde(default)]
    pub crafting: VaultCraftingConfig,
}

impl Default for VaultConfig {
    fn default() -> Self {
        Self {
            schema_version: default_config_schema_version(),
            allow_agent_apply_suggestions: false,
            tokens: Vec::new(),
            crafting: VaultCraftingConfig::default(),
        }
    }
}

fn default_config_schema_version() -> u32 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocRecord {
    pub id: String,
    pub topic: String,
    pub slug: String,
    pub title: String,
    pub user_path: String,
    pub agent_path: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub owner_scope: String,
    pub project_id: Option<String>,
    pub project_root: Option<String>,
    pub knowledge_kind: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocMetaRecord {
    pub doc_id: String,
    pub tags: Vec<String>,
    pub links_out: Vec<String>,
    pub status: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GraphNodeRecord {
    pub node_id: String,
    pub kind: String,
    pub ref_id: String,
    pub label: String,
    pub secondary_label: Option<String>,
    pub group_key: String,
    pub search_text: String,
    pub sort_time: Option<DateTime<Utc>>,
    pub payload: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GraphEdgeRecord {
    pub edge_id: String,
    pub kind: String,
    pub source_id: String,
    pub target_id: String,
    pub search_text: String,
    pub sort_time: Option<DateTime<Utc>>,
    pub payload: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub doc_id: String,
    pub scope: String,
    pub topic: String,
    pub title: String,
    pub excerpt: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventRecord {
    pub event_id: i64,
    pub ts: DateTime<Utc>,
    pub r#type: String,
    pub actor_type: String,
    pub actor_id: String,
    pub doc_id: Option<String>,
    pub run_id: Option<String>,
    pub payload: serde_json::Value,
    pub dedupe_key: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEntry {
    pub ts: DateTime<Utc>,
    pub actor_type: String,
    pub actor_id: String,
    pub action: String,
    pub args_hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub doc_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    pub result: String,
    pub details: serde_json::Value,
}
