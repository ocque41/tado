## Team handoff — `{{ intent_key }}`

You're about to delegate to or accept work from a teammate. This
pack surfaces the latest team-scoped decisions and retros so
neither side re-derives context. The retrieval policy filters to
`decision` and `retro` graph_nodes in scope `{{ scope }}`, with a
14-day freshness window (handoffs that lean on month-old facts
are usually stale).

### Top decisions to inherit
{{ top_decisions | bullets(5) }}

### Recent retros
{{ recent_retros | bullets(3) }}

### All citations
{{ all_citations | bullets(6) }}

### Missing authority

When a teammate hasn't recorded a recent retro on the work you're
inheriting, the gap surfaces here. Ask before taking over.

{{ missing_authority | bullets(5) }}

---

**Contract:** include the cited node ids in your first
`tado-send <teammate-grid> "..."` so they can `dome_read` what
you saw. If you decide differently from a cited decision, call
`dome_supersede` with your new node id so the chain reflects the
handoff.
