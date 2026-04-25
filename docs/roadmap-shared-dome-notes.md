# Shared `dome-notes` crate — T4 roadmap

Tado's `foundation-v2` branch is eventually going to grow a vector
index over notes (for the Calendar-connected automations and for
Tado-side search). Dome (at `~/Documents/terminal`) already has the
scaffolding: `bt-core/src/notes/` shipped in its D6 phase and
exposes chunker, store, embedder trait, and hybrid search.

This doc captures the plan for sharing that module between the two
repos without copy-pasting. It's a roadmap, not a deliverable — T4
ends here so T5+ can continue, and the submodule work happens when
we know which repo ends up "owning" the crate.

## Shape today

- **Dome repo**: `apps/bt-core/src/notes/` is the canonical
  implementation. Tests are there. CI runs them.
- **Tado repo**: no vector index yet. `tado-core/crates/tado-notes`
  does not exist.

## Option we pick: extract to `dome-notes`

Pull `bt-core/src/notes/` out of Dome into a standalone Rust crate
named `dome-notes`. Both repos path-depend on it via git submodule.

```
dome-notes/                   (standalone repo)
├── Cargo.toml
├── src/
│   ├── lib.rs
│   ├── chunker.rs
│   ├── embeddings.rs
│   ├── search.rs
│   └── store.rs
├── tests/
└── README.md

Dome repo
└── apps/bt-core/
    └── deps include `dome-notes = { path = "crates/dome-notes" }`
        where `crates/dome-notes` is a git submodule pointing at
        the extracted repo at a pinned commit.

Tado repo
└── tado-core/crates/tado-notes/
    └── proxy crate that re-exports `dome_notes` (same submodule
        arrangement)
```

### Why submodule, not published crate

- No crate registry. The code doesn't want a public release story
  right now; one user, two apps, both local.
- Submodule + pinned commit is how we do rewrite branches
  (`foundation-v2` rebases are familiar), so the ceremony matches.
- When the day comes to publish, we just flip the path dep to a
  version string. Zero changes for consumers.

## Why Tado needs it

- Automations on the Calendar might want to do semantic lookups
  against prior runs (e.g. "summarise the last time this
  automation ran"). Today that's FTS5-only in bt-core; sharing
  the Dome notes crate gives us the full hybrid-search surface
  for free.
- Future Tado-side "notes" surface (if we ever introduce one,
  probably as an extension): same dependency.

## Cutover order (not this phase)

1. Land Dome's D6 module + tests on Dome's `main`.
2. Create `dome-notes` repo by `git subtree` split of
   `apps/bt-core/src/notes/` with its tests. New crate at the
   repo root.
3. In Dome: convert `apps/bt-core/src/notes/` to a submodule
   pointing at `dome-notes`. Swap the `mod notes;` in lib.rs
   for a `dome_notes` dep + a `use dome_notes::*;` re-export.
   Tests keep running in dome-notes CI.
4. In Tado: add `tado-core/crates/tado-notes/` as a thin proxy
   with the same path-dep setup. Document the
   `git submodule update --init --recursive` step in the
   release procedure.
5. Once both consume the shared crate cleanly, add a release
   workflow to dome-notes (tag on green CI) so either repo
   can pin to specific versions instead of arbitrary commits.

## Why this sits at T4 as "roadmap only"

- Submodule split is a cross-repo operation that needs a remote
  coordinated push. Dome's `rebuild-v2` branch hasn't merged to
  its own `main` yet (that happens once Dome ships its first
  release). Extracting out a crate from an unshipped branch
  guarantees the extraction gets rebased later.
- T5 (extensions host in Tado) doesn't depend on this, so we
  don't block on it.
- Waiting until Dome's main has the D6 module in a stable shape
  means the extraction diff is small and mechanical rather than
  racing a stack of in-flight changes.

## Decision log

- 2026-04-22 — roadmap written (T4 of the foundation-v2
  branch). Actual extraction deferred until Dome's rebuild-v2
  merges to its main.
