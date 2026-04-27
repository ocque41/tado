//! Run a retrieval recipe end-to-end.
//!
//! `apply_recipe` is the entry point: looks up the recipe, runs the
//! policy as a `HybridQuery`, separates hits into citations + missing-
//! authority, renders the template, and packages everything as a
//! [`GovernedAnswer`].

use crate::context::relative::format_relative_ago;
use crate::error::BtError;
use crate::notes::{
    freshness_score, hybrid_search, HybridQuery, NoopEmbedder, Qwen3EmbeddingProvider,
    RetrievalCtx, SearchHit,
};
use crate::recipes::{
    load_recipes,
    template::{render, TemplateContext, TemplateValue},
    Citation, GovernedAnswer, RetrievalRecipe,
};
use chrono::Utc;
use rusqlite::{params, Connection};

/// List recipes for the given scope. Returns enabled recipes only,
/// project-scoped ones override globals on shared `intent_key`.
pub fn list_recipes(
    conn: &Connection,
    scope: Option<&str>,
    project_id: Option<&str>,
) -> Result<Vec<RetrievalRecipe>, BtError> {
    load_recipes(conn, None, scope, project_id)
}

/// Apply a recipe — run its policy as a search, render the template
/// with the hits, return a [`GovernedAnswer`].
///
/// `actor`, `embedder_loaded` are passed through so the inner
/// `hybrid_search` writes a `retrieval_log` row tagged with the
/// recipe's intent_key (so `dome-eval replay` can score recipe
/// retrievals separately).
pub fn apply_recipe(
    conn: &Connection,
    intent_key: &str,
    project_id: Option<&str>,
    actor_kind: &str,
    actor_id: Option<&str>,
    embedder_loaded: bool,
) -> Result<GovernedAnswer, BtError> {
    // Load + pick the most-specific match (project-scoped wins via
    // the resolution in `load_recipes`).
    let recipes = load_recipes(
        conn,
        Some(intent_key),
        Some(if project_id.is_some() { "project" } else { "global" }),
        project_id,
    )?;
    let recipe = recipes
        .into_iter()
        .find(|r| r.intent_key == intent_key)
        .ok_or_else(|| {
            BtError::NotFound(format!(
                "no enabled retrieval recipe for intent_key '{intent_key}'"
            ))
        })?;

    let template_body = load_template(conn, &recipe)?;

    // Build the HybridQuery from the policy.
    let topic_filter = recipe.policy.topics.first().cloned();
    let scope_param = match recipe.policy.knowledge_scope.as_str() {
        "global" => "all",
        "project" | "merged" => "all",
        _ => "all",
    };
    let q_text = recipe.title.clone();
    let mut query = HybridQuery::new(q_text.as_str(), scope_param);
    query.topic = topic_filter.as_deref();
    query.limit = recipe.policy.top_k.max(1) as usize;
    query.alpha = if embedder_loaded { 0.6 } else { 0.0 };

    let preferred_scope = match recipe.policy.knowledge_scope.as_str() {
        "project" | "merged" => Some("user".to_string()),
        _ => None,
    };
    let ctx = RetrievalCtx {
        actor_kind: actor_kind.to_string(),
        actor_id: actor_id.map(String::from),
        project_id: project_id.map(String::from),
        knowledge_scope: recipe.policy.knowledge_scope.clone(),
        tool: format!("dome_recipe_apply:{intent_key}"),
        preferred_scope,
        pack_id: None,
    };
    query.ctx = Some(ctx);

    // Run search. NoopEmbedder is the deterministic fallback when the
    // Qwen3 runtime isn't loaded — same fallback the daemon uses.
    let hits: Vec<SearchHit> = if embedder_loaded {
        let provider = Qwen3EmbeddingProvider::default();
        hybrid_search(conn, &query, &provider)?
    } else {
        hybrid_search(conn, &query, &NoopEmbedder)?
    };

    let now = Utc::now();
    let mut citations: Vec<Citation> = Vec::new();
    let mut missing_authority: Vec<String> = Vec::new();
    for hit in &hits {
        let freshness = freshness_score(
            hit.updated_at.as_deref(),
            hit.last_referenced_at.as_deref(),
            hit.created_at.as_deref(),
            now,
        );
        if hit.combined_score < recipe.policy.min_combined_score {
            missing_authority.push(format!(
                "weak match: {} (score {:.3})",
                hit.title, hit.combined_score
            ));
            continue;
        }
        citations.push(Citation {
            doc_id: hit.doc_id.clone(),
            title: hit.title.clone(),
            topic: hit.topic.clone(),
            scope: hit.scope.clone(),
            confidence: hit.confidence.unwrap_or(1.0),
            freshness,
        });
    }
    if citations.is_empty() {
        missing_authority.insert(
            0,
            format!(
                "No enabled recipe entries for intent '{intent_key}' surfaced citations above threshold {}.",
                recipe.policy.min_combined_score
            ),
        );
    }

    // Build the template context.
    let now_for_relative = now;
    let mut tctx = TemplateContext::new();
    tctx.insert(
        "intent_key".into(),
        TemplateValue::Scalar(intent_key.to_string()),
    );
    tctx.insert(
        "project_id".into(),
        TemplateValue::Scalar(project_id.unwrap_or("").to_string()),
    );
    tctx.insert(
        "scope".into(),
        TemplateValue::Scalar(recipe.policy.knowledge_scope.clone()),
    );
    tctx.insert(
        "top_decisions".into(),
        TemplateValue::List(filter_titles(&hits, "decision", &now_for_relative)),
    );
    tctx.insert(
        "outstanding_intents".into(),
        TemplateValue::List(filter_titles(&hits, "intent", &now_for_relative)),
    );
    tctx.insert(
        "recent_outcomes".into(),
        TemplateValue::List(filter_titles(&hits, "outcome", &now_for_relative)),
    );
    tctx.insert(
        "recent_retros".into(),
        TemplateValue::List(filter_titles(&hits, "retro", &now_for_relative)),
    );
    tctx.insert(
        "all_citations".into(),
        TemplateValue::List(
            citations
                .iter()
                .map(|c| format!("`{}` ({}, scope `{}`, confidence {:.2})", c.title, c.topic, c.scope, c.confidence))
                .collect(),
        ),
    );
    tctx.insert(
        "missing_authority".into(),
        TemplateValue::List(missing_authority.clone()),
    );

    let body = render(&template_body, &tctx);
    let answer = truncate_chars(body, recipe.policy.max_tokens.saturating_mul(4) as usize);

    Ok(GovernedAnswer {
        intent_key: intent_key.to_string(),
        answer,
        citations,
        missing_authority,
        policy_applied: recipe.policy.clone(),
    })
}

