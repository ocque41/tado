//! Tiny placeholder substitution for retrieval-recipe templates.
//!
//! Supports two forms only:
//!
//! - `{{ var_name }}` — looks up `var_name` in the supplied context;
//!   inserts the empty string if missing.
//! - `{{ var_name | bullets(N) }}` — `var_name` is expected to be a
//!   list of strings; renders the first N as `  - <line>` markdown
//!   bullets joined by `\n`. When the list is shorter than N we
//!   render what's there. When it's empty we render `  - _none_`.
//!
//! Why hand-rolled: a real template engine (Tera / Handlebars) would
//! double bt-core's compile time and we'd never use 5% of the
//! features. Templates are short, and the scope is fixed by Phase 5.
//!
//! Templates that need richer logic should be hand-edited per
//! project — the recipe table holds the path, so users can swap
//! the file freely without touching code.

use std::collections::HashMap;

/// One rendering input: either a scalar string or a list of strings.
#[derive(Debug, Clone)]
pub enum TemplateValue {
    Scalar(String),
    List(Vec<String>),
}

/// The render context — keyed by placeholder name.
pub type TemplateContext = HashMap<String, TemplateValue>;

/// Render a template body. Failures (unknown filter, unbalanced
/// braces) emit literal text so the caller never panics on a
/// malformed template.
pub fn render(body: &str, ctx: &TemplateContext) -> String {
    let mut out = String::with_capacity(body.len());
    let bytes = body.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        // Look for the next "{{".
        if i + 1 < bytes.len() && bytes[i] == b'{' && bytes[i + 1] == b'{' {
            if let Some(rel_close) = body[i + 2..].find("}}") {
                let inner = &body[i + 2..i + 2 + rel_close];
                let rendered = render_one(inner.trim(), ctx);
                out.push_str(&rendered);
                i = i + 2 + rel_close + 2;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

fn render_one(expr: &str, ctx: &TemplateContext) -> String {
    let parts: Vec<&str> = expr.split('|').map(str::trim).collect();
    let var_name = parts[0];
    let value = ctx.get(var_name);

    if parts.len() == 1 {
        return match value {
            Some(TemplateValue::Scalar(s)) => s.clone(),
            Some(TemplateValue::List(items)) => items.join("\n"),
            None => String::new(),
        };
    }

    let filter = parts[1];
    if let Some(arg) = filter
        .strip_prefix("bullets(")
        .and_then(|rest| rest.strip_suffix(')'))
    {
        let n: usize = arg.trim().parse().unwrap_or(5);
        let items: Vec<String> = match value {
            Some(TemplateValue::List(items)) => items.clone(),
            Some(TemplateValue::Scalar(s)) => vec![s.clone()],
            None => Vec::new(),
        };
        if items.is_empty() {
            return "  - _none_".to_string();
        }
        let take = items.iter().take(n);
        return take.map(|line| format!("  - {line}")).collect::<Vec<_>>().join("\n");
    }

    // Unknown filter — render the raw value.
    match value {
        Some(TemplateValue::Scalar(s)) => s.clone(),
        Some(TemplateValue::List(items)) => items.join("\n"),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> TemplateContext {
        let mut c = TemplateContext::new();
        c.insert("project".into(), TemplateValue::Scalar("Tado".into()));
        c.insert(
            "items".into(),
            TemplateValue::List(vec!["one".into(), "two".into(), "three".into()]),
        );
        c
    }

    #[test]
    fn renders_scalars() {
        let out = render("Hello {{ project }}!", &ctx());
        assert_eq!(out, "Hello Tado!");
    }

    #[test]
    fn renders_bullets_filter() {
        let out = render("{{ items | bullets(2) }}", &ctx());
        assert_eq!(out, "  - one\n  - two");
    }

    #[test]
    fn renders_bullets_with_short_list_renders_all() {
        let out = render("{{ items | bullets(10) }}", &ctx());
        assert_eq!(out, "  - one\n  - two\n  - three");
    }

    #[test]
    fn empty_list_renders_none() {
        let mut c = TemplateContext::new();
        c.insert("items".into(), TemplateValue::List(vec![]));
        let out = render("{{ items | bullets(3) }}", &c);
        assert_eq!(out, "  - _none_");
    }

    #[test]
    fn unknown_var_renders_empty_string() {
        let out = render("[{{ ghost }}]", &TemplateContext::new());
        assert_eq!(out, "[]");
    }

    #[test]
    fn unbalanced_braces_pass_through() {
        let out = render("hello {{ project no close", &ctx());
        assert_eq!(out, "hello {{ project no close");
    }

    #[test]
    fn nested_braces_only_consume_outer() {
        let out = render("{{ project }} ok", &ctx());
        assert_eq!(out, "Tado ok");
    }
}
