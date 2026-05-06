# Universal Performance IMPROVE Ladder + EVAL Stencils

Reference doc consumed by the Eternal Architect when generating
`crafted.md` for a `kind=perf` run, and by the worker each iteration
when picking the next refactor. The ladder is universal across
languages and stacks; the EVAL stencils are per-stack starting points.

If a project has no `bench/PERF_KNOBS.md` of its own, the architect
inlines this reference into the generated `crafted.md` so the worker
always has access to the same vocabulary.

---

## The Universal IMPROVE Ladder

Eight rungs, ordered safest → most structural. Each rung is a
category of refactor; specific examples vary by language but the
*shape* of the change is the same everywhere.

### Rung 0 — Measurement hygiene

Goal: trust your numbers before optimizing them.

- Lock the baseline before each round of changes (re-run the
  measurement N times, take the median, record the variance).
- Warm up before measuring (load caches, JIT-warmth, fill page
  tables).
- Use deterministic inputs (fixed seed, fixed data corpus, fixed
  filesystem state).
- Eliminate measurement noise: pin to one core, disable
  hyperthreading on the bench machine, no other workloads competing.

When this rung is in question, every other rung's measurement is
unreliable. Don't skip it.

### Rung 1 — Algorithmic

Goal: do less work.

- Drop redundant computation (cache invariants, hoist loop-invariant
  expressions, deduplicate calls).
- Replace `O(n^2)` patterns with `O(n log n)` or `O(n)`: sort then
  iterate, hash-set lookups, prefix-sum tables.
- Short-circuit on early exits: `for x in xs { if check(x) { return
  early; } }` instead of computing everything then filtering.
- Replace recursion with iteration where the recursion has high
  call overhead (Python especially).

This is the highest-yield rung. A complexity-class change beats every
constant-factor optimization combined.

### Rung 2 — Allocation

Goal: allocate fewer times, allocate larger chunks, reuse what you
allocated.

- Pre-size collections: `Vec::with_capacity(n)` / `[String]
  reserveCapacity(n)` / `dict.update(prealloc)` / `make([]T, 0,
  n)` instead of `new()` followed by N `push`/`append` calls.
- Reuse buffers across iterations of a hot loop instead of
  allocating fresh per iteration. Pool/arena patterns.
- Drop `clone()` / `.copy()` calls — pass references when the callee
  doesn't mutate. Especially expensive for `String` and `Vec<T>`.
- Use small-vector / inline-storage types when N is usually small
  but occasionally large: Rust `SmallVec`, Swift `ContiguousArray`
  with stack capacity, Python `array` for numeric types.

Allocations are not just the malloc cost — they pressure caches,
fragment the heap, and create work for the deallocator.

### Rung 3 — Data layout

Goal: make the CPU's cache lines work for you.

- Pack hot fields adjacent in memory (struct-of-arrays for fields
  scanned together, array-of-structs for fields scanned per record).
- Drop padding by reordering struct fields (largest first, smallest
  last in Rust; alignment-aware in Swift).
- Move cold fields to a sibling struct so hot loops touch only what
  they need.
- For cache-sensitive loops, ensure the working set fits in L1 / L2
  (usually 32 KB / 256 KB).
- Replace boxed pointers with inline storage where lifetime allows.

A 16x speedup from cache locality is not unusual on inner loops that
were previously cache-thrashing.

### Rung 4 — Concurrency

Goal: do work on more than one core.

- Parallel iter (`rayon` in Rust, `DispatchQueue.concurrentPerform`
  in Swift, `concurrent.futures` in Python, goroutines in Go) when
  the work-per-item is non-trivial AND items are independent.
- Move work off the hot path to a background queue if results aren't
  needed synchronously.
- Batch async dispatches: group N small async jobs into one larger
  one to amortize the dispatch overhead.
- Use lock-free data structures for shared counters / queues
  (`AtomicUsize`, `Channel`, `LockFreeQueue`) to avoid mutex stalls.

Be careful: parallelism amplifies cache contention. Profile before
and after.

### Rung 5 — Caching / memoization

Goal: don't recompute what you already computed.

- LRU / LFU caches around pure-function calls with hot keys.
- Interning: identical strings stored once
  (`Rc<str>`, `string.intern`, `lazy_static!` constants).
