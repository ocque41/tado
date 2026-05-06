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

• Qwen3 embeddings, in-process on Metal
• Hybrid search — vector + FTS, reranked by freshness and scope
• Tree-sitter code indexing with a live file watcher
• Knowledge graph — decisions, intents, retros — auto-extracted

Every spawn wakes up oriented.
```

(271 chars.)

---

## Post 4 / 5  (the long-running ops)

```
For long-running work:

• Eternal — sprint or mega loops, normal or continuous
• Dispatch — write a brief, an architect plans the phases
• Perf step — a same-turn pay-back gate, 8 device-independent metrics, ratcheting baseline

It refuses to ship a regression.
```

(261 chars.)

---

## Post 5 / 5  (Tado Use + Tado Pets — newest in 1.0.0)

```
Two more landing in 1.0.0:

Tado Use — Cmd+Shift+U opens a chat drawer. A headless Claude agent drives the app via 65+ MCP and bridge tools. You talk, Tado moves.

Tado Pets — a pixel-art companion floats over every Space, mirroring agent state.

https://github.com/ocque41/tado
```

(278 chars including the URL.)

### Feature breakdown — Tado Use

- Cmd+Shift+U opens a left-edge slide-in chat drawer
- Headless `claude -p` agent in the loop, no terminal tile needed
- Calls all 30 dome-mcp + tado-mcp tools plus 35+ in-process bridge tools
- Streams turns with a per-token live row + throttled auto-scroll
  (~6 Hz, suppressed when you scroll away from the bottom)
- Inherits the live engine / model / effort / permission-mode
  from the same `AppSettings` row canvas tiles spawn from
- Body font follows your terminal-font setting; chrome stays
  on Plus Jakarta Sans
- Auto-registers a stdio bridge so the agent can read app state
  and dispatch commands without going through a PTY

### Feature breakdown — Tado Pets

- Animated pixel-art companion on a borderless `NSPanel`
- Always-on-top, floats across every macOS Space
- Mirrors live state of sessions, Eternal runs, Dispatch runs,
  the perf gate — busiest-state-wins resolution
- Click-to-expand popover: per-project, per-feature breakdown
- `/pet` slash command toggles visibility
- `/hatch <prompt>` opens the hatch sheet pre-filled
- Sprite-sheet importer (`Import pet from folder…`) auto-slices
  frames and registers the new pet via `tado_pets_register`
- Dedicated settings window from the Extensions page

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
