# Plan: Quality & Performance Hardening (gwt runner, runtime packages, spec generator, protocol)

**Status**: In progress — derived from a five-pass quality review of the toolchain (2026-07-02); line refs to the tree of that date.

**Progress log:**
- 2026-07-02 — **B2 done** (gwt). Satisfied by the A1 worker-per-run refactor: each watch re-run gets a fresh ESM module registry (recompiled implementation modules re-imported, not served stale) and reclaims the imported graph on worker exit (no monotonic-buster leak). No content-hash fallback needed at current suite sizes.
- 2026-07-02 — **B4 partial** (local). First tranche of the query/storage perf work — the correctness-safe parts. (1) **SqliteDriver pragmas**: `openDb` now sets `journal_mode=WAL` + `synchronous=NORMAL` (WAL-safe, app-crash-durable, cuts per-commit fsync that dominated replay-heavy sessions) + `busy_timeout=5000` (wait rather than throw `SQLITE_BUSY`); no-op for `:memory:`. (2) **In-memory scan dirty-flag**: `QueryDbStorage_InMemory` replaced the eager `syncAll()` reflatten-of-the-whole-store-per-write (O(n²) over a replay) with a `dirty` flag + a lazy `currentItems()` snapshot recomputed on demand in the registered scan/stream closures — same flattened result, computed once per read only when something changed. (3) **`{name}By{Index}` push-down**: new Bus surface `registerQueryDbIndexLookup`/`getQueryDbIndexLookup` ((field,value)→items); the SQLite backend registers a closure that rides the existing `json_extract` GSI index via a per-field-cached prepared `WHERE json_extract(item,'$.<field>') = ? AND <notExpired>` (single-quote-escaped path, bound value) instead of the resolver materialising + parsing every row; the in-memory backend registers a scan+filter over the lazy snapshot (result parity — both match string fields). The index resolvers use the lookup when present, falling back to scan+filter. Tests: 3 index-lookup cases (SQLite match/exclude-expired, in-memory parity) + 1 interleaved-save/scan dirty-flag case in `QueryDbGsiTtlTest`. Local suite green (68 suites / 427 tests), clean build zero warnings.
- 2026-07-02 — **B4 DCB SQLite storage done** (local). `DcbEventLogStorage_Sqlite` read + append fast-paths: (1) **batched tag hydration** — `read`/`runQuery` collected tags for all result positions in one `WHERE log_name = ? AND position IN (…) ORDER BY position, rowid` query grouped into a dict, replacing the N+1 per-event `tagsForPosition`; order + per-position grouping preserved (rowid = insertion order). (2) new **`dcb_tag_by_pos(log_name, position)` index** — the existing `_by_kv` index leads with tag_key/value and can't answer a position lookup, so the batch was scanning `dcb_tag`. (3) **prepared-statement cache** keyed on SQL text (`preparedFor`) — `runQuery` prepared a fresh statement per call; node:sqlite statements re-run with new params, so one prepare per distinct shape. (4) **`anyMatch` existence check** — the append-condition now runs `SELECT 1 … WHERE <where> LIMIT 1` instead of `runQuery(...)->length > 0`, which had materialised *and tag-hydrated* every conflicting row just to test emptiness; `buildQuerySql` refactored to share `buildQueryWhere` with it so both match identical rows. Tests: multi-tag ordering + per-position grouping, non-conflicting-condition-succeeds added to `DcbEventLogStorageSqliteTest` (6 cases); existing conflict/round-trip/reopen tests unchanged and green. Whole monorepo green (216 suites / 1643 tests, run without `LOG_LEVEL=silent`), clean build zero warnings.
- 2026-07-02 — **B4 EventLog SQLite done** (local). `EventLogStorage_Sqlite`: (1) the OCC seq lookup switched from `COUNT(*)` (O(n) row scan per aggregate) to `SELECT COALESCE(MAX(seq_nr), -1) + 1` — reads the rightmost leaf of the `(log_name, aggregate_id, seq_nr)` PK index in O(log n); identical value because events are appended contiguously from seq 0 (the OCC check forbids gaps). (2) `appendStream` now `Stream.runCollect`s and delegates the whole batch to `append`, which already inserts every event under one transaction with a single OCC check — was one transaction + one seq lookup *per element* over a bulk replay, and is now atomic (all-or-nothing) instead of leaving a partial prefix committed on a mid-stream raced PK. Tests: multi-event-append-advances-seq-via-MAX + stale-seq-conflict, and an `appendStream` order/count case from a non-zero starting seq added to `EventLogStorageSqliteTest` (6 cases). Whole monorepo green (216 suites / 1645 tests), clean build zero warnings. **Deferred (still B4):** full list-query keyset-cursor push-down into SQL (filter/order/limit) — needs its own step with JS↔SQL parity tests across search/per-field-eq/range/orderBy/cursor; DCB in-memory posting lists (`DcbEventLogStorage_InMemory` — reads filter the whole log per conditional append, O(n²) per session).
- 2026-07-02 — **A2, A3, A4 done** (gwt correctness). Second-signal hard exit; rerun drain-loop (no third concurrent pass); per-test timeout race (`Collector.entry.timeout` + `Cli.raceWithTimeout`, default 5s, reported as `Throw`); `ChildProcess.onError` + trailing-line flush on stream `end`; `WatcherProbe.isAlive` ESRCH-vs-EPERM; `ProcessManager` stderr wiring + bounded watcher-crash respawn + `cleanRebuild` exit-code propagation; `structuralRebuild` only reports `buildOk` on real success + per-package rebuild dedup; `Watch.debounce` accumulates the *set* of distinct structural paths (multi-package bursts) + widened ignore globs (`dist`/`.history`); `Collector.activate` resets `skipDepth`, `Filter.xdescribe` decrements on the throwing path; `PlatformRunner` awaits ephemeral-port closes + resolves keep-alive on child exit with real exit code; watch re-emits discovery on a new source `.res` add. Tests: `WatchDebounceTest` updated + 2 new A4.1 cases; new `CliRunEntryTest` (timeout + skipDepth). Full gwt suite green (25 suites / 149 tests), clean build zero warnings.
- 2026-07-02 — **A1 done** (gwt). Each watch re-run now executes in a short-lived `worker_threads` Worker (`Worker.res` binding + `RunWorker.res` entry): a fresh ESM registry per pass re-imports recompiled implementation modules instead of replaying tests bound to Node's never-evicted stale copies (the correctness bug), and the imported graph is reclaimed on worker exit (the monotonic-buster leak). The worker's stdout pipes to the parent so NDJSON reaches the client unchanged; the parent keeps chokidar + the build watchers; on cancel the current worker is terminated. One-shot `run` stays in-process. Verified: unit suite green (149), and a live `watch` smoke run streamed identical output (44 passed) with a clean spawn→run→idle→SIGINT lifecycle. (Also satisfies B2.)
- 2026-07-02 — **A5 done** (local). `LocalBus` drain loop: a throwing/rejecting subscriber now converts to a typed error (`tryPromise`), logs-and-recovers (`catchAll`) so the fiber keeps draining, and runs `done_` via `ensuring` so the publish countdown always completes — no more topic-wide hang. Guarded the two fire-and-forget handler sites (`dispatchCommand` parked drain, `makeFireAndForgetHandler`) with `Promise.catch`. New `LocalBusPubSubTest` "failing subscriber" cases (hang-free publish + drain-fiber-survives). Full local suite green (68 suites / 421 tests).
- 2026-07-02 — **A6 partial** (local). Headline correctness fixes landed: both Sqlite append sites (`EventLogStorage_Sqlite`, `DcbEventLogStorage_Sqlite`) now map **only** a genuine `constraint failed` (PK/UNIQUE race) to the retryable `"conflict"` sentinel — disk-full/SQL/locked-db errors surface as real errors instead of being retried forever; the deliberate logical conflict checks (`Failure("conflict…")`) are unaffected. `SqliteDriver.transaction` guards `ROLLBACK` so a failing rollback can't mask the original error. MCP event-history pagination (`Platform.res`) compares positions numerically (`"10" > "9"`) so cursor pages no longer skip/duplicate across digit boundaries. Strengthened the Sqlite conflict test to assert the sentinel. Local suite green (68 suites / 421 tests).
- 2026-07-02 — **A6 DcbEventLog_Builder wiring done.** The standalone-DCB-log builder now uses `DcbEventLogStorage_InMemory.Make(Bus)` (the backend-aware functor, as Platform does) instead of the plain module: it honours `REVENTLESS_LOCAL_BACKEND=sqlite` and registers the read with the Bus so `Bus.getDcbEventLogRead` sees it. Local suite green (421). - 2026-07-02 — **A6 typed conflict sentinel done** (core/local/aws). Replaced the string `"conflict"` sentinel (detected by substring-matching a pretty-printed Effect Cause across three layers) with a typed `EventLog.appendError = Conflict | StorageFailure(string)`. `EventLog.append` now returns `result<unit, appendError>`; `EventLog_Operations` fails the retry Effect with the typed error (schedule retries only transient `StorageFailure`, never `Conflict`) and collapses the outcome without Cause stringification; `Aggregate_Callback` matches `Error(EventLog.Conflict)` (no substring left). Storage implementors return the typed variant: local InMemory/Sqlite (only a real `constraint failed`/logical check → `Conflict`), aws DynamoDb (`StaleState` → `Conflict`, else `StorageFailure`). `appendStream` keeps its string channel (bulk replay, no OCC). Test mocks + the retry/conflict tests updated; new "Conflict is never transient" case. Core 477, local 421, aws 133 all green; zero warnings.
- 2026-07-02 — **A6 QueryDb `count` done** (local, both backends). `count(id, fieldName, inc)` now mirrors DynamoDB's `ADD #fieldName :inc` on key `{id}`: it reads the counter field on the partition-key item (counters are single-state, implicit sub-key `""`), adds `inc`, upserts, and returns the **new total** — instead of echoing `inc` and never persisting (so the running total was wrong and `loadStream` never reflected it). Creates the item on first increment. New backend-parity test asserts the running total (3 → 5) and that `loadStream` sees the persisted counter under both Memory and Sqlite. Local suite green (422).
- 2026-07-02 — **A6 InMemory TTL + UIFragmentRegistry done** (local). InMemory QueryDb now records an absolute expiry (epoch seconds, same value SQLite stores) per (partition, sub-key) on save/saveBatch and lazily drops expired entries on read (`load`/`loadStream`/scan/stream) — parity with SQLite's read-time `notExpiredClause`; previously `~ttl` was silently ignored. `ensureUIFragmentRegistryQueryDbStore` now builds via the backend-aware `QueryDbStorage_InMemory.Make(Bus)` functor (retrieving ops from the Bus) instead of a hand-rolled memory-only store, so the registry persists under SQLite. New TTL backend-parity test (expired item filtered under both). **A6 fully complete.** Local suite green (423).
- 2026-07-02 — **A8 done** (spec). Grouped-EP headline bug: `Pairing` used `Dict.get(...)->Option.getOr({…set…})` whose default is eagerly evaluated, so every iteration overwrote the group's array with a fresh empty one and pushed onto a detached copy — a group with ≥2 mappings emitted a non-compiling `Plugin.res`; replaced with an explicit `switch`. `DcbValidation.schemasAreCompatible` now recurses into object properties and union variants (previously any Object/Union pair passed, so nested payload drift was invisible). `DcbDecode.makeDecoder` warns on a parse failure instead of silently dropping a drifted event. `PluginGenerator` exits non-zero on a usage error (was exit 0 → prebuild/CI stayed green with no Plugin.res). Spec builds clean (no in-package test harness yet — grouped-EP regression fixture tracked under D1); no example uses grouped EPs so the bug was unexercised.
- 2026-07-02 — **A9 done** (interop, layer-builder). `Compat.parseSemVer` strips prerelease/build suffixes, so `-alpha` versions parse correctly instead of being reported incompatible; added a `MalformedVersion` error distinct from incompatible. Layer-builder: `doPostProcessing` returns success and the build fails (panic) if any step failed instead of shipping unstripped code; the "requires rescript!" guard reads `tree.children.get("rescript")` directly (the walk-populated ref was always None); `Main.res` awaits the build and exits non-zero on failure. Tests: `CompatTest` extended with the SemVer/protocol matrix (13 new cases). Interop 44 tests green; interop/layer-builder clean builds; core rebuilds clean against both. (layer-builder has no test harness — D1.)
- 2026-07-02 — **A7 done** (core). `optimizeActions` off-by-one (`~end=count-1`) — no longer double-applies the pre-merge action; `applyChanges` propagates the first storage error instead of swallowing it; unsupported projection action returns an error instead of silent Ok(); `CommandPublisher` root fix — `send()` used non-mutating `toSpliced` so the buffer never drained and published the wrong slice (now `slice`+`splice`), `flush()`'s dead in-flight loop replaced with `send()`, `clear()` truncates instead of dropping one; `Util_Array.containsByPredicate` inverse fixed; `SchemaWalker.describeSchema` recurses into nested records so the structural hash catches nested drift. Tests: `ProjectionOptimizeTest`, `CommandPublisherTest`. Core suite green (43 suites / 476 tests); local re-verified against updated core (421 tests).
**Nature**: umbrella roadmap. Covers correctness, performance-at-scale, duplication, and missing-infrastructure items across `reventless-gwt`, `reventless-local`, `reventless-core`, `reventless-spec`, `reventless-interop`, `reventless-layer-builder`, and `reventless-vscode-protocol`. Each finding is restated inline so the plan stands alone; fixes should land with their tests.

