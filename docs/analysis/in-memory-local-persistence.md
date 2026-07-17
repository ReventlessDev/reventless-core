# Local Persistence for the In-Memory Provider — Analysis

**Status:** Analysis
**Date:** 2026-04-21

---

## Executive Summary

The `reventless-local` provider currently keeps every piece of state (event logs, DCB event log, query DBs, task bucket, pending commands) in ReScript `Dict`/`ref`/`Stm.TRef` values. Restarting the dev process — rerunning tests, restarting `pnpm dev`, reloading a GraphQL server — wipes all domain state, which is painful for any workflow that wants to iterate on a live dataset (UI development, manual QA, long-running demos, replay experiments).

This document compares lightweight embedded databases, scores them against Reventless's storage interfaces, and recommends an approach that:

1. **Keeps the pure in-memory path intact** — zero behavioural change when persistence is disabled.
2. **Adds an opt-in on-disk backend** that survives restarts without a server process.
3. **Lets a developer pick the backend per platform** with a single construction parameter (or one env var).

**Recommendation:** ship a second adapter implementation backed by **SQLite** (via `better-sqlite3` on Node, falling back to `node:sqlite` on Node 22.5+ or `bun:sqlite` under Bun). SQLite is the only candidate that matches all four Reventless storage interfaces without hand-rolled secondary indexes, stays inside a single file, and keeps the synchronous API shape the current code already uses.

---

## What We Need to Persist

Only the four storage surfaces need durability. The bus, command handlers, subscription plumbing, and heartbeat runner stay in-process.

| Surface | Current in-memory shape | Semantics that must survive restart |
|---|---|---|
| [EventLog](../../reventless/local/src/adapter/EventLog/EventLogStorage_InMemory.res) | `dict<array<JSON>>` per aggregate instance, wrapped in `Stm.TRef` | Append-only per `id`, optimistic concurrency on `seqNr == currentCount`, replay in insertion order, streaming replay |
| [DcbEventLog](../../reventless/local/src/adapter/DcbEventLog/DcbEventLogStorage_InMemory.res) | `ref<array<rawSequencedEvent>>` with monotonic `position` counter | Append with conditional check (query + `after`), read with tag/event-type filter, head position, streaming read |
| [QueryDb](../../reventless/local/src/adapter/QueryDb/QueryDbStorage_InMemory.res) | `ref<dict<dict<JSON>>>` — partition key → sub-key → item | `load` by partition key (sub-key ordered), `save`/`delete` by `(id, subId)`, batch variants, scan-all, optional sub-id field extraction, optional GSI indexes, optional TTL |
| [TaskBucket](../../reventless/local/src/adapter/Task/TaskBucket_InMemory.res) | Currently a no-op stub | Object storage (key → bytes). No current state; a persistent backend should at least store key/bytes pairs for later task replay |

Non-negotiable properties the chosen backend must supply or let us implement cheaply:

- **Compare-and-set on write** — EventLog's per-aggregate sequence number and DCB's conditional append both need a conflict check inside the same write transaction.
- **Ordered iteration under a prefix** — QueryDb returns sub-key-sorted items; DcbEventLog returns events after a given position.
- **Secondary-attribute filtering** — DcbEventLog tag queries (`AND` over `{key, value}` pairs) must not require a full scan at realistic dev dataset sizes.
- **Embedded, single-file, zero server** — we must not introduce a background daemon.
- **Synchronous or same-tick-settling API** — the existing storage functions are `async` but mostly resolve immediately; an async driver that adds IO latency to every `save` changes observable test timings and undermines the 2/3-tick guarantees documented in [InMemory_Bus.res](../../reventless/local/src/adapter/InMemory_Bus.res).
- **Clean reset/truncate** — tests call `Bus.reset()` between runs; the persistent backend needs the equivalent (`DELETE FROM *` or file truncation) gated behind a flag so developer sessions don't lose data.

---

## Candidate Comparison

Scoring legend: ✓ fits directly · ~ fits with modest code · ✗ significant mismatch or missing.

