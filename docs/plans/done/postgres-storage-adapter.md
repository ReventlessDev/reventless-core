# Plan: Postgres storage backend (`reventless-postgres`) + local-platform integration

**Status**: In progress (2026-07-04) — package Phases A–D built & compiling clean;
F2 concurrency suite written (skips without `PG_URL`). Awaiting a live Postgres
to run F2 and validate the `dcb_append` concurrency core before the invasive
Phase E local-platform integration. See **Progress** below.

## Progress (2026-07-04)

**Done — `reventless/reventless-postgres` package (compiles clean, zero warnings):**

- **A1** `PgDriver.res(i)` — async `pg` wrapper (pool, `query`/`queryOne`/`exec`,
  single-connection `transaction`, LISTEN/NOTIFY). Diverges from the sync
  `SqliteDriver`: `pg` has no synchronous client, so makers stay synchronous
  (close over the pool; operations are already async) and schema setup is a
  separate async step.
- **A2** `PgSchema.res` — idempotent `ensureSchema(pool)` (classic `event_log` +
  `snapshot`, `dcb_event` with `xid8`/IDENTITY, `dcb_scope`, `dcb_subscription`,
  GIN + btree indexes) and `truncateAll` for `resetOnStart`.
- **A3** `EventLogStorage_Postgres.res` — classic OCC as a single atomic guarded
  `INSERT … SELECT … WHERE $seq = expected_next` (gap-proof; racing writers
  collide on the PK → Conflict). `payload jsonb` returns pre-parsed.
- **B1** `dcb_append(log, events, condition, lock_strategy)` PL/pgSQL: scoped
  advisory locks (`hashtextextended`, namespaced per log, sorted acquisition) +
  **exact server-side condition check** (the `DcbTag.query` is passed as a jsonb
  AST and compiled to SQL in `dcb_condition_where`, all values `quote_literal`-d)
  + insert + `pg_notify`. One round trip, transaction-scoped.
- **B2** Cursor `<xid8>:<position>` (each zero-padded to 20 → string sort ==
  numeric sort); reads apply the `pg_snapshot_xmin` barrier; the condition
  check uses the **same two-column `(transaction_id, position)` comparison** as
  reads (decoded from the cursor), so read→decide→append is exact. The append
  check deliberately skips the fence (must see latest committed state).
- **B3** `readStream` — real keyset pagination via `Stream.paginateEffect` on
  `(transaction_id, position)`.
- **B4** `~lockStrategy` `#AdvisoryLocks` (default) / `#RowLocks` (`dcb_scope`
  `FOR UPDATE`), threaded into `dcb_append`.
- **C1** `QueryDbStorage_Postgres.res` — JSONB document tables implementing the
  clean `QueryDb_Adapter.storageMaker` (the DynamoDB shape, **no in-process
  bus**; the local bus bridge is an E concern). Async schema gated behind a
  `ready` promise. **C2** `QueryEnginePostgres.res` — query/scan filter AST → SQL.
- **D1/D2** `PgChangeFeed.res` — checkpointed fenced read + `dcb_subscription`
  checkpoints + LISTEN wakeup + a `drain` reference consumer. The feed-consumer
  API (`readBatch`/`loadCheckpoint`/`saveCheckpoint`/`listen`/`drain`) is the
  documented public surface.
- **F2** `tests/PostgresIntegrationTest.res` — classic OCC, DCB round-trip,
  conditional-append conflict, **two-writer write-skew (both lock strategies)**,
  cursor monotonicity, change-feed drain. Skips unless `PG_URL` is set.

**Design decisions / deviations from the draft (all deliberate):**

1. **Async driver, not a `SqliteDriver.resi` mirror.** No synchronous Postgres
   client exists in Node. Storage *operations* are already async so they fit;
   only *schema setup* moved out to an explicit async step.
2. **Condition check is server-side from a jsonb AST** (not a host-compiled
   WHERE), keeping `dcb_append` a single round trip as the plan's B1 intends,
   while still "compiling `DcbTag.query` to SQL as the SQLite backend does".
3. **`dcb_append` returns the encoded cursor** (not a bare position) so
   read→decide→append round-trips on both columns.
4. **`hashtextextended`** replaces hand-rolled FNV-1a — a stable Postgres
   built-in; collisions only coarsen locking, never affect correctness.
5. **Projection-checkpoint seam is an injected `~onAppended` callback**
   (`ProjectionPending`/`ProjectionCheckpoint` are reventless-local-only), so the
   package stays free of local-platform coupling.
