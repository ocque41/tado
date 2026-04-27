//! Phase 5 — retrieval recipes (Tado's analog of Knowledge Catalog
//! "verified queries").
//!
//! A recipe is an intent-keyed retrieval policy + a markdown template.
//! Agents call `dome_recipe_apply { intent_key }` and receive a
//! [`GovernedAnswer`] — synthesized markdown with citations,
//! confidence, and explicit "missing authority" flags. The synthesis
//! is deterministic (template-rendered) — no LLM in the loop.
//!
//! Three modules:
//! - [`runner`] — execute a policy → ranked hits → render template.
//! - [`template`] — tiny placeholder substitution: `{{ var }}` plus
//!   one filter (`| bullets(N)`).
//! - public types — [`RetrievalRecipe`], [`RetrievalPolicy`],
//!   [`GovernedAnswer`].

use crate::error::BtError;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

pub mod runner;
pub mod template;

pub use runner::{apply_recipe, list_recipes};

/// Retrieval policy a recipe applies. Mirrors what the v0.10 plan
/// called the recipe's "scoping & ranking knobs".
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetrievalPolicy {
    /// Topics to search. Empty = global (all topics).
    #[serde(default)]
    pub topics: Vec<String>,
    /// `graph_node` kinds to keep (`'decision' | 'intent' | 'retro' | …`).
    /// Empty = no filter.
    #[serde(default)]
    pub knowledge_kinds: Vec<String>,
    /// `'global' | 'project' | 'merged'`.
    #[serde(default = "default_knowledge_scope")]
    pub knowledge_scope: String,
    /// Hits older than this in the freshness reranker get heavily
    /// demoted. Defaults to 60 days.
    #[serde(default = "default_freshness_decay_days")]
    pub freshness_decay_days: u32,
    /// Soft cap on tokens (4 chars/token estimate) before the
    /// renderer truncates the answer.
    #[serde(default = "default_max_tokens")]
    pub max_tokens: u32,
    /// Hits below this combined_score threshold land in the
    /// `missing_authority` list instead of the citation set.
    #[serde(default = "default_min_combined_score")]
    pub min_combined_score: f32,
    /// Hard cap on number of hits surfaced.
    #[serde(default = "default_top_k")]
    pub top_k: u32,
}

fn default_knowledge_scope() -> String {
    "merged".into()
}
fn default_freshness_decay_days() -> u32 {
    60
}
fn default_max_tokens() -> u32 {
    1200
}
fn default_min_combined_score() -> f32 {
    0.05
}
fn default_top_k() -> u32 {
    8
}

impl Default for RetrievalPolicy {
    fn default() -> Self {
        Self {
            topics: Vec::new(),
            knowledge_kinds: Vec::new(),
            knowledge_scope: default_knowledge_scope(),
            freshness_decay_days: default_freshness_decay_days(),
            max_tokens: default_max_tokens(),
            min_combined_score: default_min_combined_score(),
            top_k: default_top_k(),
        }
    }
}

/// One row of `retrieval_recipes` plus its loaded template body.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetrievalRecipe {
    pub recipe_id: String,
    pub intent_key: String,
    pub scope: String,
    pub project_id: Option<String>,
    pub title: String,
    pub description: String,
    pub template_path: String,
    pub policy: RetrievalPolicy,
    pub enabled: bool,
    pub last_verified_at: Option<String>,
    /// Loaded template body (markdown with `{{ var }}` placeholders).
    /// Lazily filled by [`runner::apply_recipe`] right before rendering.
    pub template_body: Option<String>,
}

/// Synthesized response returned by `dome_recipe_apply`. Mirrors the
/// "governed answer" shape from Google's Knowledge Catalog: a
/// rendered markdown answer + the citation list it cites + an
/// explicit "what we couldn't find" flag.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GovernedAnswer {
    pub intent_key: String,
    pub answer: String,
    pub citations: Vec<Citation>,
    pub missing_authority: Vec<String>,
    pub policy_applied: RetrievalPolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Citation {
    pub doc_id: String,
    pub title: String,
    pub topic: String,
    pub scope: String,
    pub confidence: f32,
    pub freshness: f32,
}

