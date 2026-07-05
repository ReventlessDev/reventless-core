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

## Phasing

- **B3.1 — storage + engine vertical (no GraphQL reads).**
  `QueryDbBackend` registry (clone of `EventLogBackend`), AWS
  `QueryDbStorage_Postgres` deploy-time maker (`resources: []`, ops via pool;
  `ensureSchema`-style table creation folded into A3's migration step),
  `QueryDbStorage_Postgres_Runtime.opsFor`, Postgres branch +
  `pgConnection`/VPC/IAM in the ReadModel/EventCollector runtime builders,
  `QueryEnginePostgres` bound behind `queryEngineMaker` for tasks/extensions.
  Deliverable: projections persist to Postgres; QueryEngine consumers read it;
  AppSync reads still unavailable for Postgres-backed read models.
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
