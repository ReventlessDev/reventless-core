# Plan: Postgres QueryDb + read path on AWS (B3 of the RDS adapter plan)

**Status**: Scoped (2026-07-05) — implementation not started
**Parent plan**: `docs/plans/aws-postgres-rds-adapter.md` (Phase B3)

Scoping result for the "largest B-phase unknown": what it takes to run read
models (QueryDb + QueryEngine + the AppSync read path) on RDS/Aurora Postgres.
Codebase reconnaissance 2026-07-05, after the DCB (B2) and classic (B1)
EventLog verticals landed.

## What already exists (no new storage semantics needed)

The storage layer is **done and live-validated** in `reventless-postgres`:

- `QueryDbStorage_Postgres.res` — all 7 adapter ops (`load`, `loadStream`,
  `save`, `saveBatch`, `count`, `delete`, `deleteBatch`) over JSONB tables
  `qdb_<name>(partition_key, sub_key, item jsonb, expires_at)`, PK
  `(partition_key, sub_key)`, per-`indexConfig` expression indexes on
  `(item->>'field')`, lazy TTL expiry — a faithful port of the SQLite backend
  (same pattern that carried EventLog).
- `QueryEnginePostgres.res` — the QueryEngine filter AST (`Equal`, `Less`,
  `Contains`, `BeginsWith`, `Exists`, …) compiled to parameterized SQL;
  `query` (partition + subId + filters) and `scan` (filters + limit).

What's missing is **AWS glue and the AppSync read path** — the same shape of
gap B1/B2 had, plus one genuinely new problem: DynamoDB read models are served
by *direct AppSync→DynamoDB resolvers*; Postgres has no per-table AppSync data
source, so GraphQL reads must route through a Lambda.

## DynamoDB surface inventory (what a Postgres path must cover)

| Surface | DynamoDB module | Postgres story |
|---|---|---|
| Deploy-time storage | `QueryDbStorage_DynamoDb(Stream)` — table + GSIs + AppSync DataSource | `resources: []`, ops from pg pool (B1/B2 pattern) |
| Projection writes | `QueryDbStorage_DynamoDb_Runtime` bound in ReadModel/EventCollector Lambdas via `HANDLER_CONFIG.queryDbTableName` | `QueryDbStorage_Postgres_Runtime.opsFor(config, ~name)` + entry-point branch + VPC/IAM (mirror `EventLogStorage_Postgres_Runtime`) |
| Internal reads | `QueryEngine_DynamoDb` (tasks, extensions, admin) | bind `QueryEnginePostgres` behind the same `queryEngineMaker` seam |
| GraphQL reads | `QueryDbResolvers_AppSync` — unit + pipeline resolvers (getById, queryByIndex[Sort]Filtered, listAll[Connection], `@resolves`/`@resolvesMany`, auth-table pipeline), `NodeResolver_AppSync` | **the B3.2 work** — Lambda data source, see below |
| Live updates | `QueryDbStorage_DynamoDbStream` → StateTopic → AppSync Events | deferred (B3.3) — no stream on Postgres |

Key contract detail: `QueryDb_Adapter.storageMaker` returns
`{resources, dataSourceName: Pulumi.Output.t<string>, operations}` — the
`dataSourceName` is the AppSync coupling. A Postgres storage can return the
name of the **shared Lambda data source** (below), which slots into the
existing resolver plumbing without changing the adapter contract.

## The read-path decision

Two viable designs; **Option A recommended**.

**Option A — shared Lambda resolver (recommended).** One in-VPC
"PgQueryResolver" Lambda registered once as an AppSync Lambda data source.
Every Postgres read model's resolvers become thin APPSYNC_JS `Invoke`
templates carrying `{readModelName, kind, args, identity}`; the Lambda
dispatches to `QueryEnginePostgres` + purpose-built SQL for the resolver kinds.
Pros: one data source, all query logic in ReScript (testable without AppSync),
reuses `PgRuntime.poolFor` + the C1 VPC/IAM pattern, precedent exists
(`QueryInterceptorConfig` already builds AppSync→Lambda pipeline functions).
Cons: extra hop latency vs. direct resolvers; Lambda concurrency = DB
connections (C2/RDS Proxy applies).