/// Insert / update a recipe. Used by bootstrap-time seeding.
pub fn upsert_recipe(conn: &Connection, recipe: &RetrievalRecipe) -> Result<(), BtError> {
    let policy_json =
        serde_json::to_string(&recipe.policy).map_err(|e| BtError::Validation(e.to_string()))?;
    conn.execute(
        r#"INSERT INTO retrieval_recipes(
            recipe_id, intent_key, scope, project_id,
            title, description, template_path,
            retrieval_policy_json, enabled, last_verified_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT(intent_key, scope, COALESCE(project_id, '')) DO UPDATE SET
            title = excluded.title,
            description = excluded.description,
            template_path = excluded.template_path,
            retrieval_policy_json = excluded.retrieval_policy_json,
            enabled = excluded.enabled,
            last_verified_at = excluded.last_verified_at,
            updated_at = datetime('now')"#,
        params![
            recipe.recipe_id,
            recipe.intent_key,
            recipe.scope,
            recipe.project_id,
            recipe.title,
            recipe.description,
            recipe.template_path,
            policy_json,
            if recipe.enabled { 1 } else { 0 },
            recipe.last_verified_at,
        ],
    )?;
    Ok(())
}

/// Load recipes from `retrieval_recipes` matching the resolution
/// rules: prefer project-scoped + `enabled=1`; fall back to global.
pub fn load_recipes(
    conn: &Connection,
    intent_key: Option<&str>,
    scope: Option<&str>,
    project_id: Option<&str>,
) -> Result<Vec<RetrievalRecipe>, BtError> {
    let mut sql = String::from(
        r#"SELECT recipe_id, intent_key, scope, project_id, title,
                   description, template_path, retrieval_policy_json,
                   enabled, last_verified_at
            FROM retrieval_recipes
            WHERE enabled = 1"#,
    );
    if intent_key.is_some() {
        sql.push_str(" AND intent_key = ?1");
    }
    let mut bound = Vec::new();
    if let Some(k) = intent_key {
        bound.push(k.to_string());
    }
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(bound.iter().map(|s| s.as_str())), |row| {
        let policy_json: String = row.get(7)?;
        let policy: RetrievalPolicy = serde_json::from_str(&policy_json).unwrap_or_default();
        Ok(RetrievalRecipe {
            recipe_id: row.get(0)?,
            intent_key: row.get(1)?,
            scope: row.get(2)?,
            project_id: row.get(3)?,
            title: row.get(4)?,
            description: row.get(5)?,
            template_path: row.get(6)?,
            policy,
            enabled: row.get::<_, i64>(8)? != 0,
            last_verified_at: row.get(9)?,
            template_body: None,
        })
    })?;
    let all: Vec<RetrievalRecipe> = rows.collect::<Result<_, _>>()?;
    // Resolution: prefer project-scoped match; fall back to global.
    // Two passes so DB iteration order doesn't change the outcome.
    let project_match = scope.unwrap_or("project") == "project" && project_id.is_some();
    if project_match {
        let mut seen_project_keys: std::collections::HashSet<String> = Default::default();
        for r in &all {
            if r.project_id.as_deref() == project_id {
                seen_project_keys.insert(r.intent_key.clone());
            }
        }
        let chosen: Vec<RetrievalRecipe> = all
            .into_iter()
            .filter(|r| {
                if r.project_id.as_deref() == project_id {
                    return true;
                }
                if r.scope == "global" && !seen_project_keys.contains(&r.intent_key) {
                    return true;
                }
                false
            })
            .collect();
        return Ok(chosen);
    }
    // Otherwise just return what matched.
    Ok(all)
}