6. **QueryDb split**: the package ships the clean bus-less storage; the
   bus-coupled variant lives in the local platform (E).

**VALIDATED against live Postgres 16 (2026-07-05):** F2 suite — 8/8 green,
including two-writer write-skew (both lock strategies) and a 12-writer hot-tag
test (exactly one wins, no lost updates). The `dcb_append` concurrency core is
proven: `xid8` casts, `hashtextextended` advisory locks, the xmin barrier,
cursor encoding, `WITH ORDINALITY` ordering, and the guarded classic insert all
behave correctly.

**Done — Phase E (local-platform integration):**

- **E1** `Backend.postgres(~connection, ~resetOnStart)` — an **async smart
  constructor** (connect + `ensureSchema` + optional truncate + `countAll`) that
  returns a `Backend.Postgres({pool, initialCount, connection})` variant carrying
  a ready pool, so `Platform.MakeWithConfig` stays a synchronous functor.
  `BackendState` gains a `Postgres` arm + `setPostgres`/`getPostgresPool`.
- **E2** Event-log dispatchers route to the Postgres runtime.
  **Dispatch refactor (requested):** the backend switch was hoisted OUT of the
  `*Storage_InMemory.res` files (a naming smell) into dedicated
  `LocalEventLogStorage` / `LocalDcbEventLogStorage` / `LocalQueryDbStorage`
  `Make(Bus)` modules; the `_InMemory` files now hold only the pure in-memory
  impl. All ~50 `*Storage_InMemory.Make` call sites repointed. Full
  reventless-local suite: **475/475 green**; whole monorepo builds clean.
- **Scope (documented in code + Platform.res):** `Backend.Postgres` persists the
  durable **event logs** (classic + DCB). Read models (QueryDb) route to the
  in-memory live-query arm — the LocalBus scan/stream registrations are
  synchronous and async pg can't satisfy them without a broader bus refactor; the
  package's `QueryDbStorage_Postgres` remains available to deploy-time compute
  layers. Tasks remain file/SQLite/memory-backed.
- **Startup replay (`PgProjectionCatchup`):** because read models are in-memory
  (empty on start), they are **rebuilt on every startup** by full-replaying the
  durable pg event log `(0, head]` through the projection handlers — read models
  are derived data, the log is the source of truth. The pre-session head is
  captured before plugins build so this session's live-delivered events aren't
  redelivered; envelopes are reconstructed by `ProjectionCheckpoint`'s builders so
  they match live delivery exactly. No persisted checkpoint is needed (full
  replay from 0). Validated live: `PgProjectionCatchupTest` (3/3).

**Done — Phase F:**

- **F1** `BackendParityTest.runUnderPostgres` (guarded on `PG_URL`) — the EventLog
  scenarios run under Postgres alongside Memory/Sqlite. Green with and without a DB.
- **F2** live concurrency suite — 8/8 (see above).
- **F3** `.github/workflows/postgres.yml` — `postgres:16` service-container job.

**Done — F4 (typed DCB `appendError`):** replaced the `Error("conflict")`
substring convention with a typed variant `Conflict | StorageFailure(string)`,
defined once in `ReventlessInfra.DcbEventLog` (mirrors `EventLog.appendError`) and
threaded through the core adapter, all four backends (in-memory, SQLite, Postgres,
DynamoDB), and the `StateChangeSlice_Callback` retry consumer. This also fixed a
latent bug: the consumer classified conflicts via `String.startsWith("Conflict")`
(capital) while local/pg backends emitted lowercase `"conflict"`, so real
conflicts were **misclassified in metrics** — now a typed `switch`. All tests
migrated. Validated: core DCB 160/160, local 476/476, postgres 8/8, AWS runtime
45/45 (AWS integration compiles; needs a live DynamoDB to run).

**Remaining:**

- **Future (out of this plan):** async LocalBus QueryDb registrations → live
  Postgres-backed read-model *tables* in the local platform (tiers #2/#3 from the
  scope discussion). Not needed for correctness — startup replay already rebuilds
  read models from the durable log; this would only add externally-inspectable
  read-model tables + persisted incremental checkpoints.

---

