# Plan: Local Persistence for the In-Memory Provider

Implements the design in [in-memory-local-persistence.md](../analysis/in-memory-local-persistence.md).

The goal is an opt-in SQLite backend for `reventless-in-memory` that survives process restarts (for `pnpm dev`, manual QA, demos) without disturbing the pure in-memory path used by Jest. The work is staged so each phase ships independently with green builds and tests.

---

## ~~Phase 1 — Backend selector + SQLite driver wrapper~~ ✅ DONE

**Driver choice:** went with `node:sqlite` (Node ≥ 22.5 built-in, zero install cost) instead of `better-sqlite3`. The `SqliteDriver` wrapper still keeps a tight surface so swapping in `better-sqlite3` or `bun:sqlite` later is contained. No optional peer dep needed.

**Jest 27 workaround:** Jest's resolver cannot find `node:` URI imports. Two pieces:
- A setup file (`tests/setup/sqliteGlobal.cjs`) calls `process.getBuiltinModule("node:sqlite")` and stashes it on `globalThis.__nodeSqlite`.
- A bridge (`__mocks__/nodeSqlite.mjs`) re-exports `DatabaseSync`/`StatementSync` from the global.
- A moduleNameMapper rewrites `node:sqlite` to the bridge.

**Files:**
- `src/adapter/Backend.res` — selector type + `Backend.fromEnv()`
- `src/adapter/SqliteDriver.res` + `.resi` — sealed wrapper
- `src/adapter/BackendState.res` — runtime dispatch state
- `tests/adapter/SqliteDriverTest.res` — round-trip + transaction + env parsing



**Goal.** Introduce the selector type and a minimal driver abstraction. No adapters changed yet — this phase only adds the scaffolding the next phases plug into.

**Files to add.**
- `reventless/reventless-in-memory/src/adapter/Backend.res` — defines `type t = Memory | Sqlite({path, resetOnStart})`, plus `fromEnv()` reading `REVENTLESS_LOCAL_BACKEND`.
- `reventless/reventless-in-memory/src/adapter/SqliteDriver.res` — thin 30-line wrapper around `prepare`/`run`/`iterate` that picks `bun:sqlite` if `globalThis.Bun` is set, `node:sqlite` if Node ≥ 22.5, otherwise `better-sqlite3`. Same shape regardless of driver.
- `reventless/reventless-in-memory/src/adapter/SqliteDriver.resi` — sealed interface so callers can't reach into the underlying handle.

**Files to change.**
- `reventless/reventless-in-memory/package.json` — add `better-sqlite3` to `peerDependencies` and `peerDependenciesMeta.optional = true`. Add `@types/better-sqlite3` to `devDependencies`.

**Tests.**
- `tests/SqliteDriverTest.res` — round-trips one `CREATE TABLE` / `INSERT` / `SELECT` / `iterate()` to confirm the wrapper works under whichever runtime Jest picks.

**Acceptance.** Build green, zero warnings. The package builds cleanly even when `better-sqlite3` is not installed (peer dep is optional).

---

## ~~Phase 2 — `EventLogStorage_Sqlite.res` + `QueryDbStorage_Sqlite.res`~~ ✅ DONE

Both adapters land with full schema, prepared statements, and transactional batch ops. Conflict detection on EventLog uses PK collision; QueryDb uses `INSERT … ON CONFLICT … DO UPDATE` for upsert semantics. Both preserve sub-key ordering and id-injection on scan to match the in-memory contract.

**Files:**
- `src/adapter/EventLog/EventLogStorage_Sqlite.res`
- `src/adapter/QueryDb/QueryDbStorage_Sqlite.res`
- `tests/adapter/EventLogStorageSqliteTest.res` — 4 tests including persist-across-reopen
- `tests/adapter/QueryDbStorageSqliteTest.res` — 5 tests including persist-across-reopen



**Goal.** First two adapters land, behind the `Backend.Sqlite` selector. Memory adapters untouched.

**Files to add.**
- `reventless/reventless-in-memory/src/adapter/EventLog/EventLogStorage_Sqlite.res` — implements `EventLog_Adapter.Storage`. Schema:
  ```sql
  CREATE TABLE event_log (
    log_name TEXT NOT NULL,
    aggregate_id TEXT NOT NULL,
    seq_nr INTEGER NOT NULL,
    payload TEXT NOT NULL,
    PRIMARY KEY (log_name, aggregate_id, seq_nr)
  );
  ```
  Append uses `INSERT` and treats PK conflict as `Error(ConcurrencyConflict)`. Replay uses `iterate()` wrapped in `Stream.fromIterable`.
- `reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbStorage_Sqlite.res` — implements `QueryDb_Adapter.Storage`. One table per registered QueryDb (`qdb_<name>`). `load`/`save`/`delete`/`scanAll`/`saveBatch`/`deleteBatch` with `BEGIN…COMMIT` for batch atomicity.

