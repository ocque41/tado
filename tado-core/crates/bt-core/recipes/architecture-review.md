## Architecture review — `{{ intent_key }}`

This is a governed retrieval pack. Use it before making
architecture decisions in this project. The retrieval policy
filters to `decision`, `intent`, and `retro` graph_nodes in scope
`{{ scope }}`, demoting anything older than 60 days via the
freshness reranker.

### Top decisions
{{ top_decisions | bullets(5) }}

### Outstanding intents
{{ outstanding_intents | bullets(5) }}

### Recent retros
{{ recent_retros | bullets(3) }}

### All citations
{{ all_citations | bullets(8) }}

### Missing authority

If the lists above are sparse or the project has shipped recently
without a matching `decision` retro, those gaps surface here:

{{ missing_authority | bullets(5) }}

---

**How to use this pack:** treat each citation as a load-bearing
fact. If you're about to override or contradict one, call
`dome_supersede` with the new node id so the next agent inherits
the chain.