**Status**: Draft (2026-07-03)
**Nature**: feature plan. One new package `reventless/reventless-postgres`
(`@reventlessdev/reventless-postgres`, Apache-2.0), a new backend option in
`reventless-local`, and parity/concurrency test coverage. No adapter-interface
changes required; one optional hardening (F4) touches
`DcbEventLog_Adapter.res`.
**Prior art in this repo**: `docs/analysis/dcb-dynamodb-consistency-check.md`,
`docs/analysis/dcb-high-contention-handling.md` (§7 already anticipated: "the
hard requirement for any backend is an atomic conditional append — Postgres
satisfies this natively"), backlog items `dcb-hot-tag-fence-contention`,
`dcb-monotonic-position-generation`.

## Motivation

Both event-log flavors (classic OCC and DCB) currently have three backends:
DynamoDB (production), in-memory and SQLite (local). A Postgres backend adds
the missing fourth column and is worth having in its own right:

1. **Exact DCB semantics.** DynamoDB *emulates* the append condition with
   per-(tag, event-type) fence sentinel rows (it cannot evaluate a predicate
   across rows inside a write). Postgres evaluates the *actual*
   `DcbTag.query` atomically — eliminating fence write amplification
   (TransactWriteItems ≈ 4× WCU per simple append), the ~500 tx/s hot-tag
   ceiling, and the false-conflict class from fence granularity. Most of the
   `dcb-high-contention-handling.md` mitigation taxonomy becomes unnecessary
   on this backend.
2. **Monotonic positions by construction** — `(xid8, bigint)` cursors resolve
   the `dcb-monotonic-position-generation` backlog item for this backend
   (DynamoDB positions are `timestamp-uuid`, not monotonic).
3. **A storage layer usable by any compute layer.** The adapter needs only a
   connection string — RDS/Aurora, any managed EU provider, an in-cluster
   operator, or a laptop container. It removes the hard AWS dependency from
   the write path and gives third-party backends a reference storage
   implementation with owned semantics.
4. **A durable local platform.** `reventless-local` gains
   `Backend.Postgres(...)` alongside `Memory`/`Sqlite` — same functor/config
   mechanism, real persistence, and the same storage semantics as any
   Postgres production deployment.

The SQLite backend is the porting template for schema shape, query
compilation, and adapter plumbing (`DcbEventLogStorage_Sqlite.res` already
implements true DCB semantics on SQL) — but **not** for concurrency: SQLite
has a single writer, so its check-then-insert is race-free by accident.
Postgres has concurrent writers; the append design below is the part that
must be engineered, not copied.

---

## Phasing

| Phase | Item | Package | Class |
|---|---|---|---|
| A1 | `PgDriver` binding (`pg`, style of `SqliteDriver.resi`) | reventless-postgres | Plumbing |
| A2 | Schema + idempotent migration runner | reventless-postgres | Plumbing |
| A3 | Classic `EventLogStorage_Postgres{,_Runtime}` | reventless-postgres | Feature |
| B1 | `dcb_append` PL/pgSQL: scoped advisory locks + exact check + insert | reventless-postgres | Feature (core of the plan) |
| B2 | Cursor encoding `"<xid8>:<position>"` + xmin-fenced reads | reventless-postgres | Feature |
| B3 | `readStream` keyset pagination | reventless-postgres | Feature |
| B4 | Lock-strategy option `#AdvisoryLocks` / `#RowLocks` | reventless-postgres | Hardening |
| C1 | `QueryDbStorage_Postgres{,_Runtime}` (JSONB documents) | reventless-postgres | Feature |
| C2 | `QueryEngine_Postgres` (query-AST → SQL) | reventless-postgres | Feature |
| D1 | Change feed: checkpointed poll + NOTIFY wakeup | reventless-postgres | Feature |
| D2 | Feed-consumer API as a documented public surface | reventless-postgres | Contract |
| E1 | `Backend.Postgres` variant + `BackendState.setPostgres` | reventless-local | Integration |
| E2 | Dispatch wiring in local storage makers + docs | reventless-local | Integration |
| F1 | `runUnderPostgres` in `BackendParityTest` + sibling parity suites | reventless-local | Test |
| F2 | DCB concurrency suite (genuinely concurrent writers — new) | reventless-postgres | Test |
| F3 | CI job with Postgres service container | repo CI | Test |
| F4 | Typed DCB `appendError` upstream (optional, recommended) | reventless-core | Hardening |

Order: A → B → (C ∥ D) → E → F1–F3 continuously from B on. F4 anytime.

---

## Phase A — Package, driver, schema, classic log

### A1 — `PgDriver` binding

Thin externals over `pg` (node-postgres) with a `.resi`, mirroring
`reventless-local/src/adapter/SqliteDriver.res(i)`: connect/pool, query with
parameters, transaction helper, `LISTEN` subscription handle. No ORM, no
query builder — the adapter compiles its own SQL.

### A2 — Schema + migrations

DCB log table (per log name; classic log table is separate and trivial):

```sql
CREATE TABLE dcb_event (
  log_name        text        NOT NULL,
  position        bigint      GENERATED ALWAYS AS IDENTITY,
  transaction_id  xid8        NOT NULL DEFAULT pg_current_xact_id(),
  event_type      text        NOT NULL,
  tags            text[]      NOT NULL DEFAULT '{}',   -- 'key=value', sorted
  data            jsonb       NOT NULL,
  meta            jsonb       NOT NULL,
  recorded_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (log_name, position)
);
CREATE INDEX dcb_event_tags_gin  ON dcb_event USING gin (tags);
CREATE INDEX dcb_event_type_pos  ON dcb_event (log_name, event_type, position);
CREATE INDEX dcb_event_tx_pos    ON dcb_event (log_name, transaction_id, position);
```

- `tags text[]` + GIN `@>` containment implements `queryItem` semantics
  ("carries ALL these tags") in one operator, for arbitrary tag combinations —
  no precomputed composite indexes, no per-tag index zoo.
- `~partitionTag` / `~crossPartitionTagKeys` / `~indexes` /
  `~strongConsistency` are no-ops, exactly as in the SQLite backend: in a
  relational store all tags are equal citizens.
- Migration runner: idempotent `ensureSchema(connection)` callable from any
  deploy-time context or standalone; the package does not depend on any
  IaC/provider SDK. Deploy-time resource emission (an `Adapter.resource` with
  `service = "postgres:Table"`) is left to the platform package that embeds
  this storage.

### A3 — Classic event log

`event_log(log_name, aggregate_id, seq_nr bigint, payload jsonb, PRIMARY KEY
(log_name, aggregate_id, seq_nr))` — OCC by primary-key violation mapped to
the typed `Conflict`, a direct port of `EventLogStorage_Sqlite`. Validates
driver, migrations, and plumbing before the hard part.

---

## Phase B — DCB append and reads

Design summary (full survey of seven external DCB-on-Postgres implementations
and the three known consistency strategies behind this choice: see Sources).

### B1 — Append: scoped advisory locks + exact check + insert

One PL/pgSQL function `dcb_append(events jsonb, condition jsonb)`, one
network round trip, transaction-scoped:

1. **Lock scopes.** 64-bit hashes (FNV-1a, namespaced per `log_name`) of
   every tag value in condition-query ∪ written-events tags;
   `SELECT pg_advisory_xact_lock(k) FROM unnest($keys) k ORDER BY k`
   (sorted acquisition — deadlock-free; disjoint boundaries fully parallel).
2. **Exact condition check** — compile `DcbTag.query` to SQL as the SQLite
   backend does, against the array column
   (`event_type = ANY($types) AND tags @> $tags`, OR across query items),
   with the two-column `after` comparison from B2. Under the held locks at
   READ COMMITTED this is race-free: a concurrent conflicting writer is
   either committed (visible) or blocked on our lock. Match → conflict error.
3. **Insert** all events via `INSERT … SELECT … FROM unnest(...)`,
   `RETURNING position`.
4. **`pg_notify('dcb_' || log_name, last_position)`** for D1 wakeup.

Why not the two alternatives:

- *Single-statement `INSERT…WHERE NOT EXISTS` under SERIALIZABLE*: equally
  correct, but contention degrades to abort/retry storms (SSI predicate
  locks are page-granular → false-positive aborts) and every reader pays SSI
  bookkeeping. Note the same statement at READ COMMITTED **without locks is
  wrong** — the check cannot see concurrent uncommitted inserts (a published
  implementation ships this write-skew window; our F2 suite must include the
  exact scenario).
- *Version side-table with row locks*: structurally the DynamoDB fence
  translated to SQL — same per-tag granularity, same false-conflict class.
  Dominated; the whole point of Postgres is evaluating the real query.

Key structural win to preserve in the implementation: lock scope controls
only *what serializes*; the *check* is exact — coarse lock scoping can delay
an append, never wrongly reject it.

`appendUnconditional` (seed/import/replay): same function, null condition,
steps 1–2 skipped. No auxiliary rows to maintain.

### B2 — Cursor encoding + reader visibility

The hard problem in a Postgres event store is reader-side visibility, not
the append: `bigint` positions are allocated at INSERT but visible at
COMMIT, so a naive `WHERE position > $checkpoint` poller can permanently
skip an event committed late. Industry-consensus fix, adopted here:

- Stamp rows with `transaction_id = pg_current_xact_id()` (`xid8`,
  epoch-safe).
- All reads apply
  `transaction_id < pg_snapshot_xmin(pg_current_snapshot())
  ORDER BY transaction_id, position` — readers only see rows no in-flight
  transaction can precede; a returned head position is stable forever.
- `sequencePosition` is already an opaque string owned by the adapter:
  encode zero-padded `"<xid8>:<position>"` (string sort = numeric sort).
  Spec-compliant monotonic positions with zero interface changes;
  `~strongConsistency` becomes a genuine no-op (every read is safely
  consistent, at the cost of a few ms visibility lag).
- The append condition's `after` decodes to the same two-column comparison,
  making read → decide → conditional-append exact end to end.

### B3 — `readStream`

Keyset pagination on `(transaction_id, position)` + `LIMIT`, wrapped in the
existing `Stream.paginateEffect` pattern. One ordered SQL source — the
DynamoDB runtime's per-clause fan-out, k-way merge, and dedup layers have no
Postgres counterpart; don't port them.

### B4 — Lock-strategy option

Transaction-scoped advisory locks are safe under PgBouncer transaction mode
(lock+check+insert live in one transaction inside the function) but cause
connection pinning on RDS Proxy. Ship the strategy as a storage option:
`#AdvisoryLocks` (default) and `#RowLocks` (`SELECT … FOR UPDATE` on a
`dcb_scope(log_name, scope_hash)` companion table — same algorithm, row
locks). Cheap insurance; both paths run through F2.

---

## Phase C — QueryDb + query engine

- **C1** `QueryDbStorage_Postgres{,_Runtime}`: JSONB document tables +
  expression indexes; same maker surface as
  `QueryDbStorage_Sqlite`/`_DynamoDb`. The no-stream aliasing trick the local
  platform uses (stream flavor → same maker) applies until D1 consumers need
  more.
- **C2** `QueryEngine_Postgres`: compile the existing query AST to SQL —
  `LocalQueryEngine` (which already targets the SQLite dialect) is the
  porting template, as it was for the event log. List-pushdown behavior must
  match (`QueryDbListPushdownParityTest` extends to Postgres in F1).

---

## Phase D — Change feed

The one component with no template in this repo (DynamoDB Streams has no
drop-in equivalent). **Checkpointed polling with NOTIFY wakeup**, not logical
decoding:

- **D1** A feed reader over the xmin-fenced query from B2 with a
  `dcb_subscription(subscriber, last_tx xid8, last_position bigint)`
  checkpoint table; `LISTEN dcb_<log>` turns polling into near-real-time
  wakeup with a low-frequency fallback tick. No skips regardless of commit
  ordering; a late subscriber replays from any historical cursor directly
  against the log (no retention window, no shard iterators).
- **D2** **The feed-consumer API is a documented public surface of the
  package** — cursor semantics (`(xid8, position)` pair, opaque encoding),
  batch read, checkpoint contract. External relays and platform packages
  (any compute layer bridging the feed onto a bus/topic transport) are
  first-class consumers; the in-repo reference consumer is the F1 parity
  wiring. Design it as an API, not an internal helper.
- Logical decoding (`pgoutput`/wal2json) is deferred deliberately:
  replication-slot lifecycle, WAL-retention risk on consumer outage, and
  pooler incompatibilities buy fidelity this design doesn't need — events
  are already durably queryable in-table. Revisit only if sub-10 ms fan-out
  becomes a requirement.

---

## Phase E — Local platform integration

Postgres becomes a first-class, user-facing backend of `reventless-local`,
selectable exactly like SQLite (alongside, not replacing — `Memory`/`Sqlite`
remain the zero-dependency instant dev loop):

- **E1** `Backend.t` gains `Postgres({connection: string, resetOnStart: bool})`
  (`src/adapter/Backend.res`); `BackendState.setPostgres(~pool, ...)`
  mirroring `setSqlite`; `MakeWithConfig`'s `backend` config accepts it.
- **E2** The dispatching storage makers
  (`EventLogStorage_InMemory.Make` et al., which already dispatch to SQLite
  via `BackendState`) gain the Postgres arm, delegating to the
  `reventless-postgres` runtime modules. `reventless-local` takes a
  workspace dependency on `@reventlessdev/reventless-postgres`.
  Task-bucket storage (`TaskBucket_Sqlite` pattern) follows the same split
  if in scope; if not, document `Backend.Postgres` as covering
  event-log/query-db storage with tasks remaining file/SQLite-backed (call
  it out explicitly rather than silently).
- Docs: backend selection guide entry + the operational note that
  `resetOnStart` truncates, never drops, the schema.

Value: durable local/single-node deployments, and development against the
identical storage semantics of any Postgres production target.

---

## Phase F — Tests and CI

- **F1** `BackendParityTest` gains `runUnderPostgres(fn)` alongside
  `runUnderMemory`/`runUnderSqlite` (connect, reset schema, run, teardown);
  every existing scenario runs under all three. Same for
  `QueryDbListPushdownParityTest` and `EventLogSnapshotParityTest`. This is
  the correctness gate: the GWT suites that validate SQLite must pass
  unchanged against Postgres.
- **F2** New concurrency suite, Postgres-only (nothing else has concurrent
  writers): two-writer write-skew scenario (overlapping condition queries —
  the exact anomaly the advisory locks close), commit-out-of-allocation-order
  visibility (late-committing lower position must not be skipped by a
  checkpointing reader), hot-tag queueing behavior (N writers, one boundary:
  all succeed or conflict cleanly, no lost updates), both `#AdvisoryLocks`
  and `#RowLocks`.
- **F3** CI: Postgres service container job (F1/F2 + package unit tests).
  Local runs via testcontainers or `docker run`; keep the suite skippable
  when no Postgres is reachable so the default `pnpm test` stays
  dependency-free.
- **F4** (optional, recommended) Typed DCB `appendError` in
  `DcbEventLog_Adapter.res`: the classic log has `Conflict |
  StorageFailure(string)`; the DCB adapter still signals conflicts by
  substring convention (`Error("Conflict: …")`). A second production backend
  doubles down on that fragility — type it now, migrate both backends.
  Small, breaking only for code that pattern-matches the string.

Related, separate plan: extracting the parity suites into a publishable
conformance kit so out-of-repo backends can run the identical behavioral
contract. This plan only extends the in-repo suites; it should avoid
structuring F1/F2 in ways that would resist that extraction (keep scenarios
parameterized over the storage makers, not over `BackendState` details).

## Non-goals (v1)

- Tagless append conditions (keep the DynamoDB-parity rejection; relaxable
  later — Postgres could support a global advisory scope).
- Logical-decoding change feed (see D).
- Multi-node write scaling (Citus et al.).
- Provider-specific provisioning components (RDS/Aurora/operator resources)
  — platform packages wrap `ensureSchema` + connection config themselves.
- Performance claims: before publishing any numbers vs. DynamoDB, run the
  GWT-derived load scenarios against both (hot-tag contention, wide-OR
  decision-model reads, cold replay). External published figures span three
  orders of magnitude; measure, don't quote.

## Risks / open questions

- **Pooling × locking** interact (B4): decide the documented default
  deployment shape (few long-lived connections vs. pooled) — shipping both
  strategies is the hedge, but the docs must steer.
- **`xid8` cursors don't survive logical dump/restore** (txids reset;
  `pg_upgrade` is fine). A log export/import path must renumber cursors —
  same concern class as existing replay tooling; note it in the cursor docs.