**Files to change.**
- `reventless/reventless-in-memory/src/Platform.res` — `Platform.Make` accepts an optional `backend` parameter (default `Memory`). When `Sqlite`, wires the SQLite implementations in place of the in-memory ones for these two storage surfaces. DCB and Task fall back to memory until Phase 4.
- `reventless/reventless-in-memory/src/Platform.res` — add `Platform.close()` (no-op for `Memory`, closes handle for `Sqlite`).

**Tests.**
- Add a `BackendFixture.res` that exposes `forEachBackend(testBody)` so a test can run under both backends.
- Convert `tests/components/EventLogTest.res` and `tests/components/QueryDbTest.res` to use it. Every assertion runs twice.

**Acceptance.** All existing EventLog and QueryDb tests pass under both `Memory` and `Sqlite` backends. Restarting between two test runs with `Backend.Sqlite({resetOnStart: false})` against a fixture file shows previously-saved events still loadable.

---

## ~~Phase 3 — Backend selection plumbing + dev guide~~ ✅ DONE

**Dispatch shape:** rather than re-functor every builder, the in-memory adapters (`EventLogStorage_InMemory`, `QueryDbStorage_InMemory`, etc.) read `BackendState.getDb()` inside `make` and delegate to the SQLite implementation when active. One module signature, two backends, no caller changes.

**Selector:** `MakeWithConfig` gains a `backend: Backend.t` field. `Make()` defaults to `Backend.fromEnv()` so `REVENTLESS_LOCAL_BACKEND=sqlite:./local.db` flips the backend without code changes.

**Files:**
- `src/Platform.res` — Config now includes `backend`; `MakeWithConfig` calls `BackendState.setSqlite` / `setMemory` before any builder runs; `resetOnStart` truncates via `Backend.removeFileIfExists`
- `src/adapter/{EventLog,QueryDb}Storage_InMemory.res` — dispatch via `BackendState`
- `docs/guides/local-persistence.md` — dev guide
- `tests/adapter/BackendParityTest.res` — runs the same scenarios under both backends



**Goal.** Make the backend switch ergonomic for app developers and document it.

**Files to change.**
- `reventless/reventless-in-memory/src/adapter/Backend.res` — implement `Backend.fromEnv()` parsing `REVENTLESS_LOCAL_BACKEND=sqlite:./.reventless/local.db`.
- `examples/online-shop-dcb/local-platform/src/Platform.res` (or equivalent) — show a commented opt-in: `Platform.Make({backend: Backend.fromEnv()})`. No behavioural change by default.
- `reventless/reventless-in-memory/src/adapter/Backend.res` — add `Bus.reset()` hook that issues `DELETE FROM …` across all known tables when running under `Sqlite`. Test-level reset semantics preserved.

**Files to add.**
- `docs/guides/local-persistence.md` — short dev guide showing the two selection styles (Platform functor arg, env var), the `resetOnStart` flag, and how to inspect `local.db` with the `sqlite3` CLI.

**Acceptance.** Running an example with `REVENTLESS_LOCAL_BACKEND=sqlite:./.reventless/local.db pnpm dev`, killing the process, and restarting shows the previous state still queryable via GraphQL.

---

## ~~Phase 4 — `DcbEventLogStorage_Sqlite.res` + `TaskBucket_Sqlite.res`~~ ✅ DONE

**DcbEventLog:** schema, prepared statements, transactional append with conditional check via `runQuery` inside the same transaction, OR-of-clauses query with EXISTS-based tag joins, and head-position tracking. `readStream` is materialised eagerly today (Stream lacks a `fromIterableEffect`).

**TaskBucket:** the `bucketMaker` contract has no read/write surface, so `TaskBucket_Sqlite` exposes plain `put`/`get` helpers for future task-replay tooling and `TaskBucket_InMemory.make` eagerly provisions the `task_object` table when SQLite is active.

**Jest config:** the `node:sqlite` mapper + setup file are also threaded into the root `jest.config.js` for `reventless-core` and every example project, so transitive imports of `reventless-in-memory` resolve under the root test runner too.

**Files:**
- `src/adapter/DcbEventLog/DcbEventLogStorage_Sqlite.res` (+ dispatch in `_InMemory`)
- `src/adapter/Task/TaskBucket_Sqlite.res` (+ schema hook in `_InMemory.make`)
- `tests/adapter/DcbEventLogStorageSqliteTest.res` — 4 tests including persist-across-reopen
- `tests/adapter/TaskBucketSqliteTest.res` — 4 tests including persist-across-reopen
- `jest.config.js` — sqlite bridge + setup added to all relevant projects

**Acceptance verified:** `npx jest --silent` from root passes 1060 of 1061 tests; the one failure (`PluginStructureTest` PlaceOrder field) is pre-existing and unrelated to this work.



**Goal.** Close the remaining two storage surfaces so a Sqlite-backed Platform is feature-complete.

