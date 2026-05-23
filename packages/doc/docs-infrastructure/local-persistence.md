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

## Verifying the active backend

On startup `makePlatform` logs which backend is in use:

```
[Platform] backend: memory
[Platform] backend: sqlite (./.reventless/local.db)
[Platform] backend: sqlite (./.reventless/local.db, resetOnStart)
```

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

All five storage surfaces are SQLite-backed:

| Surface | Status |
|---|---|
| `EventLog` | persistent |
| `QueryDb` (basic load/save/delete) | persistent |
| `DcbEventLog` (events + tags + conditional append) | persistent |
| `TaskBucket` (`put` / `get` helpers; bucket maker still returns dummy resource) | persistent |
| `QueryDb` GSI indexes (`json_extract`-based SQLite indexes) | persistent |
| `QueryDb` TTL (`expires_at` column + lazy filter) | persistent |

A restart with `Backend.Sqlite({path, resetOnStart: false})` keeps all of the above intact. Use `resetOnStart: true` (or just delete the file) to start fresh.
