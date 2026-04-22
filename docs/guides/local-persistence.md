# Local Persistence for the In-Memory Platform

By default the in-memory platform wipes all state on restart. If you are iterating on a UI, demoing a workflow, or replaying events across multiple dev sessions, you can opt into a SQLite-backed persistence layer that survives restarts without running a separate database server.

Jest tests continue to use the pure in-memory path — persistence is strictly opt-in.

---

## Two ways to enable SQLite

### Option 1 — Platform functor argument

```rescript
module Platform = InMemory.Platform.MakeWithConfig({
  let silent = false
  let splitApi = true
  let cloner = false
  let backend = Backend.Sqlite({
    path: "./.reventless/local.db",
    resetOnStart: false,
  })
})
```

Pass `resetOnStart: true` to wipe the file every time `Platform.MakeWithConfig` runs — matches the fresh-every-time behaviour that Jest relies on. Leave it `false` for dev sessions where you want data to accumulate across restarts.

### Option 2 — Environment variable

```bash
REVENTLESS_LOCAL_BACKEND=sqlite:./.reventless/local.db pnpm dev
```

The default `Platform.Make()` picks up `REVENTLESS_LOCAL_BACKEND` via `Backend.fromEnv()` — no code change required. Recognised values:

| Value | Effect |
|---|---|
| unset, empty, or `memory` | Pure in-memory (default) |
| `sqlite:<path>` | SQLite file at `<path>`, no reset |
| `sqlite:<path>?reset` | SQLite file at `<path>`, wiped on each construction |

---

## What gets persisted

Currently Phase 2 ships with SQLite-backed adapters for:

- **EventLog** — per-aggregate event streams, with optimistic concurrency via primary-key conflict
- **QueryDb** — read-model tables, one per registered QueryDb

The remaining surfaces (DCB event log, task bucket) fall back to in-memory. Restart will lose DCB-sourced state even when SQLite is active — see the [local-persistence plan](../plans/in-memory-local-persistence.md) for the roadmap.

---

## Inspecting the local database

SQLite writes one file at the configured path. You can poke at it with the standard CLI:

```bash
sqlite3 ./.reventless/local.db
sqlite> .tables
event_log  qdb_Orders  qdb_Products
sqlite> SELECT * FROM event_log LIMIT 5;
sqlite> SELECT partition_key, item FROM qdb_Orders LIMIT 5;
```

The schema is:

- `event_log(log_name, aggregate_id, seq_nr, payload, PRIMARY KEY(log_name, aggregate_id, seq_nr))`
- `qdb_<name>(partition_key, sub_key, item, PRIMARY KEY(partition_key, sub_key))` — one table per QueryDb

Delete the file to reset everything. Committing a sample `local.db` into a fixtures folder is a reasonable way to share a deterministic demo dataset with collaborators.

---

## What is persisted

All five storage surfaces are now SQLite-backed:

| Surface | Status |
|---|---|
| `EventLog` | persistent (Phase 2) |
| `QueryDb` (basic load/save/delete) | persistent (Phase 2) |
| `DcbEventLog` (events + tags + conditional append) | persistent (Phase 4) |
| `TaskBucket` (`put` / `get` helpers; bucket maker still returns dummy resource) | persistent (Phase 4) |
| `QueryDb` GSI indexes (`json_extract`-based SQLite indexes) | persistent (Phase 5) |
| `QueryDb` TTL (`expires_at` column + lazy filter) | persistent (Phase 5) |

A restart with `Backend.Sqlite({path, resetOnStart: false})` keeps all of the above intact. Use `resetOnStart: true` (or just delete the file) to start fresh.