## Phasing rationale

Order = correctness → performance → structure → tests/infra. Correctness leads because several bugs silently lose or corrupt data (a hung bus topic, a duplicated projection action, a generator that emits non-compiling plugins). The performance phase implements one idea at every layer: **key work on what changed** — the change signal (watch path, package build event, slice content) already exists everywhere and is currently discarded. Structure (dedup/contract consolidation) is behavior-preserving and goes last among code phases. Tests for each fix land with the fix; net-new harnesses are Phase D.

| Phase | Item | Package | Class |
|---|---|---|---|
| A1 | Stale-code watch re-runs (ESM cache) | gwt | Correctness |
| A2 | Rerun race + missing test timeout + signal handling | gwt | Correctness |
| A3 | Process/build lifecycle fixes | gwt | Correctness |
| A4 | Watch fidelity fixes (bursts, ignores, discovery) | gwt | Correctness |
| A5 | LocalBus subscriber-failure hang | local | Correctness |
| A6 | Conflict misclassification + backend parity | local/core | Correctness |
| A7 | Projection + CommandPublisher bugs | core | Correctness |
| A8 | Spec generator + DCB validation gaps | spec | Correctness |
| A9 | Interop SemVer + layer-builder failure modes | interop/layer-builder | Correctness |
| B1 | Affected-set test re-runs + incremental discovery | gwt | Performance |
| B2 | Content-hash module cache (or worker-per-run) | gwt | Performance |
| B3 | Per-plugin graph reload + misc runner perf | gwt | Performance |
| B4 | Query push-down into SQLite + in-memory indexes | local | Performance |
| B5 | Projection checkpoints + aggregate snapshots | local/core | Performance |
| B6 | Hot-path allocations | core/spec | Performance |
| C1 | Protocol package: graph types, kinds, version export | protocol | Contract |
| C2 | `ComponentKind` single source | spec/protocol | Structure |
| C3 | Shared tooling modules | new/spec | Structure |
| C4 | Package-internal dedup | gwt/core/local | Structure |
| D1 | Test suites for untested packages | spec/protocol/layer-builder | Tests |
| D2 | Targeted regression tests | all | Tests |
| D3 | Benchmark harness + timing events | gwt/local | Infra |
| D4 | Runner robustness (cancel, retries, readiness) | gwt | Infra |

