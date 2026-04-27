## Completion claim — `{{ intent_key }}`

You're about to claim something is shipped, complete, or verified.
This pack surfaces the recent outcomes, retros, and decisions
that should already exist if the claim is true. The retrieval
policy filters to `outcome`, `retro`, and `decision` graph_nodes
in scope `{{ scope }}`, with a 30-day freshness window.

### Recent outcomes
{{ recent_outcomes | bullets(5) }}

### Recent retros
{{ recent_retros | bullets(3) }}

### Top decisions backing the claim
{{ top_decisions | bullets(3) }}

### All citations
{{ all_citations | bullets(6) }}

### Missing authority

If the claim should be backed by an outcome retro and isn't, the
gap surfaces here. **Treat any entry below as a reason to verify
before claiming.**

{{ missing_authority | bullets(5) }}

---

**Contract:** if every cited row's `confidence` is ≥ 0.7 *and* at
least one matching outcome retro exists, the claim is verified.
Otherwise: confirm with `dome_verify` before declaring done, or
flag the gap to the user.