| Candidate | EventLog | DcbEventLog tag filter | QueryDb sub-key + GSI | Sync API | Install / binary | Notes |
|---|---|---|---|---|---|---|
| **SQLite — `better-sqlite3`** | ✓ UNIQUE(id, seq_nr) | ✓ JOIN on tags table w/ index | ✓ composite PK + named indexes | ✓ synchronous C++ | Prebuilt native ~1 MB | Most popular Node SQLite; used by Effect's own `SqliteClient` |
| **SQLite — `node:sqlite` (built-in)** | ✓ same schema | ✓ same | ✓ same | ✓ synchronous | 0 bytes (shipped with Node ≥ 22.5) | Experimental flag but stable in 22.17.x; no install step |
| **SQLite — `bun:sqlite`** | ✓ same | ✓ same | ✓ same | ✓ synchronous | 0 bytes under Bun | Only active under Bun runtime; Jest under Node still needs another driver |
| **LMDB (`lmdb-js`)** | ✓ key `events/{id}/{seq}` | ~ needs hand-rolled `tags/{key}/{value}/{pos}` index table | ~ needs named sub-DBs per index | ✓ synchronous reads | Native, ~1 MB | Fastest reads (mmap); every secondary index is manual and must stay consistent inside the same txn |
| **LevelDB / classic-level** | ✓ prefix keys | ✗ tag AND queries become N-way stream merges | ~ manual | Async only | Native | Good append throughput but every read becomes async — breaks tick-timing assumptions |
| **DuckDB** | ✓ SQL | ✓ SQL | ✓ SQL | ✓ synchronous | Native, ~40 MB | Optimised for analytics, not for tiny OLTP inserts; huge binary for dev-only use |
| **PouchDB** | ~ _rev-based OCC | ~ via Mango / views (warmup cost) | ~ views | Async only | Pure JS, ~500 KB | Appeal is browser parity; materially slower on every path |
| **LokiJS** | ✓ array + unique index | ~ requires two indexes joined in app code | ~ secondary indexes | ✓ sync writes, periodic autosave | Pure JS, ~100 KB | "Save everything" snapshot persistence — not append-only; risk of losing recent writes on crash |
| **NeDB** | — | — | — | — | — | Deprecated; excluded |
| **SurrealDB embedded** | ✓ | ✓ | ✓ | Async only | Native, large | Overkill for a dev fallback; still maturing embedded JS support |
| **Redis (embedded mocks)** | Stream type | Sorted sets | Hashes | Async | Typically server-based | Requires external daemon for a real persistence story |

### Why SQLite wins on fit

Every Reventless interface maps to a small, obvious SQL schema:

```sql
-- EventLog (one table per platform, partitioned by log name)
CREATE TABLE event_log (
  log_name TEXT NOT NULL,
  aggregate_id TEXT NOT NULL,
  seq_nr INTEGER NOT NULL,
  payload TEXT NOT NULL,      -- JSON.stringify
  PRIMARY KEY (log_name, aggregate_id, seq_nr)
);
-- Optimistic concurrency: INSERT … and let the PK conflict become an "Error(conflict)".

-- DcbEventLog
CREATE TABLE dcb_event (
  log_name  TEXT NOT NULL,
  position  INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  data      TEXT NOT NULL,
  PRIMARY KEY (log_name, position)
);
CREATE TABLE dcb_tag (
  log_name  TEXT NOT NULL,
  position  INTEGER NOT NULL,
  tag_key   TEXT NOT NULL,
  tag_value TEXT NOT NULL
);
CREATE INDEX dcb_tag_by_kv ON dcb_tag(log_name, tag_key, tag_value, position);

-- QueryDb (one table per registered QueryDb)
CREATE TABLE qdb_<name> (
  partition_key TEXT NOT NULL,
  sub_key       TEXT NOT NULL DEFAULT '',
  item          TEXT NOT NULL,
  PRIMARY KEY (partition_key, sub_key)
);
-- Declared GSIs become additional covering indexes on computed columns.

-- TaskBucket
CREATE TABLE task_object (
  bucket TEXT NOT NULL,
  key    TEXT NOT NULL,
  body   BLOB NOT NULL,
  PRIMARY KEY (bucket, key)
);
```

This is ~80 lines of schema that covers every adapter. With `better-sqlite3`'s synchronous API:

- `append` stays an `async` function that calls synchronous SQL inside `Stm.commit`'s effect chain — same tick count as the current `Dict`-based implementation.
- `replayStream` wraps a prepared statement's `iterate()` into `Stream.fromIterable` without loading the whole log.
- Tag filtering for DCB becomes a single `JOIN dcb_tag` per query element, indexed on `(tag_key, tag_value)`.
- QueryDb sub-key ordering is a single `ORDER BY sub_key` — matching the existing `Array.toSorted` contract.
- `saveBatch`/`deleteBatch` wrap in a `BEGIN … COMMIT` and keep the atomic-per-batch semantics the current code relies on.

### Why SQLite wins on footprint

| Metric | `better-sqlite3` | `lmdb-js` | `classic-level` | `duckdb` |
|---|---|---|---|---|
| Install size on disk (unpacked) | ~4 MB | ~6 MB | ~3 MB | ~45 MB |
| Cold-start (first `open`) | <5 ms | <5 ms | ~20 ms | ~80 ms |
| Write amplification for append-only events | 1 row | 1 key + N tag-index keys | 1 key + N tag-index keys | SQL row + WAL |
| Has prebuilt binaries for macOS/Linux/Windows x64/arm64 | ✓ | ✓ | ✓ | ✓ |
| Works under Jest ESM without `--experimental-vm-modules` hacks | ✓ | ~ (native-module gotchas) | ~ | ~ |

SQLite keeps the dev database in **one file** (`./.reventless/local.db` by default), which is easy to delete, inspect with `sqlite3` CLI, or commit into a fixture folder for deterministic demos.

### When another backend might still be worth carrying

- **LMDB** is meaningfully faster for read-heavy replay workloads (memory-mapped). If we ever add a "replay from history" benchmark suite, LMDB could win on raw numbers — but it needs us to own every secondary index, which is exactly the code SQLite spares us from.
- **PouchDB** would be interesting only if we want the *same* persistence engine in the browser; that question is already covered in [reventless-livestore-integration.md](./reventless-livestore-integration.md), and LiveStore itself sits on SQLite.

---

## Keeping Both Backends Supported

### Driving constraint

The current in-memory adapters are functors of `InMemory_Bus.T`. Their module types (`EventLog_Adapter.storageMaker`, `QueryDb_Adapter.storageMaker`, `DcbEventLog_Adapter.storageMaker`, `Task_Adapter.bucketMaker`) are fixed by `ReventlessCore`. A persistent backend must produce values of the same types so every platform-level call site stays unchanged.

That means: **two implementations of each `*_InMemory.res` file, both registering themselves against the same Bus interface**. Only the `storageMaker` body differs.

### Package and module layout

Two viable shapes. Both keep `reventless-local` the default and additive.

**Option A — extend the existing package (recommended).**
```
reventless/local/src/adapter/
  EventLog/
    EventLogStorage_InMemory.res           # current Dict-based
    EventLogStorage_Sqlite.res             # new
  DcbEventLog/
    DcbEventLogStorage_InMemory.res
    DcbEventLogStorage_Sqlite.res
  QueryDb/
    QueryDbStorage_InMemory.res
    QueryDbStorage_Sqlite.res
  Task/
    TaskBucket_InMemory.res
    TaskBucket_Sqlite.res
  Backend.res                              # new — backend selector
```

Pros: single `@reventlessdev/reventless-local` dependency for app developers; no workspace duplication; `Backend.res` is the one place that knows about both.

Cons: `better-sqlite3` becomes an optional peer dep. The package's `package.json` should declare it as `peerDependenciesMeta.optional = true` so pure-memory users don't download a native binary.

**Option B — new package `reventless-local`.**

Keeps the native binary entirely out of `reventless-local`. Costs: two packages to publish in lockstep, a second functor layer in platform construction. Only worth doing if users who install `reventless-local` for CI/testing really do not want the SQLite peer dep present.

**Recommendation: Option A.** Fewer moving parts; the native binary is optional; one import path for app developers.

### Developer-facing selector

The Platform currently looks roughly like:

```rescript
module Platform = InMemory.Platform.Make()   // constructs bus + registers adapters
```