**Option B — AppSync RDS (Data API) data source.** AppSync natively supports
Aurora relational data sources via the RDS Data API; resolvers embed SQL
directly. Pros: no Lambda hop, no VPC for the read path. Cons: **Aurora
Serverless with Data API only** (rules out plain RDS instances the parent plan
targets), SQL scattered across mapping templates instead of testable ReScript,
separate auth/limits regime. Keep as a documented alternative, not the default.

## ⚠️ B3.1 prerequisite discovered (2026-07-05): projection delivery

Deep-dive before implementation surfaced a structural gap that predates B3 and
re-orders it:

- ReadModel and StateViewSlice EventCollectors consume their source event logs
  via **DynamoDB-stream ESMs** (`EventCollectorChannel.DynamoDbStream`;
  `ReadModelEntryPoint.mjs` keys handlers by `sourceUrn` = stream ARN;
  `StateViewSliceRuntime_Builder_Single` same channel).
- On a Postgres-backed platform (B1/B2 as landed), event-log storage
  `resources` are empty → **no ESM is created → the ReadModel/StateViewSlice
  Lambdas are never invoked**. The change-feed relay feeds only the *plugin*
  EventCollector SQS queue, whose Lambda drives EP/extension routing, the
  cross-plugin SNS topic, and aggregate command topics — it does **not** run
  within-plugin RM/SVS projections.
- Net: before any B3 storage work, a Postgres platform has no working
  within-plugin projection path. This is a latent B1/B2 gap that would surface
  on the first live deploy — B2.4's explicitly-untested "EventCollector
  fan-out" boundary is exactly this.
- Additional hazard: `EventCollectorChannel_DynamoDbStream.make` does
  `outputs.resources->Array.getUnsafe(0)` (marked FIXME) per subscribed event
  topic — empty resources on Postgres produce `undefined` entries at deploy
  time; whether that crashes `connectLambda` or silently skips is unverified.

**Design options for Postgres projection delivery:**

- **(A) Per-consumer SQS queues (recommended).** On Postgres platforms each
  RM/SVS EventCollector gets an SQS channel; the relay fans each log out to
  every subscribed consumer queue, one `(log, consumer)` subscriber checkpoint
  each (the relay builder already supports N entries per log after the per-log
  subscriber fix). `ReadModelEntryPoint` handles SQS records (the
  `handleDynamoDbOrSqsEvent` helper exists) keyed by queue ARN. Preserves the
  DynamoDB path's per-consumer isolation, retries, and DLQ options.
- **(B) In-process fan-out in the plugin EC Lambda.** Run RM/SVS projections
  inside the plugin EventCollector, service-keyed. Fewer queues but couples
  projection failure/latency to the EC Lambda and loses per-RM isolation —
  diverges from the DynamoDB path's semantics. Not recommended.

**Revised B3.1** therefore leads with projection delivery (A), then the
storage/runtime swap below. One more implementation note discovered:
`QueryDbStorage_Postgres.makeStorage` (reventless-postgres) starts its
`ensureTable` promise **eagerly** — called at deploy time it would attempt a DB
connection from outside the VPC; make `ready` lazy (first-operation) before
binding it in a deploy-time maker.

## Phasing