---

## Phase A — Correctness

### A1 — gwt: watch re-runs must execute current code

`reventless/reventless-gwt/src/Loader.res:19-24` cache-busts only the test file's own URL (`?t=N`); its static imports — the slice/behavior modules under test — resolve to unqueried URLs already in Node's ESM registry, so after a recompile a re-run re-registers tests that close over the **old** module instances. `src/LocalHost.res:30-34` documents the same limitation for `loadGraph`. The monotonic buster also leaks: Node never evicts registry entries, so long watch sessions grow by (files × module graph) per re-run.

**Fix (also B2):** run each re-run pass in a short-lived `worker_threads` Worker — fresh module registry per run (correctness) and memory reclaimed on worker exit (the leak). Keep the current in-process path for one-shot `run`. Alternative if workers prove awkward: content-hash cache keys (`?v=<sha256>`) plus a per-URL `Collector` entry cache so unchanged files replay entries without re-import — but this still needs transitive busting for changed *implementation* files, which the worker approach gets for free.

### A2 — gwt: rerun race, per-test timeout, second-signal exit

- `src/Cli.res:536-549`: `runInProgress` is cleared **before** awaiting the pending re-run, so a third concurrent `runOnce` can start, corrupting the module-global `Collector` (`src/Collector.res:39-49,122-127`) and interleaving NDJSON events. Fix: hold the flag across a drain loop (`while rerunPending { rerunPending := false; await runOnce }`).
- `src/JestBind.res:55-70` accepts `~timeout` but the Collector arm drops it; `Cli.runEntry` (`src/Cli.res:234-250`) awaits test bodies with no deadline — a hung test wedges the run. Fix: `Promise.race` each body against its timeout (with a default), report as a timeout mismatch.
- `src/Cancellation.res:19-28`: after the first SIGINT every further signal is a no-op — with a hung await only SIGKILL works. Fix: `process.exit(130)` on the second signal.