/// Filter hits by their bound `graph_node` kind. v0.10's
/// `attach_doc_metadata` doesn't surface the kind directly, but the
/// hit's title is enough for a first pass — recipe templates show the
/// title regardless. Future (Phase 6): query `graph_nodes` alongside
/// docs.
///
/// Matching is *prefix-based* on the canonical conventions
/// `Decision: …` / `Intent: …` / `Outcome: …` / `Retro …` (matching
/// what the extractor's heading parser at
/// `enrichment/extractor.rs::detect_headings` and `RunEventWatcher`'s
/// structured retros emit). Loose substring matching here would
/// surface false positives like "Income report" matching the
/// "outcome" filter.
fn filter_titles(hits: &[SearchHit], kind_hint: &str, now: &chrono::DateTime<Utc>) -> Vec<String> {
    hits.iter()
        .filter(|h| {
            let lower = h.title.to_ascii_lowercase();
            // Accept either `Kind: …`, `Kind …`, or a "Retro …" /
            // "Outcome …" prefix — same shapes RunEventWatcher writes.
            let prefixes: &[&str] = match kind_hint {
                "decision" => &["decision:", "decision "],
                "intent" => &["intent:", "intent "],
                "outcome" => &["outcome:", "outcome "],
                "retro" => &["retro:", "retro ", "retro-"],
                _ => return true,
            };
            prefixes.iter().any(|p| lower.starts_with(p))
        })
        .map(|h| {
            let ts = h
                .updated_at
                .as_deref()
                .or(h.created_at.as_deref())
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .map(|dt| dt.with_timezone(&Utc));
            let rel = ts
                .map(|t| format!(" ({})", format_relative_ago(t, *now)))
                .unwrap_or_default();
            format!("`{}`{}", h.title, rel)
        })
        .collect()
}

fn truncate_chars(s: String, max: usize) -> String {
    if s.chars().count() <= max {
        s
    } else {
        s.chars().take(max).collect()
    }
}