/// Default recipe definitions baked into the app. Used by Phase 5's
/// bootstrap action to seed every fresh project. Returns a tuple of
/// `(intent_key, title, description, policy, template_body)`.
pub fn default_recipes() -> Vec<(&'static str, &'static str, &'static str, RetrievalPolicy, &'static str)> {
    vec![
        (
            "architecture-review",
            "Architecture review",
            "Used when an agent is about to make an architecture decision. Surfaces prior decisions, outstanding intents, and recent retros so the agent doesn't re-derive context.",
            RetrievalPolicy {
                topics: vec![],
                knowledge_kinds: vec!["decision".into(), "intent".into(), "retro".into()],
                knowledge_scope: "merged".into(),
                freshness_decay_days: 60,
                max_tokens: 1200,
                min_combined_score: 0.05,
                top_k: 8,
            },
            include_str!("../../recipes/architecture-review.md"),
        ),
        (
            "completion-claim",
            "Completion claim",
            "Used when an agent is about to claim a feature is shipped. Surfaces outcomes, retros, and recent activity so the agent verifies before claiming.",
            RetrievalPolicy {
                topics: vec![],
                knowledge_kinds: vec!["outcome".into(), "retro".into(), "decision".into()],
                knowledge_scope: "project".into(),
                freshness_decay_days: 30,
                max_tokens: 1000,
                min_combined_score: 0.05,
                top_k: 6,
            },
            include_str!("../../recipes/completion-claim.md"),
        ),
        (
            "team-handoff",
            "Team handoff",
            "Used when an agent is about to delegate to or accept work from a teammate. Surfaces team-scoped notes plus the latest run retros.",
            RetrievalPolicy {
                topics: vec![],
                knowledge_kinds: vec!["decision".into(), "retro".into()],
                knowledge_scope: "merged".into(),
                freshness_decay_days: 14,
                max_tokens: 800,
                min_combined_score: 0.05,
                top_k: 6,
            },
            include_str!("../../recipes/team-handoff.md"),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mem_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::migrations::migrate(&conn).unwrap();
        conn
    }

    #[test]
    fn upsert_and_load_round_trip() {
        let conn = mem_db();
        let recipe = RetrievalRecipe {
            recipe_id: "rec1".into(),
            intent_key: "architecture-review".into(),
            scope: "global".into(),
            project_id: None,
            title: "Architecture review".into(),
            description: "Test".into(),
            template_path: ".tado/verified-prompts/architecture-review.md".into(),
            policy: RetrievalPolicy::default(),
            enabled: true,
            last_verified_at: None,
            template_body: None,
        };
        upsert_recipe(&conn, &recipe).unwrap();
        let loaded = load_recipes(&conn, Some("architecture-review"), Some("global"), None).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].title, "Architecture review");
    }

    #[test]
    fn upsert_overwrites_existing() {
        let conn = mem_db();
        let mut recipe = RetrievalRecipe {
            recipe_id: "rec1".into(),
            intent_key: "x".into(),
            scope: "global".into(),
            project_id: None,
            title: "v1".into(),
            description: "".into(),
            template_path: "p".into(),
            policy: RetrievalPolicy::default(),
            enabled: true,
            last_verified_at: None,
            template_body: None,
        };
        upsert_recipe(&conn, &recipe).unwrap();
        recipe.title = "v2".into();
        upsert_recipe(&conn, &recipe).unwrap();
        let loaded = load_recipes(&conn, Some("x"), None, None).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].title, "v2");
    }

    #[test]
    fn project_scope_wins_over_global() {
        let conn = mem_db();
        upsert_recipe(
            &conn,
            &RetrievalRecipe {
                recipe_id: "rec_g".into(),
                intent_key: "x".into(),
                scope: "global".into(),
                project_id: None,
                title: "global".into(),
                description: "".into(),
                template_path: "p".into(),
                policy: RetrievalPolicy::default(),
                enabled: true,
                last_verified_at: None,
                template_body: None,
            },
        )
        .unwrap();
        upsert_recipe(
            &conn,
            &RetrievalRecipe {
                recipe_id: "rec_p".into(),
                intent_key: "x".into(),
                scope: "project".into(),
                project_id: Some("proj-1".into()),
                title: "project-specific".into(),
                description: "".into(),
                template_path: "p".into(),
                policy: RetrievalPolicy::default(),
                enabled: true,
                last_verified_at: None,
                template_body: None,
            },
        )
        .unwrap();
        let loaded = load_recipes(&conn, Some("x"), Some("project"), Some("proj-1")).unwrap();
        let titles: Vec<&str> = loaded.iter().map(|r| r.title.as_str()).collect();
        assert!(titles.contains(&"project-specific"));
        // Global should be eclipsed by the project-specific match.
        assert_eq!(titles.iter().filter(|t| **t == "global").count(), 0);
    }
}