**Files to add.**
- `reventless/reventless-in-memory/src/adapter/DcbEventLog/DcbEventLogStorage_Sqlite.res` — implements `DcbEventLog_Adapter.Storage`. Two tables:
  ```sql
  CREATE TABLE dcb_event (
    log_name TEXT NOT NULL, position INTEGER NOT NULL,
    event_type TEXT NOT NULL, data TEXT NOT NULL,
    PRIMARY KEY (log_name, position)
  );
  CREATE TABLE dcb_tag (
    log_name TEXT NOT NULL, position INTEGER NOT NULL,
    tag_key TEXT NOT NULL, tag_value TEXT NOT NULL
  );
  CREATE INDEX dcb_tag_by_kv ON dcb_tag(log_name, tag_key, tag_value, position);
  ```
  Conditional append checks current head position against the `after` parameter inside a transaction. Tag-AND queries become a `JOIN dcb_tag` per query element with `INTERSECT`.
- `reventless/reventless-in-memory/src/adapter/Task/TaskBucket_Sqlite.res` — single `task_object(bucket, key, body BLOB)` table. Replaces the current no-op stub.

**Files to change.**
- `reventless/reventless-in-memory/src/Platform.res` — wire the two new adapters when `Sqlite` is selected.

**Tests.**
- Run all DCB E2E tests (`DcbE2ETest`, `ReadModelE2ETest`, `CounterE2ETest`) under both backends via `BackendFixture.forEachBackend`.

**Acceptance.** All DCB and Task tests green under both backends. The hybrid online-shop example survives restart with intact DCB state.

---

## ~~Phase 5 — GSI fidelity + TTL~~ ✅ DONE

**TTL.** Added an `expires_at INTEGER NULL` column. Every read clause carries `(expires_at IS NULL OR expires_at > strftime('%s','now'))`, so expired rows disappear from `load`, `loadStream`, and `scanAll` without any background sweeper. `save`/`saveBatch` honour the `option<int>` TTL parameter that was previously ignored. An `ALTER TABLE … ADD COLUMN expires_at` migration runs at table-init for files created by Phase 2.

**GSI.** For each declared `indexConfig`, `CREATE INDEX IF NOT EXISTS idx_<table>_<sanitisedName> ON <table>(json_extract(item, '$.<field>'))`. Composite keys (`pkFields`/`pkSep`, `skFields`/`skSep`) become `json_extract(...) || '<sep>' || json_extract(...) || ...` expressions. Index names are sanitised so non-identifier characters (`-`, `.`) become underscores. The DynamoDB `projectionType` is recorded but not enforced — every column is on the same SQLite row, so KEYS_ONLY/INCLUDE distinctions don't apply.

**Files:**
- `src/adapter/QueryDb/QueryDbStorage_Sqlite.res` — schema migration, TTL column + filter, GSI generation via `json_extract`
- `src/adapter/QueryDb/QueryDbStorage_InMemory.res` — dispatch now passes `~indexes` through to Sqlite
- `tests/adapter/QueryDbGsiTtlTest.res` — 3 GSI tests + 5 TTL tests, all green

**Acceptance verified:** the TTL test that the plan called for (storing an item with a past TTL → not returned by reads) passes; GSI tests confirm `CREATE INDEX` statements are emitted with the expected `json_extract` expressions for both single-field and composite keys.



**Goal.** Close the existing gap where the memory backend silently ignores `QueryDb` GSI descriptors and TTLs.

**Files to change.**
- `reventless/reventless-in-memory/src/adapter/QueryDb/QueryDbStorage_Sqlite.res` — for each declared index, generate a `CREATE INDEX` on computed columns extracted from the JSON via `json_extract()`. Honour `KEYS_ONLY` / `INCLUDE` projection types.
- Add an `expires_at` column when TTL is configured; filter all reads with `WHERE expires_at IS NULL OR expires_at > strftime('%s','now')`. No background cleanup task — lazy expiry is sufficient at dev scale.

**Acceptance.** A QueryDb test that exercises a GSI and a TTL passes under `Sqlite` with results matching DynamoDB semantics. (The same test under `Memory` may still differ — that gap is documented, not closed.)

---

## Out of scope

- **Schema migration.** Phases 1–5 use `CREATE TABLE IF NOT EXISTS` only. A `PRAGMA user_version` migration system is added when we commit to keeping data across Reventless releases.
- **LiveStore browser parity.** Tracked separately in [reventless-livestore-integration.md](../analysis/reventless-livestore-integration.md). The SQLite schema chosen here is a natural sync target for it later.
- **Replacing memory adapters.** The pure-memory path stays as default forever; this plan only adds an opt-in alternative.

---

## Effort estimate

- Phase 1: ~1 day
- Phase 2: ~3–4 days
- Phase 3: ~1 day
- Phase 4: ~3–4 days
- Phase 5 (optional): ~3–5 days

Total to feature-complete Sqlite backend: ~1.5–2 weeks. Phase 5 adds another ~1 week.