### A3 — gwt: process/build lifecycle

- `src/ChildProcess.res:42-43`: no `"error"` listener — an ENOENT spawn failure crashes the CLI. Add `onError`, route to `buildFail`/`onStop`.
- `src/ProcessManager.res:22-32`: a crashed `rescript build -w` is never detected (no `onClose`); the entry stays in `running`, build status freezes. Detect, emit, respawn.
- `src/Cli.res:567-585`: `structuralRebuild` emits `buildOk` unconditionally even when the classifier saw errors; `ProcessManager.cleanRebuild` (`src/ProcessManager.res:64-77`) ignores exit codes (a failed `clean` still chains into `build`). Track failure through the chain.
- `src/ProcessManager.res:26-27,66`: only stdout is classified; compiler/pnpm crashes on stderr are invisible until the 120 s watchdog. Wire stderr like `PlatformRunner` does (`src/PlatformRunner.res:151-152`).
- `src/PlatformRunner.res:153-158`: `onClose` fires the callback but the runner then awaits cancellation forever (zombie parent after child crash) and returns 0 regardless of child exit code. Resolve the keep-alive in `onClose`; derive the exit code.
- `src/ChildProcess.res:49-66`: flush the unterminated last output line in `onClose` (crash messages typically lack a trailing newline).
- `src/WatcherProbe.res:24-30`: distinguish `ESRCH` (dead) from `EPERM` (alive, not ours) in `isAlive`.

### A4 — gwt: watch fidelity

- `src/Watch.res:48-77`: the debounce keeps a single `bestPath`; a burst spanning two packages (branch switch, multi-package refactor) clean-rebuilds only one, leaving the other with stale `.res.mjs`. Accumulate the set of structural paths per window; rebuild every distinct owning package.
- `src/Watch.res:84` ignores only `node_modules/lib/.git` while `src/Discovery.res:31,38-44` also prunes `dist`, `.history`, and `.gwtignore` subtrees — writes under `dist/` can trigger re-run loops. Share one ignore predicate (see C3 `FsWalk`).
- `src/Collector.res:39-47` + `src/Filter.res:29-35`: `skipDepth` is never reset and not decremented on exception — a throwing `xdescribe` silently skips every subsequent file. Reset in `activate()`, decrement in a `finally`.
- `src/Cli.res:529-533`: discovery items are emitted once at watch start; test files added mid-session run but never appear in the client's tree. Re-emit items for newly discovered files.
- `src/PlatformRunner.res:65-75`: ephemeral-port allocation closes probe servers fire-and-forget before the child binds (EADDRINUSE race). Await the closes; prefer child-binds-port-0-and-reports; retry on bind failure.

### A5 — local: a failing subscriber must not hang the topic

`reventless/reventless-local/src/adapter/LocalBus.res:268`: a throwing/rejecting handler becomes an Effect defect in `Effect.promise(() => handler(...))->Effect.zipRight(msg.done_)`; `done_` never runs, the countdown (`:314-328`) never completes, the publisher's await (`:346`) hangs — and since the dead drain fiber stops consuming while `subscriberCounts` is never decremented, **every subsequent publish on that topic hangs too**. Fix: run `done_` via `Effect.ensuring`; catch handler defects and log them. Add the failing-subscriber test (none exists).

Related fire-and-forget rejections to guard: `LocalBus.res:375,417`, `Scheduler/LocalScheduledPublisher.res:64`, `Platform.res:1024`.

### A6 — local/core: conflict classification and backend parity