- **B3.0 — projection delivery on Postgres platforms** — ✅ **landed
  (2026-07-05)**, design (A) as scoped, with one simplification: instead of an
  SQS channel per RM/SVS EventCollector, there is **one feed queue per
  consumer Lambda** (`AllReadModelsFeed`, `AllStateViewSlicesFeed`) and the
  relay fans every Postgres log into it; per-projection filtering
  (`meta.service` / event-type matching in the callbacks) makes over-delivery
  a no-op — the same property that lets several read models share one DynamoDB
  stream. Pieces:
  - `PgProjectionFeed` (adapter/Postgres/) — feed-queue registry + `makeQueue`
    (DLQ-backed SQS) + `connect` (ESM + receive IAM on the consumer Lambda).
  - `EventCollectorRuntime_Builder_Single` / `StateViewSliceRuntime_Builder_Single`
    — provision + connect the feed queue when a Postgres backend is active;
    handler `sourceUrn` falls back to the feed queue ARN when the source has no
    stream resource (also de-fuses the `getUnsafe(0)` deploy crashes in
    `finishWithDcbEventLog` and the HANDLER_CONFIG serializers).
  - `EventCollectorChannel_DynamoDbStream_Runtime.handleStreamEvent` — now
    decodes `aws:sqs` records (relay-injected `{id, meta, event}` bodies)
    alongside `aws:dynamodb`, per record, so mixed backends work; unit-tested
    (`EventCollectorChannelStreamRuntimeTest`).
  - `EventCollectorChannel_DynamoDbStream.make` — the `getUnsafe(0)` FIXME is
    now a `filterMap`, skipping stream-less (Postgres) event topics.
  - `Platform.provisionPgChangeFeedRelay` — each log now targets the plugin
    EventCollector queue **plus** every matching feed queue (classic → RM feed;
    DCB → RM + SVS feeds), one `<scope>:<logName>` subscriber per pair; a log
    without a collector queue still feeds projections.
  Still unvalidated live (same boundary as B2.4): actual SQS delivery + ESM
  behavior on a deployed stack.