- Lazy compute: defer work until first access, then memoize.
- Precompute lookup tables for small expensive functions.
- Use weak references when full retention causes memory bloat.

Be careful: caches are correctness-fragile (invalidation is
notoriously hard) and can themselves cause regressions if the cache
miss path is now slower than the original work.

### Rung 6 — IO / syscall reduction

Goal: stop talking to the kernel and the disk so often.

- Buffer writes: `BufWriter` / `BufferedWriter` / `bufio.Writer`
  instead of one `write` per byte.
- Batch SQL writes inside a transaction (`BEGIN; … COMMIT;`)
  instead of one INSERT per row.
- Vectored IO (`writev` / `readv`) when you have multiple buffers
  to send in one syscall.
- Reduce file open/close churn — keep file descriptors around for
  the duration of a hot loop.
- Coalesce HTTP requests: batch endpoint, GraphQL, request grouping.

`strace` / `dtrace` will tell you exactly how many syscalls you're
making — surprisingly often that number is the bottleneck.

### Rung 7 — Structural

Goal: replace the algorithm or data structure entirely.

- Swap `HashMap` for `BTreeMap` (or vice-versa) when the access
  pattern shifts.
- Replace a B-tree-backed DB with an in-memory key-value store when
  the dataset fits.
- Codegen: generate optimized code at compile time (Rust macros,
  Swift `@frozen`, C++ templates, Python `Cython`/`numba`).
- Replace one library with a faster one (e.g. `serde_json` →
  `simd-json`, `re` → `regex` with proper flags, `requests` →
  `httpx` with connection pooling).
- Move work to a different layer entirely (push computation into
  the DB query, into a stored procedure, into a CDN edge worker).

This is the most disruptive rung. Use only when Rungs 1–6 have
plateaued.

---

## EVAL Stencils — per stack

These are the starting commands for each EVAL phase the architect
should bake into `crafted.md`. EVERY stencil must end with a call to
`bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh` so the
gate fires per iteration.

### Rust

```bash
# Correctness gate (perf-suite runs this internally too)
cargo test --workspace --quiet

# Per-bench measurement (replace <bench-name> with the project's
# actual criterion bench target)
cargo bench --bench <bench-name> -- --save-baseline current

# Score
bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
```

### Swift

```bash
# Correctness + bench (XCTest .measure { ... } blocks live in any
# test class; --filter narrows to the bench classes)
swift test --filter '*Bench*'

# Score
bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
```

### Node / TypeScript

```bash
# Correctness
npm test --silent

# Bench (vitest's built-in bench runner; or tinybench / mitata)
npx vitest bench --run

# Score
bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
```

### Python

```bash
# Correctness + bench (pytest-benchmark runs both)
pytest --benchmark-only --benchmark-json=/tmp/bench.json

# Score
bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
```

### Go

```bash
# Correctness
go test ./...

# Bench
go test -bench=. -benchmem ./...

# Score
bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
```

### Generic / shell-friendly

When the project doesn't fit a single-language stencil, use
`hyperfine` to time an arbitrary command:

```bash
# Correctness — project's own tests
<project's test command>

# Wall-clock around a representative invocation
hyperfine '<entry-cmd>' --warmup 3 --export-json /tmp/bench.json

# Score
bash $CLAUDE_PROJECT_DIR/.tado/eternal/hooks/perf-gate.sh
```

---

## How the worker uses this doc

1. The architect picks the EVAL stencil that matches `perf-suite
   detect`'s output and writes the chosen stencil into crafted.md's
   `## PERFORMANCE` section.
2. The architect picks default weights (see the suite's defaults if
   none specified) and writes them into the same section.
3. Each iteration the worker:
   - Runs the EVAL stencil verbatim from crafted.md.
   - Reads `perf-proposals.md` (auto-generated by the gate on
     regression) for refactor candidates.
   - Picks the proposal at the rung that best addresses the
     largest-loss sub-metric (see eternal-performance-evaluator
     agent for the rung-to-metric mapping).
   - Applies ONE refactor, re-runs the gate, prints `[PERF-OK]` if
     it passes.

The ladder is meant to be climbed slowly. Don't jump to Rung 7
because Rung 1 was harder than expected — that's how perf
optimization projects fail. Hold a rung until the metric plateaus,
then promote.
