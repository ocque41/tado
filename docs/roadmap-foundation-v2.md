# foundation-v2 — branch status

This document tracks the long-lived `foundation-v2` branch. It's the
place to check what's landed, what's deferred, and what needs to be
true before the squash-merge back to `master`.

## Principle

Per the project rule: **no master merges until the rewrite is fully
done; the final merge is squash-to-one-commit.** `foundation-v2`
follows the same shape as the original Rust+Metal rewrite did.

## What has landed on this branch

| Phase | Commit idea                                                                    | Status    |
|-------|--------------------------------------------------------------------------------|-----------|
| T1    | Promote `tado-core/` to a Cargo workspace (`tado-terminal` + `tado-shared`)    | ✅ done    |
| T2    | Stand up `tado-ipc` crate (contract types + outbound helper)                   | ✅ done    |
| T3    | Stand up `tado-settings` crate (atomic IO + scope enum + paths)                | ✅ done    |
| T4    | Roadmap for extracting `dome-notes` as a shared crate                          | 📘 roadmap |
| T5    | Swift-side extension host protocol + empty registry                            | ✅ done    |
| T6    | Feature-migration roadmap (Eternal / Dispatch / Notifications → extensions)    | 📘 roadmap |
| T7    | Codified conventions in `CLAUDE.md` (Rust-first, extensions-first, etc.)       | ✅ done    |

## What still needs to happen before the squash-merge

The branch's structural pieces are in. What's missing for a release-
able `master` is the **actual migration work**:

1. **`IPCBroker.swift` → `tado-ipc`** — port the broker loop out of
   Swift (file watcher via `notify` crate, message delivery, CLI
   shell-script generation). The crate skeleton + contract types
   are already here; the runtime port lands as a series of focused
   commits.
2. **`AtomicStore` / `ScopedConfig` / `MigrationRunner` / `FileWatcher`
   / `BackupManager` → `tado-settings`** — same pattern. Atomic IO
   + the five-scope enum + path helpers live in the crate now;
   the scope merger, migration runner, backup tarball producer,
   and watcher callback bridge come in follow-up commits.
3. **`dome-notes` extraction** (T4 roadmap). Blocked on Dome's
   `rebuild-v2` merging to its own `main`. Submodule setup across
   both repos.
4. **Feature migrations** (T6 roadmap). One commit per feature,
   in the suggested order: Notifications → Eternal → Dispatch.
5. **Swift tidy-up** after the above — audit + delete the now-
   dead Swift-side Services/Persistence duplicates.

## When to merge

Merge to master when **all** of:

- ☐ `IPCBroker.swift` is down to a ~100 LOC facade that delegates
  to `tado-ipc`.
- ☐ `Sources/Tado/Persistence/*` is down to thin wrappers over
  `tado-settings`.
- ☐ At least one feature (Notifications) has migrated to an
  extension and the migration pattern is proven.
- ☐ `swift build` and `cargo build` are clean.
- ☐ `swift test` passes.
- ☐ The v0.8.0 release procedure works end-to-end on the branch
  (so the squash commit is release-ready).

Until then, `foundation-v2` stays on its own branch, rebased onto
master at each tagged release to stay current.

## How to continue on this branch

```bash
git checkout foundation-v2
git rebase master    # stay current with any master fixes
# … do work …
cargo test -p bt-core -p tado-ipc -p tado-settings  # for Rust
swift build && swift test                           # for Swift
git commit …
```

## Decision log

- 2026-04-22 — T1-T7 landed. T8 (squash-merge) intentionally
  deferred per the rewrite-shipping rule; the Rust ports + feature
  migrations need to complete first. Branch is healthy and safe to
  continue pushing commits onto.