- **B3.1 — storage vertical (no GraphQL reads)** — ✅ **landed (2026-07-05)**
  for the write path; the QueryEngine half moved to B3.1b:
  - `QueryDbBackend` (adapter/QueryDb/) — selection + **admin exemption list**:
    admin read models (Plugins, UIFragmentRegistry) stay on DynamoDB because
    deploy-time consumers (schema-clobber guard's Plugin-RM scan,
    `PLUGIN_RM_TABLE_NAME` gates, retire hooks) query them during `pulumi up`
    from outside the VPC. Registered by `Platform.MakeWithConfig` alongside the
    other two backend selections.
  - AWS `QueryDbStorage_Postgres` maker (`resources: []`, `dataSourceName ""`,
    ops via `QueryDbStorage_Postgres_Runtime.opsFor` → shared pool) +
    `QueryDbStorage.Selectable/SelectableStream` + `QueryDbResolvers.Selectable`
    (Postgres RMs get NoOp resolvers until B3.2 — their GraphQL fields are
    unresolved). reventless-postgres `makeStorage` was split into a plain-ops
    `makeOperations` with **lazy** schema setup (first operation, not
    construction — deploy machines can't reach the VPC-private DB).
  - Builders swapped to the selectors (ReadModel_Single(_Stream),
    NoResolver_Stream, StateViewSlice(_Stream)); on Postgres the spec name is
    registered as the stable `qdb_<name>` discriminator. PerReadModel /
    NoResolver (non-stream) / Counter / ForeignReadModel stay DynamoDB-only.
  - Runtime builders emit per-RM `pgConnection` into HANDLER_CONFIG (per read
    model — admin-exempt RMs share the Lambda with pg-backed ones), SVS gets a
    shared top-level `pgConnection` in the compressed config; both Lambdas go
    in-VPC with `GetSecretValue` when any handler is pg-backed. Entry points
    (`ReadModelEntryPoint` / `StateViewSliceEntryPoint`) bind the Postgres op
    set when `pgConnection` is present (indexes/subIdField read from the
    dynamically-imported spec module); absent → DynamoDB path byte-identical.
  - Validated: full monorepo build zero warnings, 1758 tests green.
- **B3.1b — QueryEngine on Postgres (open).** Runtime QueryEngine consumers
  (extensions in the plugin EC Lambda, tasks) rebuild DynamoDB query/scan from
  table names in HANDLER_CONFIG — they cannot read Postgres-backed read models
  yet. Needs `QueryEnginePostgres` bound in those runtimes (entry-point branch
  + VPC on task/EC Lambdas) and a `queryEngineMaker` selector for the
  deploy-time engine (admin scan stays DynamoDB thanks to the exemption).
  Scope alongside or into B3.2 — both put query logic behind the same seams.
- **B3.2 — AppSync read path (the big one).** `PgQueryResolverEntryPoint.mjs`
  + shared Lambda data source + `QueryDbResolvers_Lambda` (parallel to
  `QueryDbResolvers_AppSync`, emitting Invoke templates). Resolver-kind → SQL
  mapping: getById → `SELECT … WHERE partition_key=$1`; queryByIndex(Sort,
  Filtered) → expression-index `WHERE` + filters + `LIMIT`; listAll/Relay
  connection → **keyset pagination** on `(partition_key, sub_key)` (cursor =
  last key, not OFFSET); `@resolvesMany` BatchGet → `WHERE partition_key = ANY($1)`;
  node resolver → same dispatch keyed by type name; auth-table pipeline →
  Lambda-side lookup (auth tables themselves stay DynamoDB in the first cut —
  they're admin-managed and tiny; porting them is a follow-up).
- **B3.3 — live updates (deferred).** StateTopic assumes a DynamoDB stream
  ARN. Postgres options: (a) publish from the projection Lambda after
  `save` (simplest — the writer knows what changed), or (b) qdb triggers +
  NOTIFY + the relay pattern (B2 infrastructure). Decide when the live-update
  contract (docs/guides/appsync-events-live-updates.md) is actually needed on
  a Postgres platform; not a blocker for B3.1/2.

Order: B3.1 is mechanical (one day-scale, follows B1 file-for-file). B3.2 is
the real project — resolver-kind coverage should be driven by what the AutoUI
actually issues (getById, index list, connection pagination) before the long
tail (`@resolves*`, node, auth).

## Risks / open questions

- **Feature parity pressure in B3.2**: the DynamoDB resolver surface is wide
  (sort variants, INCLUDE projections, scanSort, interceptor stash contract).
  Mitigate by scoping to AutoUI-issued queries first and failing loudly on
  unmapped kinds.
- **Relay cursors**: DynamoDB `nextToken` is opaque server-side; Postgres
  keyset cursors are framework-issued — make them opaque (base64 of last key)
  so clients can't depend on shape.
- **Connection pressure**: AppSync can fan out reads far harder than command
  Lambdas — B3.2 makes C2 (RDS Proxy / pooling knob) load-bearing, not
  optional hardening.
- **Mixed platforms**: a Postgres QueryDb with DynamoDB EventLogs (or vice
  versa) is allowed by the registry design but untested — declare supported
  combinations in D1.

## Sources

- Storage/engine (done): `reventless/reventless-postgres/src/QueryDbStorage_Postgres.res`,
  `QueryEnginePostgres.res`; SQLite precedent `reventless/reventless-local/src/adapter/QueryDb/QueryDbStorage_Sqlite.res`.
- Adapter contract: `reventless/reventless-core/src/components/QueryDb/QueryDb_Adapter.res`
  (`storageMaker` with `dataSourceName`; `queryEngineMaker`).
- DynamoDB read path: `reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res`,
  `NodeResolver_AppSync.res`, `rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res`.
- Runtime writes: `reventless/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res`,
  `QueryEngine_DynamoDb.res`.
- B1/B2 wiring precedent: `EventLogBackend.res`, `DcbBackend.res`,
  `PgChangeFeedRelay_*` (this repo, landed 2026-07-05).