- **GIN update amplification** under sustained ingest: benchmark with
  `gin_pending_list_limit` tuning; dropping the GIN is a migration-free
  `DROP INDEX` if a write-heavy profile ever demands it.
- **DCB spec conformance vectors**: dcb.events is converging on shared test
  vectors; passing them would be a credible public artifact
  ("spec-conformant DCB store on Postgres"). Track and adopt when stable.

## Sources

- DCB spec + implementations: https://dcb.events/specification/ ·
  https://dcb.events/resources/libraries/
- SERIALIZABLE single-statement append:
  https://github.com/bwaidelich/dcb-eventstore-doctrine
- Advisory-lock scopes + read barrier (READ COMMITTED):
  https://github.com/kraken-tech/dcb-event-store
- `xid8` cursor + PL/pgSQL conditional append:
  https://github.com/rodolfodpk/go-crablet
- xid8 + xmin fence schema (NB: its unlocked check has a write-skew window):
  https://github.com/sliceworkz/eventstore
- Ordering/visibility (`xid8` pattern origin):
  https://event-driven.io/en/ordering_in_postgres_outbox/
- Marten DCB (version side-table = fence-on-SQL, for contrast):
  https://martendb.io/events/dcb.html
- Advisory lock per stream: https://github.com/message-db/message-db
