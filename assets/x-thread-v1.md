# Tado v1.0.0 — X thread (5 posts)

**X post limit:** 280 chars. Each post below is hand-counted and fits.
Post 1 carries the GitHub link so the OG card renders; subsequent
posts stay text-only to keep the thread readable.

---

## Post 1 / 5  (link post)

```
Tado v1.0.0 is out.

A macOS canvas where todos spawn AI coding agents. Each row → its own Claude or Codex terminal tile. Pannable, zoomable, with a local second brain that remembers everything.

10 rust crates. 0 cloud calls.

https://github.com/ocque41/tado
```

(279 chars including the URL — fits.)

---

## Post 2 / 5  (the canvas)

```
The canvas:

• Type a todo, get an agent
• Cmd+Tab between list view and grid
• Forward mode — pipe your next message into a running agent
• Idle + prompt detection auto-flags "needs you"
• Metal-rendered terminals. Wide chars, color emoji, retina. 15 themes.
```

(265 chars.)

---

## Post 3 / 5  (the second brain)

```
The second brain:

• Qwen3 embeddings, in-process, on Metal
• Hybrid search — vector + FTS, reranked by freshness, scope, supersede
• Tree-sitter codebase indexing with a live file watcher
• Knowledge graph — decisions, intents, retros — all auto-extracted

Every spawn wakes up oriented.
```

(279 chars.)

---

## Post 4 / 5  (the long-running ops)

```
For long-running work:

• Eternal — sprint or mega loops, normal or continuous
• Dispatch — write a brief, an architect designs the multi-phase plan
• Performance step — a same-turn pay-back gate with 8 device-independent metrics and a per-project ratcheting baseline

It refuses to ship a regression.
```

(279 chars.)

---

## Post 5 / 5  (the foundation)

```
Underneath:

• 10 Rust crates, one libtado_core.a
• 30 MCP tools auto-registered into Claude Code
• Atomic JSON persistence, 5-scope config
• Real-time A2A event socket
• libc::killpg clean shutdown — no orphan processes

Built end to end on top of itself.

https://github.com/ocque41/tado
```

(278 chars including the URL.)

---

## Posting notes

- Post 1 is the only one that needs the URL inline so X renders the
  GitHub OG card with the social-preview image (once you upload it
  via Settings → Social preview — see `assets/social-preview-v1.png`).
- Post 5 repeats the URL because thread tails frequently lose their
  parent's link card when reshared.
- No emojis, no hashtags — matches Tado's editorial-restraint
  brand voice.
- Posts 2-4 are pure text so they read well even when X collapses
  long threads.