/// Resolve the recipe's template body. Tries the on-disk path first
/// (so users can edit `.tado/verified-prompts/<intent>.md` per
/// project); falls back to a simple "no template found" stub when
/// the file is missing.
fn load_template(conn: &Connection, recipe: &RetrievalRecipe) -> Result<String, BtError> {
    if let Some(body) = &recipe.template_body {
        return Ok(body.clone());
    }
    // Try filesystem first — relative paths resolve against the
    // vault root via the `vault_root` column convention. We fetch
    // the project_root from `docs` if the recipe is project-scoped.
    let resolved_path: Option<String> = if let Some(pid) = &recipe.project_id {
        conn.query_row(
            "SELECT project_root FROM docs WHERE project_id = ?1 LIMIT 1",
            params![pid],
            |row| row.get::<_, Option<String>>(0),
        )
        .ok()
        .flatten()
        .map(|root| format!("{}/{}", root, recipe.template_path))
    } else {
        None
    };
    if let Some(p) = resolved_path {
        if let Ok(body) = std::fs::read_to_string(&p) {
            return Ok(body);
        }
    }
    // Fall back to the baked default if this recipe matches one of
    // the shipped intents. Lets every project's agents call the
    // baseline recipes without anything copied to disk.
    for (intent_key, _title, _desc, _policy, body) in crate::recipes::default_recipes() {
        if intent_key == recipe.intent_key {
            return Ok(body.to_string());
        }
    }
    // Last-resort stub. Better than panicking on a malformed recipe.
    Ok(format!(
        "## {title}\n\n{description}\n\n### All citations\n\n{{{{ all_citations | bullets(8) }}}}\n\n### Missing authority\n\n{{{{ missing_authority | bullets(5) }}}}\n",
        title = recipe.title,
        description = recipe.description,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recipes::{upsert_recipe, RetrievalPolicy, RetrievalRecipe};

    fn mem_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        crate::migrations::migrate(&conn).unwrap();
        conn
    }

    fn seed_recipe(conn: &Connection) {
        upsert_recipe(
            conn,
            &RetrievalRecipe {
                recipe_id: "rec1".into(),
                intent_key: "smoke".into(),
                scope: "global".into(),
                project_id: None,
                title: "Smoke recipe".into(),
                description: "Test".into(),
                template_path: ".tado/verified-prompts/smoke.md".into(),
                policy: RetrievalPolicy {
                    knowledge_scope: "global".into(),
                    top_k: 5,
                    min_combined_score: 0.0,
                    ..Default::default()
                },
                enabled: true,
                last_verified_at: None,
                template_body: None,
            },
        )
        .unwrap();
    }

    fn seed_doc(conn: &Connection, doc_id: &str, title: &str, body: &str) {
        let now = Utc::now().to_rfc3339();
        conn.execute(
            r#"INSERT INTO docs(id, topic, slug, title, user_path, agent_path,
                created_at, updated_at, user_hash, agent_hash,
                owner_scope, project_id, project_root, knowledge_kind)
                VALUES (?1, 'inbox', ?1, ?2, 'a.md', 'b.md',
                        ?3, ?3, '0', '0', 'global', NULL, NULL, 'knowledge')"#,
            params![doc_id, title, now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO fts_notes(doc_id, scope, content) VALUES (?1, 'user', ?2)",
            params![doc_id, body],
        )
        .unwrap();
    }

    #[test]
    fn apply_recipe_returns_governed_answer_with_citations() {
        let conn = mem_db();
        seed_recipe(&conn);
        // Recipe title "Smoke recipe" — FTS5 sanitiser ANDs both
        // tokens, so the doc body must contain both "smoke" and
        // "recipe" for a match.
        seed_doc(&conn, "d1", "Decision: smoke testing protocol", "smoke testing recipe in CI");
        let answer = apply_recipe(&conn, "smoke", None, "system", None, false).unwrap();
        assert_eq!(answer.intent_key, "smoke");
        assert!(!answer.citations.is_empty());
        assert!(answer.answer.contains("Smoke recipe"));
    }

    #[test]
    fn apply_recipe_missing_intent_errors() {
        let conn = mem_db();
        let err = apply_recipe(&conn, "nonexistent", None, "system", None, false).unwrap_err();
        assert!(matches!(err, BtError::NotFound(_)));
    }

    #[test]
    fn apply_recipe_returns_missing_authority_when_no_hits() {
        let conn = mem_db();
        seed_recipe(&conn);
        // No docs seeded → no hits.
        let answer = apply_recipe(&conn, "smoke", None, "system", None, false).unwrap();
        assert!(answer.citations.is_empty());
        assert!(!answer.missing_authority.is_empty());
    }
}
