# Dome Note Reliability

This document records the failure class behind the recent Dome note
save/delete regressions and the rules we use to avoid repeating it.

## What failed

Two note actions broke after scoped knowledge and topic work landed:

- **Save on an existing note** still called the create path.
- **Delete** still called generic JSON-RPC with a hand-built actor
  payload that did not match bt-core's accepted actor schema.

Both failures showed the same user-facing message:
`"Dome may be offline."`

The daemon was not offline. The UI was calling the wrong lifecycle
path or the wrong bridge contract.

## Reliability rules

1. **One lifecycle stage, one explicit API**
   - Create uses create.
   - Update body uses update.
   - Rename uses rename.
   - Delete uses delete.
   - Do not reuse create as a hidden upsert unless the Rust contract
     explicitly guarantees that behavior.

2. **Prefer typed FFI over ad-hoc JSON-RPC in the desktop bridge**
   - Swift UI code should call dedicated FFI functions backed by typed
     Rust service methods.
   - Generic `handle_rpc` with hand-built JSON is acceptable only when
     there is no stable typed surface yet.

3. **Destructive actions must be success-dominant**
   - Once the core delete succeeds, follow-up telemetry must not turn
     the result into a visible failure.
   - Event emission, audit writes, and graph refresh are important, but
     they are secondary to the actual delete result.
   - Secondary failures should become warnings, not fake offline errors.

4. **Bridge contracts must accept deliberate aliases when needed**
   - If old clients or helpers may send `type/sessionId` instead of
     `kind/session_id`, the Rust parser should either reject them with a
     precise error or support them intentionally.
   - Silent mismatch is the worst case.

## Required test matrix for note features

Any change to Dome notes should verify all of these:

- create global note
- create project note
- update existing note body
- rename existing note title
- delete existing note
- topic create + note create in new topic
- list/filter by scope and topic after create/update/delete

At minimum:

- Rust unit test for create/update/delete lifecycle
- Swift build
- Swift tests

## Known design limit

`doc_delete` is still not fully atomic across SQLite rows and on-disk
files. The current rule is:

- core note deletion must succeed or fail clearly
- telemetry must be best-effort
- follow-up work should tighten the DB/filesystem delete story if Dome
  starts needing stronger recovery guarantees