We can extend `Platform.Make` to accept a backend config without breaking existing code:

```rescript
// Default — identical to today
module Platform = InMemory.Platform.Make()

// Opt in to persistence
module Platform = InMemory.Platform.Make({
  let backend = InMemory.Backend.Sqlite({path: "./.reventless/local.db"})
})
```

`InMemory.Backend.t` becomes:

```rescript
type t =
  | Memory                                 // current behaviour
  | Sqlite({path: string, resetOnStart: bool})
```

Mechanism:

- `Platform.Make` inspects `backend` and passes the chosen concrete module to each component builder. Because both `EventLogStorage_InMemory` and `EventLogStorage_Sqlite` implement `EventLog_Adapter.Storage`, the swap is a single `module Impl = …` binding.
- `resetOnStart: true` wipes the SQLite file on construction — matches today's fresh-every-test behaviour for Jest.
- An env var shortcut (`REVENTLESS_LOCAL_BACKEND=sqlite:./.reventless/local.db`) is read inside `Backend.fromEnv()` for developers who prefer to keep platform code unchanged and flip backends per shell.

### Behavioural parity tests

Every test in [reventless-local/tests/](../../reventless/local/tests/) should run under both backends. Concretely: a `describe.each([Memory, Sqlite])` wrapper (ReScript-flavoured via `Jest.describe` + a backend-selector fixture) so any divergence between the two adapters becomes a visible test failure. The small number of timing-sensitive tests (fake timers, subscriber count assertions) are unaffected — SQLite calls are synchronous and do not change microtask counts.

### Reset semantics

- `Bus.reset()` (test-level) — clears in-process registries AND issues `DELETE FROM …` across all tables. No file deletion; the DB file is reused.
- `Backend.resetOnStart` — destroys and recreates the file at `Platform.Make` time. Keeps fresh-start determinism for Jest while letting `pnpm dev` leave the file alone by default.
- `Platform.close()` (new) — closes the SQLite handle. Today the memory backend has nothing to close; this is a no-op there.

---

## Risks and Open Questions

- **Native binding availability in Bun.** `better-sqlite3` works under Bun via the Node N-API compatibility layer, but `bun:sqlite` is cheaper. If we detect `globalThis.Bun`, we should prefer `bun:sqlite`. Both expose the same `prepare`/`run`/`iterate` shape; a thin 30-line wrapper module abstracts the two.
- **Schema migration.** Early versions can recreate the schema on start (`CREATE TABLE IF NOT EXISTS`). Once we commit to keeping data across Reventless releases, we need a migration system. Recommendation: punt until after the first usable release; add `PRAGMA user_version` and a migration table then.
- **GSI semantics.** `QueryDb` already accepts a rich index descriptor (partition/sort, projection type, INCLUDE fields). Memory ignores it; SQLite would honour it via computed columns + indexes. That closes an existing gap where memory diverged from DynamoDB behaviour.
- **TTL.** `QueryDb.save` takes an optional TTL. Memory ignores it. SQLite would need a lazy-expiry helper (`WHERE expires_at IS NULL OR expires_at > ?`) or a periodic cleanup task.
- **Interaction with [reventless-livestore-integration.md](./reventless-livestore-integration.md).** LiveStore is SQLite-backed on the client. If we later ship that integration, the server's SQLite schema for EventLog is a natural sync target — so the choice made here does not conflict.

---

## Recommended Next Steps

1. Prototype `EventLogStorage_Sqlite.res` + `QueryDbStorage_Sqlite.res` behind a `Backend.Sqlite` selector in `reventless-local`. Keep the memory adapters untouched.
2. Wire the backend selector through `Platform.Make`; add an env-var shortcut.
3. Port every existing adapter test to run under both backends (`describe.each`).
4. Add `DcbEventLogStorage_Sqlite.res` + `TaskBucket_Sqlite.res` once the event-log + query-db path is green.
5. Write a short dev guide (`docs/guides/local-persistence.md`) showing the two selection styles (Platform functor arg, env var) and the reset flag.

Total effort: ~1–2 weeks for a working SQLite backend with adapter-level parity tests; another ~1 week if we add TTL and GSI fidelity.