- `reventless-local/src/adapter/DcbEventLog/DcbEventLogStorage_Sqlite.res:309` and `EventLog/EventLogStorage_Sqlite.res:92`: catch-all `| _ => Error("conflict")` turns every SQLite failure (disk full, SQL error) into a retryable OCC conflict; `reventless-core/src/components/EventLog/EventLog_Operations.res:118` and `Aggregate_Callback.res:188` then detect conflicts by **substring match** over a pretty-printed Cause — misclassified errors retry indefinitely. Fix: a typed conflict sentinel end-to-end; only the deliberate append-condition failure maps to it.
- `reventless-local/src/components/DcbEventLog_Builder.res:6` wires the plain `DcbEventLogStorage_InMemory` (never consults `BackendState`, never registers the bus read — `DcbEventLogStorage_InMemory.res:105`), while `Platform.res:697` uses `Make(Bus)`: standalone DCB logs silently stay in memory under SQLite and are invisible to `Bus.getDcbEventLogRead`. Use the functor.
- Backend divergences: QueryDb TTL honoured by SQLite (`QueryDbStorage_Sqlite.res:146`) but discarded in memory (`QueryDbStorage_InMemory.res:79,132`); `count` returns the increment, not a total, in both (`QueryDbStorage_InMemory.res:153`, `QueryDbStorage_Sqlite.res:263`); `ensureUIFragmentRegistryQueryDbStore` (`Platform.res:750-809`) hand-rolls a third in-memory store that never persists under SQLite. Align or return explicit `Error("not implemented")`.
- `SqliteDriver.res:41-52`: a throwing `ROLLBACK` replaces the original error; nesting throws. Guard the rollback; SAVEPOINTs or an in-transaction flag.
- `Platform.res:285`: MCP event-history pagination compares positions as **strings** (`"10" > "9"` is false) — cursors skip/duplicate. Parse to int (as the storage layers' `posToInt` does).

### A7 — core: Projection and CommandPublisher

- `src/Projection.res:291`: `optimizeActions` slices with `~end=optimizedActionsCount` (count = full length, end exclusive) so `lastAction` stays in the slice and the merged action is appended on top — **the last action applies twice**. Fix: `~end=count - 1`. Add the property test (D2): optimized vs unoptimized sequences must produce identical store states.
- `src/Projection.res:105-107`: `applyChanges` swallows storage errors (`| _ => Ok()` with a TODO). Propagate the first `Error`.
- `src/Projection.res:239-242,262-265`: unsupported actions log "not yet supported" and return `Ok()`/`[]` — silent read-model loss reported as success. Return an error.
- `src/util/CommandPublisher.res:128`: `flush()`'s in-flight branch loops `while running.contents->Option.isNone` — reached only when `running` is `Some`, so it exits immediately; buffered commands are neither awaited nor sent. Invert + final `send()`.
- `src/util/CommandPublisher.res:118`: `clear()` uses `Array.removeInPlace(0)` (= `splice(0,1)`) — removes one element; the "cleared" rest publishes later. Truncate.
- `src/util/Util_Array.res:1`: `containsByPredicate` returns the inverse (`Option.isNone`). Uncalled today; fix or delete before its first caller.
- `src/plugin/component/SchemaWalker.res:15-43`: the "structural hash" renders nested records as the literal string `"object"` — nested schema edits don't change the SHA256, so drift detection misses them. Recurse into `Object({properties})`.

### A8 — spec: generator and DCB validation

- `src/generator/Pairing.res:319-324`: grouped extension points use `Dict.get(...)->Option.getOr({ Dict.set(...); a })` — **`getOr`'s default is evaluated eagerly**, so every iteration replaces the group's entry with a fresh empty array and pushes land on a detached one. An EP group with ≥2 mappings generates a `Plugin.res` that doesn't compile (`Codegen.res:114-120` emits no module; `:229-242` still references it, `Array.getUnsafe(0)` on `[]` at `:234`). Fix: explicit `switch`. Regression fixture: one group, two mappings (D1).
- `src/generator/Pairing.res:121-140`: `extractTargetName` scrapes raw source lines with quote indexing — trailing comments containing quotes corrupt names; type-annotated declarations are missed; exceptions swallowed. Harden + surface errors.
- `src/components/DcbValidation.res:60-71`: `schemasAreCompatible` treats any `(Object, Object)` / `(Union, Union)` pair as compatible — nested payload drift passes. Recurse into properties / compare union tags.
- `src/components/DcbValidation.res:29-31`: Rule 1 ignores `isTaggedArray` (`DcbTag.res:263-267`) though runtime extraction treats array tagging differently.
- `src/components/DcbDecode.res:89-95,120-124`: every sury parse failure is swallowed (`catch | _ => ()` / `None`) — schema drift becomes invisible event drops. Return `result` or emit a structured warning.
- `src/generator/PluginGenerator.res:10-25`: usage errors print to stderr but exit 0.

### A9 — interop + layer-builder

- `reventless-interop/src/Compat.res:19-33`: `parseSemVer` splits on `"."`, so any prerelease (`1.0.0-alpha.1`) parses as `None` and `validateProtocol` reports **incompatible** rather than malformed — in a codebase living on `-alpha` versions. Strip prerelease/build suffixes; add a `MalformedVersion` error; test the matrix (currently untested).
- `reventless-layer-builder/src/DependencyBundler.res:9-14`: a failed post-process step is logged and the build **succeeds**, shipping unstripped deploy-time/test code. Track a failure flag, exit non-zero.
- `DependencyBundler.res:178-191`: the "X requires rescript!" guard can never fire — `rescript` is a dev dep filtered out of the walk (`:171`), so `rescriptModule` stays `None`. Look it up via `tree.children.get("rescript")` directly.
- `Main.res:143`: the top-level build promise is discarded; failures surface only as unhandledRejection.
- Low-severity sweep (fold in opportunistically): scanner error swallowing (`gwt/Discovery.res:47-51`, `ComponentScan.res:43-46`, `PackageScan.res:45-47`, `Cli.res:457-459` — EACCES currently looks like "no tests"/no graph; log to stderr or emit a warning event); naive `file://` construction (`gwt/FormatterVsCode.res:20`, reversed by slicing at `Collector.res:158-160` — use `pathToFileURL`/`fileURLToPath`); `UserStore.res:133` dropping the `load()` result; `posToInt` mapping malformed cursors to 0; `Authorization.res:20`'s magic `"anonymous"` string; `interop/Query.res:73-74,128-129` collapsing decode errors to `MetaMissing`; `Protocol.res:115-119` collapsing malformed JSON and unknown-event into the same `None` (add a `Malformed` diagnostic path) and `:126` emitting an empty NDJSON line on failed stringify.

---

## Phase B — Performance

### B1 — gwt: affected-set re-runs + incremental discovery

Today every watch event triggers full re-discovery, full reload of every test file, and full re-execution (`src/Cli.res:383-432,536-549`) — O(total) per save.

1. The watch callback already receives the changed path (`src/Watch.res:79-92`) and `PackageScan.findOwning` maps path → owning package (`src/PackageScan.res:50-60`). On a plain `Change`, re-run only that package's test files; merge cached `fileResult`s for the rest into the emitted summary (the NDJSON protocol is per-test, so clients stay consistent).
2. Walk the tree once at session start; maintain the discovered set from chokidar `add`/`unlink` events; full re-walk only after structural rebuilds. (`Discovery.discover` stays as-is for one-shot `run`.)

### B2 — gwt: module-cache strategy

Worker-per-run from A1 is the primary fix (correctness + leak + isolation). If measured worker overhead is unacceptable for very fast suites, the fallback is content-hash URL keys + a `Collector` per-URL entry cache — see A1 for the trade-off.

### B3 — gwt: graph reload + misc runner perf

- `src/LocalHost.res:35-39` cold-imports **every** plugin per discovery. Key per-plugin reload on that package's `buildOk` (the watch session already classifies builds); re-emit `graph` only when `sha256(encoded structures)` changed — today identical graphs re-emit and force client re-renders.
- `src/FormatterVsCode.res:46-115`: `locateInSource` is O(labels × lines) with a never-invalidated `sourceLineCache` (stale ranges after edits; duplicate labels hit the first occurrence). Invalidate by mtime; pre-index each file's string literals in one pass.
- `src/BuildClassifier.res:81`: the failure message truncates to the first 20 buffered lines, silently dropping later error blocks in multi-error builds. Raise the cap or truncate per block. Also `:108-136`: errors arriving before the first "Parsed" line never settle → no `onFail`, no watchdog; arm on first output.
- Quadratic accumulation: `Collector.push` (`src/Collector.res:101`), `Diff.walk` (`src/Diff.res:22-30,62-73`), walker concats (`src/Discovery.res:55-68`) → `Array.push`/`Set`. Parallelize the serial directory walks (`Promise.all` over subdirs). `PlatformScan.walk` (`src/PlatformScan.res:106-121`) descends into matched packages despite its comment.

### B4 — local: query push-down + indexes

- `QueryDbResolvers_GraphQL.res:324-332,416-442,490-493`: every list query materialises the full read model, filters/sorts in JS, then applies keyset bounds; under SQLite `QueryDbStorage_Sqlite.res:181-191` re-runs `scanAllStmt` + `JSON.parse` per row per request. Push filter/order/limit into SQL (`json_extract` predicates + `ORDER BY … LIMIT pageSize+1`).
- The per-index `json_extract` GSI indexes (`QueryDbStorage_Sqlite.res:88-97`) are created but **unused** — the `{name}By{Index}` resolvers scan+filter in JS (`QueryDbResolvers_GraphQL.res:751-762`). Add a prepared `WHERE json_extract(item,'$.<field>') = ?` per index, register it in the Bus.
- `QueryDbStorage_InMemory.res:86-88`: `syncAll()` reflattens+resorts the entire store per single-row write (O(n²) over a replay). Dirty-flag + lazy sort in the registered scan closure (`:218`).
- DCB SQLite (`DcbEventLogStorage_Sqlite.res`): N+1 tag query per event (`:240`) with an index that can't serve the per-position lookup (`:34-36`) — add `(log_name, position)` and batch with `IN (...)`; cache prepared statements per query shape (`:208` prepares per call); `SELECT EXISTS … LIMIT 1` for append conditions (`:271` materialises all conflicting rows); `MAX(seq_nr)+1` instead of `COUNT(*)` (`EventLogStorage_Sqlite.res:56-71`); batch `appendStream` into one transaction (`:109-122`).
- `SqliteDriver.res:26-31`: set `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout` pragmas.
- DCB in-memory (`DcbEventLogStorage_InMemory.res:33,53`): reads filter the whole log per conditional append → O(n²) per session. Posting lists (`Map<tagKey:value, positions>`, `Map<eventType, positions>`), intersect, binary-search `after`.

### B5 — checkpoints and snapshots

- **Projection checkpoints (local)**: read models are fed only by live bus events; under SQLite the tables persist but there is no "last projected position" and no catch-up at startup — a crash between append and projection write diverges state permanently. Add `projection_checkpoint(read_model, position)` + startup catch-up replay.
- **Aggregate snapshots**: every command replays the full stream from seq 0, again per conflict retry (`reventless-core/src/components/Aggregate/Aggregate_Callback.res:135-137`). Port StateChangeSlice's LRU delta-seed pattern; optionally a `snapshot(log_name, aggregate_id, seq_nr, state)` table + `latestSnapshot` op for long local sessions.
- **Persisted-data versioning**: no `PRAGMA user_version` anywhere (the only migration is a try/catch `ALTER TABLE`, `QueryDbStorage_Sqlite.res:49-52`); `Message.flatJsonToStoredEvent` passes `schemaVersion` through unused; `ExportMeta.version` is frozen and never read by `Compat.validateAndProject`. Introduce versioning or delete the vestigial fields.

### B6 — hot-path allocations

- `reventless-core/src/Message.res:21-37` + `Projection.res:15`: fresh `S.object` schema per decoded event — memoize per `(idSchema, eventSchema)`.
- `Projection.res:268-276`: `groupActionsById` re-filters all actions per id → one-pass dict grouping; `:89-92` nested deep-`!=` state diff → index by subId; `:118,141-166`: eager state stringification even when debug is off (and `getOrThrow` crashes on non-serializable state) → lazy log thunks.
- `spec/src/components/DcbTag.res:398-401,644-647`: per-message stringify→parse round-trip + linear variant scan on dispatch — use `reverseConvertToJsonOrThrow` and index variants by TAG once per schema (as `DcbDecode.makeDecoder` already does).
- `StateChangeSlice_Callback.res:203`: LRU key falls back to `""` on stringify failure — cross-contaminates cache entries; fail closed instead.
- Layer-builder: `predIsNecessary` full-tree walk runs twice per node (`DependencyBundler.res:109,171`); serial extraction (`:117-124`) → small concurrency pool; `Lru.res:38` materialises all keys to evict one.

---

## Phase C — Structure & contracts

### C1 — protocol package: one graph vocabulary, exported version

- Make `Protocol.graphNode/graphEdge` (`reventless-vscode-protocol/src/Protocol.res:55-59`) the **only** graph record: `DomainGraph.build` (`gwt/src/DomainGraph.res:21-24`) produces Protocol records directly, deleting the field-by-field re-map in `FormatterVsCode.graph` (`gwt/src/FormatterVsCode.res:256-267`).
- Promote node/edge `kind` strings to variants in the protocol package so producers and consumers exhaust-match (today `DomainGraph.res:242` emits `extends`, which downstream renderers don't all map; `edge.label` at `DomainGraph.res:24,55` is never populated — populate or drop).
- genType-export `protocolVersion` (`Protocol.res:107-110`) so consumers import it instead of hand-copying the number (the header comment already claims single-source; make it true).
- Add the per-variant round-trip test (`toJsonLine` → `parseStreamEvent`) for all 22 variants **in this package** — the wire shape is currently pinned only indirectly by a consumer.
- Emit-side golden NDJSON fixture generated from `FormatterVsCode`, published with the package so consumers can replay it against their decoders in their own CI.

### C2 — `ComponentKind` single source

The component-kind vocabulary (folder names, file suffixes, kind→category maps) is hand-maintained in at least: `spec/src/generator/Discovery.res:20-44` (plural-tolerant `folderToComponentType`), `gwt/src/ComponentMeta.res:10-23,30-40` (singular-only — **already disagrees** with spec), `spec/components/Plugin.pluginStructure` (`Plugin.res:304-318`), `interop/components/Plugin.res:6-18` (missing `tasks`/`extensions`), plus downstream tooling tables. Define one `ComponentKind` module — variant, accepted folder spellings, body-file suffixes, display metadata, per-kind part rules — exported through `reventless-vscode-protocol` (the package external tooling already consumes), and rewrite the in-repo tables to derive from it.

### C3 — shared tooling modules

Promote the best existing implementation of each into a shared, published module set (either widening `reventless-vscode-protocol` or a small sibling package):

- `FsWalk` — one recursive walker (roots, ignore set, `.gwtignore` sentinel pruning, file predicate). Replaces the five walkers: `gwt/src/Discovery.res:46-70`, `ComponentScan.res:42-66`, `PlatformScan.res:106-121`, `spec/src/generator/Discovery.res:112-198`, and the divergent ignore globs in `gwt/src/Watch.res:84` (the A4 bug class).
- `Debounce` — the rank-coalescing chokidar wrapper (`gwt/src/Watch.res:48-77`) generalized (A4's multi-path fix lands here).
- `ChildProcess` + `killTree` — the hard-won teardown semantics (`gwt/src/ChildProcess.res`, `ProcessManager.res:79-89`), with A3's `onError`/flush fixes.
- `ExnMessage` — the one correct extractor handling JS Errors **and** ReScript `RE_EXN_ID` payloads (`gwt/src/Cli.res:213-223`).
- `PluginName` — plugin-name derivation, currently verbatim-duplicated between `spec/src/generator/Config.res:15-33,60-78` and `gwt/src/LocalHost.res:58-98` (~45 lines; a drift silently breaks graph plugin keys).
- `Args` — a small flag-table CLI parser replacing the hand-rolled loop (`gwt/src/Cli.res:92-201`) and fixing the `--flag=value` vs `--flag value` grammar inconsistency across tools.
- Publishing this set also lets external consumers stop vendoring pure modules (e.g. the DCB scope-inference logic in `spec/src/components/DcbScopeInference.res` is known to be re-ported verbatim elsewhere because the package is unpublished).

### C4 — package-internal dedup

- **gwt mismatch normalization**: six hand-maintained switches over the 10-variant `Outcome.mismatch` (`Outcome.res:59-97,102-161`, `FormatterHuman.res:44-87`, `FormatterTap.res:20-75`, `FormatterJson.res:64-134`, `FormatterVsCode.res:306-356`) → one normalization step (`{kind, expectedRendered, actualRendered, extras, fieldDiff}`) consumed by every emitter. Also fixes JUnit rendering differently from every other formatter (`FormatterJunit.res:58-69` uses raw `Outcome.format`).
- **`Behavior_GWT`**: `Make` vs `MakeFromAggregate` duplicate the entire assertion core (`Behavior_GWT.res:283-381` vs `:508-603`) — extract a shared comparison-core functor, as `Delegate_GWT` already does.
- **gwt DSL alignment pass** (user-facing vocabulary): `whenCmd`/`whenCommand`/`whenSourceCmd`; five spellings of "nothing emitted"; `test` sync vs promise-with-timeout by module; `AggregateT` missing `todo`.
- **gwt dead surface**: `Outcome.toJson` (superseded, drifted), `--schema-version` parsed but never read (`Cli.res:161-163` vs hard-coded `"1.1.0"` in `FormatterJson.res:8`), `resetLocateCache` (no callers), `PlatformScan.serveScript` computed but unused. Delete or wire.
- **local/core**: extract one `registerAdminSchema` from the triplicated admin GraphQL registration (`Platform.res:1655-1676,1854-1881,2067-2094` — with drift at `:2098`); merge `Util_Adapter`/`Util_AdapterRuntime`; one `variantTagName` helper for the ~13 TAG-extraction copies across `DcbTag`/`DcbValidation`/`DcbDecode`; namespace interop's spec-colliding module names (`Counter`, `Plugin`, `Aggregate`, …); remove dead `~bus` params in DCB storage; `LocalBus`'s dead `silent` flag; hardcoded ports in `Platform.res:1912-2144` (route through `resolvePort`); pick one `Util_` naming convention.
- **sury absent-vs-null audit**: `spec/types/StoredEvent.res:37` uses `S.option` for `tags` in a JSON-encoded schema (violates the project's own js_nullable rule); interop uses `field?:` throughout and `Resource.res:8` has `option<string>` inside a union payload with only the `None` case tested. Audit + add `Some(_)` round-trip tests.

---

## Phase D — Tests & infrastructure

### D1 — test suites for untested packages

- **reventless-spec: zero in-package tests** despite publishing at `3.0.0-alpha.62`. Priority fixtures: grouped EP with two mappings (A8's compile-breaking bug), `extractTargetName` edge cases, `folderToComponentType` spellings, DcbValidation nested-drift cases.
- **reventless-vscode-protocol**: the C1 round-trip suite.
- **reventless-layer-builder**: post-process failure propagation, the rescript-dependency guard, plus a smoke-import of layer entry points and a size guard on the zip.

### D2 — targeted regression tests (land with their Phase A/B fixes)

Projection property test (optimized ≡ unoptimized), `CommandPublisher.flush/clear`, LocalBus failing-subscriber + unsubscribe, restart/read-model-rebuild under SQLite, MCP cursor pagination, conflict-sentinel classification, `runWatch` rerun state machine, `Collector` exception paths (`skipDepth`), `Loader`/worker isolation semantics, `ProcessManager.cleanRebuild` sequencing/respawn, `ChildProcess` partial-chunk buffering + `killTree`, golden outputs for human/TAP/JUnit formatters, `WatcherProbe`, interop `parseSemVer`/`validateProtocol` matrix.

### D3 — benchmarks + timing

- Synthetic-workspace generator (N plugins × M slices × K tests) + timed `discover`, `run`, watch re-run, `LocalHost.loadGraph`, and local-runtime query/replay benchmarks, with thresholds in CI. Track RSS across 100 watch re-runs (validates A1/B2's leak fix).
- A `timing` event in the vscode NDJSON protocol so CLI-side phase durations (discovery walk, load, domain analysis, per-package build) are observable by any client; the runner already measures per-test and per-build durations — surface them.

### D4 — runner robustness

- **In-band cancellation**: a stdin control line (`{"cmd":"cancelRun"}`) checked by the existing `Cancellation.isCancelled` poll — clients currently must kill the whole watch session (losing adopted build watchers).
- **Flaky-test support**: `--retries=N` re-running failures before reporting, with attempt metadata in `RunnerTypes.testResult` (`RunnerTypes.res:5-15`); most valuable for the async DSLs (Projection/SideEffect/Delegate).
- **Structured platform readiness**: replace the substring match on `"GraphQL:Domain"`/`"listening on"` (`PlatformRunner.res:33-34`) with an env-triggered structured readiness line owned by the framework, plus a readiness timeout (today a silent child hangs the session forever).
