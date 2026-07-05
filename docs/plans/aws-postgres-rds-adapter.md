# Plan: AWS-managed Postgres adapter (`reventless-aws` → RDS/Aurora)

**Status**: Backlog (2026-07-05)
**Nature**: feature plan. New deploy-time adapters in `reventless-aws` that
provision managed Postgres (RDS/Aurora) and route EventLog / DcbEventLog /
QueryDb Lambda operations to the existing `@reventlessdev/reventless-postgres`
runtime. No new storage semantics — the storage engine already exists and is
live-validated; this plan is **provisioning + connection wiring only**.
**Prior art in this repo**:
- `docs/plans/done/postgres-storage-adapter.md` — the storage engine
  (`reventless-postgres`), live-validated on Postgres 16 (8/8 concurrency,
  475/475 local). Its **v1 non-goal** was explicitly: *"Provider-specific
  provisioning components (RDS/Aurora/operator resources) — platform packages
  wrap `ensureSchema` + connection config themselves."* This plan is that
  deferred piece.
- `reventless/reventless-aws/src/adapter/EventLog/` (DynamoDB adapter shape),
  `.../DcbEventLog/`, `.../QueryDb/`, `.../QueryEngine/`.
- `docs/plans/Backlog/aws-deployment-strategy.md`,
  `docs/plans/Backlog/deploy-runtime-separation-plan.md`.

## Motivation

`reventless-postgres` is a complete, connection-string-only storage backend for
all three surfaces (classic EventLog, DcbEventLog + change feed, QueryDb), and
is already integrated into `reventless-local` as `Backend.postgres`. But the
**AWS deploy path has no Postgres story**: every adapter under
`reventless/reventless-aws/src/adapter/{EventLog,DcbEventLog,QueryDb,QueryEngine}/`
is DynamoDB-only. To run a real Pulumi-deployed, Lambda-backed platform on
managed Postgres today, a developer must hand-provision RDS and hand-wire the
runtime modules — none of it is exposed through the framework's adapter
selection.

Why it's worth doing:

1. **Exact DCB semantics in production.** DynamoDB *emulates* the DCB append
   condition with per-(tag, event-type) fence sentinel rows; Postgres evaluates
   the real `DcbTag.query` atomically (see the done plan's §Motivation). Today
   that exactness is only reachable locally.
2. **Monotonic positions by construction** (`(xid8, bigint)` cursors) — resolves
   `dcb-monotonic-position-generation` for AWS deployments too, not just local.
3. **A second production backend.** Removes the hard DynamoDB dependency from the
   write/read path for teams that prefer a relational store or an EU-managed
   Postgres, while staying on the same Pulumi/Lambda deploy machinery.

## The seam (what already exists to plug into)

Each AWS storage adapter is a `storageMaker` returning
`{resources: array<Pulumi resource>, operations: {…runtime ops…}}`
(`reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb.res`).
The **operations** half already exists for Postgres — the runtime modules in
`reventless-postgres` (`EventLogStorage_Postgres`, `DcbEventLogStorage_Postgres`,
`QueryDbStorage_Postgres`, `QueryEnginePostgres`) implement the same operation
shapes. **This plan builds the missing `resources` half** (RDS/Aurora + schema +
secret) and the glue that hands a resolved connection to the runtime inside the
Lambda.

Adapter interfaces to satisfy (unchanged):
- `ReventlessCore.EventLog_Adapter.storageMaker`
- `ReventlessInfra.DcbEventLog` adapter (typed `appendError` already landed — F4)
- `ReventlessCore` QueryDb + QueryEngine adapter shapes

---

## Exploration findings (2026-07-05 — codebase reconnaissance before starting)

Three parallel seam surveys confirmed the shape and turned up three facts that
reshape the phasing:

1. **The operations half already returns the adapter shape, but the AWS makers
   are still new thin files.** The `reventless-postgres` runtime modules
   (`EventLogStorage_Postgres`, `DcbEventLogStorage_Postgres`,
   `QueryDbStorage_Postgres`, `QueryEnginePostgres`) implement the exact op
   signatures the AWS adapters need. But their makers take `~pool: PgDriver.pool`
   *at call time*, whereas the AWS `storageMaker` is
   `(~name, ~opts) => {resources, operations: Pulumi.Output.t<operations>}` — the
   ops live inside a `Pulumi.Output.apply` closure that Pulumi serializes and runs
   *in the Lambda*. So each AWS Postgres adapter is a **new file** that resolves
   `{host, port, db, secretArn}` at deploy time and, at cold start, fetches the
   secret → `PgDriver.makePool(connectionString)` (memoized per container) → binds
   the existing pg ops. **This is the central glue** and it is what distinguishes
   the AWS path from the local path (`reventless-local` hands the pool in directly).

2. **`rescript-pulumi-aws` has no RDS bindings and no create-side Secret** — and
   the standard `Lambda.Function` binding has **no `vpcConfig` field** (only the
   legacy `CallbackFunction` does). Bindings are hand-written (no codegen). VPC /
   Subnet / SecurityGroup / Secrets-Manager-*read* bindings already exist. → A new
   **Pre-A binding phase** is required before any provisioning can compile.

3. **Backend selection is module-alias-based and currently hardcoded.** Each
   `<Surface>Storage.res` is `module DynamoDb = …`, and the AWS builders hardcode
   `EventLogStorage.DynamoDbStream` / `QueryDbStorage.DynamoDb` etc. A Postgres arm
   is a new `module Postgres = …Storage_Postgres` alias plus parallel builder
   modules; D1's per-surface knob is genuinely new (no existing selection point).
   Runtime env/IAM seams are clean: `RuntimeEnvironment_Lambda.makeFromCodeAsset`
   already exposes `additionalEnvVars` (dict) and `additionalIamPolicies` (array).

### Reference: exact seams

- AWS adapter shape (all four surfaces): `EventLog_Adapter.storageMaker =
  (~name, ~opts) => {resources: array<Adapter.resource>, operations:
  Pulumi.Output.t<operations>}`. DynamoDb template:
  `reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb.res`
  (`operations: table->toResolvedTableOutput->Pulumi.Output.apply(resolved => {…ops…})`).
  QueryDb additionally carries `dataSourceName: Pulumi.Output.t<string>` (AppSync);
  **Postgres has no direct AppSync data source → reads must route through a Lambda
  resolver** (`QueryInterceptor_Lambda` / `NodeResolver_AppSync`) — the largest B3
  unknown.
- pg runtime pool: `PgDriver.makePool({connectionString, max?}) => pool`;
  `PgSchema.ensureSchema(pool)` idempotent (all `IF NOT EXISTS`);
  DCB lock knob `type lockStrategy = [#AdvisoryLocks | #RowLocks]` on
  `DcbEventLogStorage_Postgres.makeStorage(~lockStrategy)`.
- change feed: `PgChangeFeed.{readBatch, loadCheckpoint, saveCheckpoint, listen,
  unlisten, drain}` (checkpointed LISTEN/NOTIFY; `dcb_subscription` table).
- Lambda seams: `RuntimeEnvironment_Lambda.makeFromCodeAsset` — inject env via
  `additionalEnvVars`, IAM via `additionalIamPolicies`; **no `vpcConfig` today**
  (zero-VPC deploy). `Util_Vpc.getVpcConfig` reads a VPC from a StackReference but
  targets `CallbackFunction` (Fargate-only use today).

---

## Phasing

| Phase | Item | Package | Class |
|---|---|---|---|
| **A0** | **Pre-A bindings**: `rescript-pulumi-aws` — `Rds.{Instance,Cluster,ClusterInstance,SubnetGroup,Proxy}`, `SecretsManager.{Secret,SecretVersion}`, and a `vpcConfig` field on `Lambda.Function`. Hand-authored, following the existing EC2/DynamoDb binding pattern. | rescript-pulumi-aws | Plumbing (blocker) |
| A1 | `reventless-aws` takes a workspace dep on `reventless-postgres` + `pg` Lambda-layer/bundling story | reventless-aws | Plumbing |
| A2 | `PgConnection` deploy-time component: RDS/Aurora resource + Secrets Manager secret + VPC/SG wiring, resolving to a connection-config `Output` | reventless-aws | Feature (core) |
| A3 | Schema provisioning at deploy time (`ensureSchema`) — Pulumi dynamic/command resource or a one-shot migration Lambda | reventless-aws | Feature |
| B1 | `EventLogStorage_Postgres` AWS adapter (`storageMaker`: resources = shared PgConnection ref; operations delegate to the pg runtime) | reventless-aws | Feature |
| B2 | `DcbEventLogStorage_Postgres` AWS adapter + change-feed → EventCollector/bus bridge | reventless-aws | Feature |
| B3 | `QueryDbStorage_Postgres` + `QueryEngine_Postgres` AWS adapters | reventless-aws | Feature |
| C1 | Lambda runtime env: inject connection secret ARN, resolve at cold start, IAM `secretsmanager:GetSecretValue`, VPC config + SG | reventless-aws | Feature (core) |
| C2 | Connection pooling decision: pinned `#AdvisoryLocks` on direct RDS vs. RDS Proxy + `#RowLocks` — expose as a config knob | reventless-aws | Hardening |
| D1 | Backend selection: how a platform opts a surface into Postgres vs. DynamoDB (per-surface, so mixed deployments are possible) | reventless-aws | Contract |
| D2 | Deploy-time resource `service`-tag / routing so command publishers target the right backend (cf. `meta.service` dispatch note) | reventless-aws | Contract |
| E1 | Example: a hybrid example (or new `examples/online-shop-postgres/`) deploying one plugin on RDS | examples | Integration |
| E2 | CI deploy smoke: provision → migrate → append → replay → teardown against a throwaway RDS (or LocalStack/pg where feasible) | repo CI | Test |
| F1 | Deployment guide: `docs/guides/postgres-aws-deployment.md` (pooling, VPC, secrets, cost, when-to-choose-vs-DynamoDB) | docs | Doc |

Order: **A0 → A** → B (∥ across surfaces) → C → D → E → F. A0 blocks A2 (nothing
provisions without RDS/Secret bindings). C1 gates any live test.

---

## Phase A — Package wiring & connection component

### A1 — Dependency + bundling ✅ (2026-07-05)
- **Done.** `reventless-aws` now depends on `@reventlessdev/reventless-postgres`
  (`workspace:*` in both `package.json` and `rescript.json`); `pg` arrives
  transitively (as it does for `reventless-local`). Verified: clean build, clean
  3-line lockfile change, no UI contamination.
- **`pg` Lambda delivery — decided: the existing layer, no bundling change.** The
  `reventless-layer-builder` walks the full production dependency tree and bundles
  everything except a fixed exclude list (`@pulumi/*`, `aws-sdk`, `smithy`,
  `opentelemetry`, `sury-ppx`, …). `pg` is pure-JS and not excluded, so it rides
  along automatically once `reventless-postgres` is a transitive dep — no layer or
  bundling edit required.

### A2 — `PgConnection` deploy-time component (the core) ✅ (2026-07-05, single-instance)
**Done for single RDS `Instance`** — `reventless-aws/src/adapter/Postgres/PgConnection.res`.
Compiles clean (zero warnings). Also required a small binding addition:
`EC2_SecurityGroup.Ingress` gained an optional `self` (and `securityGroups`)
field to express the self-referencing 5432 rule.
- **Networking is an input, not provisioned.** `make(~vpcId, ~subnetIds, …)` — the
  platform supplies an existing VPC + private subnets; `PgConnection` does not
  create a VPC (a full VPC is a platform concern, out of scope).
- **Self-referencing SG** (not "allow Lambda SG → 5432"): one shared SG with a
  self ingress on 5432. Lambdas attach the *same* SG in C1 (`securityGroupId`
  output), which sidesteps the resource-ordering coupling of a separate client SG.
- **Credentials via `manageMasterUserPassword`** — RDS mints/rotates the master
  secret; no plaintext in Pulumi state. `connectionConfig.secretArn` surfaces
  `masterUserSecrets[0].secretArn`; the runtime resolves it at cold start.
- **Output shape:** `@schema connectionConfig {host, port, database, secretArn}`
  (Output) + `securityGroupId` (Output) + `subnetIds` (pass-through for the Lambda
  `vpcConfig`). Serializable for the C1 handler env var.
- **Deferred: Aurora / Serverless v2.** Second engine behind the *same*
  `connectionConfig` output shape — the `Rds.{Cluster,ClusterInstance}` bindings
  already exist (A0); wiring is a fast-follow, not a blocker for B/C.

Original A2 sketch (retained for reference):
A single reusable Pulumi component owning:
- **The instance**: `aws.rds.Instance` (single) or `aws.rds.Cluster` +
  `ClusterInstance` (Aurora Postgres / Aurora Serverless v2). Engine, version,
  storage, backup, multi-AZ, deletion-protection as component options.
- **Networking**: DB subnet group, security group allowing Lambda SG →
  5432. This is the biggest new surface vs. DynamoDB (which needs no VPC).
- **Credentials**: master password in Secrets Manager (or RDS-managed master
  secret); the component resolves a connection-config `Pulumi.Output.t` (host,
  port, db, secret ARN) that the storage adapters and Lambda env consume.
- **Shared, not per-surface**: one database can host all three surfaces' tables
  (`event_log`, `dcb_event`, QueryDb JSONB tables). The storage adapters take a
  reference to the shared `PgConnection`, they don't each provision a DB.
  Follow the "resources vs. operations" split: `PgConnection` emits the
  resources once; each `storageMaker` contributes only its table/schema concern.

### A3 — Schema provisioning at deploy time
**Decision (2026-07-05): one-shot in-VPC migration Lambda.** Invoked as a Pulumi
resource after the DB is up, running the exact `PgSchema.ensureSchema` the local
backend uses — zero schema drift, and it works for VPC-only RDS with no deploy-
runner network reach (the common case). The command/dynamic-resource option is
rejected: it needs the deploy runner to reach the DB, which breaks for VPC-only
RDS unless the instance is publicly accessible or the runner runs in-VPC.

`reventless-postgres` exposes idempotent `PgSchema.ensureSchema(pool)`. At
deploy time this must run against the freshly-provisioned DB. Options
(pick in the plan's design step):
- A Pulumi `command`/dynamic resource that connects and runs `ensureSchema`
  (needs network reachability from the deploy runner → complicates VPC-only DBs).
- **A one-shot migration Lambda** in-VPC invoked as a Pulumi resource after the
  DB is up (mirrors how other post-provision steps run). Preferred for VPC-only
  RDS. Reuses the exact `ensureSchema` the local backend uses → zero schema
  drift between local and AWS.

---

## Phase B — Per-surface storage adapters

### ⚠️⚠️ Coupling finding (2026-07-05 — discovered before the builder step)

**For aggregates, EventLog storage and event propagation are one mechanism: the
DynamoDB stream.** `Aggregate_Builder_Single.Make` wires three coupled modules —
`EventLogStorage.DynamoDbStream` (EventLog table *with* a stream),
`EventTopicPublisher.DynamoDbStream` (publishes events off that stream), and
`EventCollectorChannel.DynamoDbStream` (consumes the stream → read models &
cross-aggregate reactions). The aggregate's write path *and* its entire
downstream propagation both ride that one table's stream.

**Consequence:** routing an aggregate's EventLog to Postgres while leaving the
propagation on DynamoDB streams ships a **silently broken** system — commands
append to Postgres, the still-created DynamoDB table (whose stream feeds the
EventCollector) stays empty, so every projection and cross-aggregate reaction
no-ops. Therefore **B1(aggregate) is inseparable from B2** (the Postgres
change-feed → EventCollector bridge): any aggregate with read models or
cross-entity flows needs both at once. Postgres has no streams, so the propagation
must come from `PgChangeFeed` via a relay Lambda / long-lived consumer.

The runtime groundwork already landed (PgDriver pool, PgRuntime, EventLog
Postgres runtime, entry-point branch) is correct and still needed — but the
**deploy-time builder wiring was deliberately NOT done**, because on its own it
would produce the broken half above. The only vertical isolatable from B2 is an
aggregate/DCB with **zero read models and zero cross-entity reactions**
(pure command → append → replay) — a thin proof, and even that wants a
storage-selection change so no unused DynamoDB table is created.

**Decision needed** (the fork): (a) do B2's change-feed bridge next so a *real*
aggregate/DCB vertical works end to end; (b) ship the thin write/replay-only proof
first (needs D1 storage-selection to avoid the wasted DynamoDB table); or (c) pause
the deployed path and instead harden/extend the in-process/`reventless-local`
Postgres path (which already works) until the change-feed design is settled.

**Chosen (2026-07-05): (a) — design B2 first.** See the deep-design doc
[`aws-postgres-change-feed-bridge.md`](./aws-postgres-change-feed-bridge.md). Two
constraints it establishes: **B2 is DCB-first** (only DCB has a change feed; the
classic `event_log` feed is net-new, deferred), and the relay **injects via the
existing SQS-fed EventCollector path** (`handleDynamoDbOrSqsEvent`), pushing
`rawSequencedEvent`s transformed into the EventCollector JSON shape.

### ⚠️ Reframing (2026-07-05 — discovered while starting B1)

**The deployed Lambda does not use the storageMaker's `operations` Output.** The
runtime path is a set of **hand-written `.mjs` entry points** under
`src/adapter/Runtime/` (`AggregateEntryPoint.mjs`, `ReadModelEntryPoint.mjs`,
`DcbCommandTopicEntryPoint.mjs`, …) that, at cold start, read a `HANDLER_CONFIG`
env var (resolved resource IDs serialized at deploy time by the `*Runtime_Builder`
modules), dynamically import the Spec/Behavior modules, and **bind storage ops
directly from the DynamoDB runtime modules**. Concretely, `AggregateEntryPoint.mjs`:
- `import { append, replay, replayStream, appendStream } from ".../EventLogStorage_DynamoDb_Runtime.res.mjs"` (hardcoded),
- `const resolvedTable = { name: eventLogTableName }` from the `eventLogTable` env,
- binds those ops into `EventLog_Operations`.

So a Postgres backend is **not** a drop-in `storageMaker` swap on the deployed
path. Each surface's EventLog/DcbEventLog/QueryDb ops are wired in a
backend-specific entry point. Delivering Postgres on the deployed path requires,
per surface:
1. a **Postgres branch in the entry point** — read a `connectionConfig` env var,
   build the pg pool at cold start (async Secrets Manager fetch →
   `PgDriver.makePool`, memoized per container; pg.Pool connects lazily so a
   password-provider callback is the clean rotation-safe option), bind
   `EventLogStorage_Postgres` / `DcbEventLogStorage_Postgres` /
   `QueryDbStorage_Postgres` runtime ops;
2. **env plumbing** in the `*Runtime_Builder.finish()` — serialize
   `PgConnection.connectionConfig` into `HANDLER_CONFIG` (or a dedicated
   `PG_CONNECTION` var) instead of / alongside the table name; attach IAM
   `secretsmanager:GetSecretValue` + VPC config (this is the **C1** work, so C1
   is no longer just "gates live test" — it's a prerequisite of B on the deployed
   path);
3. **backend selection** (**D1**) surfaced at entry-point granularity — e.g.
   presence of `PG_CONNECTION` picks the branch. D1 is therefore entangled with B,
   not a later step.

The `storageMaker`/selector-module framing below still holds for the **in-process
/ deploy-time-wiring** path and for `reventless-local`; it's the *deployed AWS
Lambda* path that goes through the entry points. **Decision (2026-07-05): branch
inside each existing entry point**, gated by presence of a `PG_CONNECTION` env var
— one code path per surface, per-Lambda env gives mixed/per-component backends
for free, DynamoDB stays the default with Postgres additive.

**Runtime pool foundation — landed (2026-07-05):**
- `PgDriver.poolConfig` (reventless-postgres) extended with discrete
  `host`/`port`/`database`/`user` + a `password` *provider* + `ssl`
  (`connectionString` now optional). Cloud-agnostic: the driver only takes a
  provider function; the Secrets Manager fetch stays AWS-side.
- `PgConnection.connectionConfig` now carries `username` (deploy-time known) so
  the pool builds without first awaiting the secret.
- `PgRuntime.poolFor(connectionConfig)` (reventless-aws) — one memoized pg pool
  per secret ARN per container, password resolved from Secrets Manager via a
  cached, rotation-safe provider (pg calls it per physical connection). This is
  the reusable cold-start glue every B-surface entry-point branch will call.

**Aggregate EventLog runtime + entry-point branch — landed (2026-07-05):**
- `EventLogStorage_Postgres_Runtime.res` (reventless-aws, EventLog surface folder)
  — `opsFor(connectionConfig, ~logName) => EventLog_Adapter.operations`, mirroring
  `EventLogStorage_DynamoDb_Runtime`'s role. `logName` is the per-aggregate
  `event_log.log_name` (all aggregates share one Postgres table).
- `AggregateEntryPoint.mjs` gained a **Postgres branch** in `buildAggregateParts`,
  selected by presence of a per-handler `pgConnection` field in `HANDLER_CONFIG`
  (finer than a single env var — supports mixed/per-aggregate backends, the D1
  goal). Absent `pgConnection` ⇒ the DynamoDB path is byte-identical. Verified:
  clean build, entry-point import smoke test passes, all 139 reventless-aws tests
  green.

**Classic vertical — deploy-time half landed (2026-07-05).** The B1 aggregate
path is now end-to-end at the wiring level, mirroring the DCB (B2.3c/d) pattern
piece for piece:
- **`EventLogBackend`** (adapter/EventLog/) — classic analogue of `DcbBackend`:
  platform selection `{connectionConfig, securityGroupId, subnetIds}` + a
  relay-log registry `{logName, aggregateName, collectorQueue*}`. Filled in two
  steps per plugin build: `EventLogStorage_Postgres.make` registers each log
  (`<Aggregate>EventLog`); `PluginRuntime_Builder.forPluginEventCollector`
  attaches the plugin's EventCollector SQS queue — its `~eventTopics` dict is
  keyed by aggregate name, so it attaches exactly the aggregates whose DynamoDB
  stream the collector would have subscribed (admin EP filtering included).
- **`EventLogStorage_Postgres` + `EventLogStorage.Selectable`** — deploy-time
  classic maker (`resources: []`, ops from `EventLogStorage_Postgres_Runtime`)
  + selector, wired into `Aggregate_Builder_Single` and `_Single_Async` (the
  Platform strategies). PerAggregate/Micro/NoResolver stay DynamoDB-only. The
  builders substitute the stable `<Aggregate>EventLog` log-name for the table
  name when Postgres is active.
- **`AggregateRuntime_Builder_Single(_Async).finish()`** — emits a per-handler
  `pgConnection` fragment into HANDLER_CONFIG (activates the entry-point branch),
  puts the AllAggregates(-Async) Lambda in-VPC on the DB SG/subnets, and grants
  `secretsmanager:GetSecretValue` on the DB secret (the C1 items for aggregates).
  Whole-Lambda toggle: all Single-strategy aggregates follow the platform
  selection — per-aggregate mixing remains a refinement.
- **Classic relay** — `PgChangeFeedRelay_Builder.relayLog` gained a
  `feed: Dcb({partitionTag}) | Classic` field; the entry point branches on
  `kind: "classic"` to `PgChangeFeedRelay_Runtime.relayClassic`, which drains
  `event_log` via `EventLogChangeFeed.drain` and feeds each stored `payload`
  (already the flat DynamoDB item shape — classic appends store the serialized
  event verbatim on both backends) through `buildJsonEvent'` — byte-identical
  EventCollector bodies. One shared relay Lambda serves DCB + classic logs.
- **`Platform.MakeWithConfig ~pgConnection`** now also sets `EventLogBackend`
  (classic follows the same toggle as DCB) and `provisionPgChangeFeedRelay`
  merges both registries. **Checkpoint-clobber fix:** `dcb_subscription` /
  `event_log_subscription` key by subscriber alone, but the relay used one
  shared subscriber string for all logs — multiple logs would clobber each
  other's checkpoints and skip events. Subscriber is now per-log
  (`aws-eventcollector-relay:<logName>`), for DCB logs too (pre-live, so no
  migration; a re-deploy replays from scratch — projections are idempotent).
- Validated: full monorepo build zero warnings; 1758 tests green incl. new
  `PG_URL`-gated classic-relay integration tests (bodies, checkpoint, and a
  cross-log checkpoint-isolation regression test); relay entry-point import
  smoke test. The remaining untested surface is the same as B2.4's: the live
  AWS boundary (SQS SendMessage, in-VPC Lambdas, EventCollector fan-out).

### Original per-surface sketch (in-process / storageMaker path):
Each mirrors the DynamoDB adapter file layout
(`<Surface>Storage_Postgres{,_Runtime}.res` under the surface folder, registered
in the surface's `<Surface>Storage.res` selector module):

- **B1 EventLog** — `storageMaker` whose `resources` reference the shared
  `PgConnection` (and the migration dependency), and whose `operations` are the
  `reventless-postgres` classic runtime ops (`append`/`replay`/`replayStream`/
  `appendStream`/`latestSnapshot`/`writeSnapshot`) bound to a lazily-resolved
  pool built from the injected connection secret.
- **B2 DcbEventLog** — same for the DCB runtime. **Plus the change-feed
  bridge**: the DynamoDB DCB adapter feeds projections via DynamoDB Streams;
  Postgres has no Streams. Wire `PgChangeFeed` (checkpointed LISTEN/NOTIFY +
  `dcb_subscription`) into whatever consumes the AWS EventCollector today — this
  is the one genuinely new AWS-side component (a poller/relay Lambda or a
  long-lived consumer). Design it against the feed-consumer public API the done
  plan established (D2 there).
- **B3 QueryDb + QueryEngine** — ✅ **scoped (2026-07-05)**, own sub-plan:
  `docs/plans/aws-postgres-querydb-adapter.md`. Summary: storage + engine
  already exist live-validated in reventless-postgres; B3.1 is the mechanical
  B1-style AWS glue (registry, deploy-time maker, runtime opsFor, VPC/IAM),
  B3.2 is the real project — a shared in-VPC Lambda AppSync data source
  replacing the direct DynamoDB resolvers (Option A; RDS Data API kept as
  documented alternative), B3.3 (live updates) deferred.

---

## Phase C — Lambda runtime & connectivity

### C1 — Runtime env & IAM (core)
- Inject the connection secret ARN + host/db into handler env
  (`RuntimeEnvironment_Lambda`). Resolve the secret at cold start, build one
  `pg.Pool` per container, reuse across invocations.
- IAM: `secretsmanager:GetSecretValue` on the secret; VPC execution role
  (`ec2:CreateNetworkInterface` et al.) so Lambdas can reach the DB.
- **VPC placement**: any Lambda touching Postgres must be in the DB's VPC/subnets
  with the Lambda SG. This is a material change to the Lambda deploy shape and
  must thread through the Runtime builders — call out cold-start / ENI-latency
  implications.

### C2 — Pooling × locking (hardening)
The done plan (B4) ships both `#AdvisoryLocks` (default, transaction-scoped —
safe under PgBouncer transaction mode, **pins connections on RDS Proxy**) and
`#RowLocks` (RDS-Proxy-safe). Expose the strategy as a `PgConnection` /
per-surface config knob and **document the default deployment shape**:
- Direct-to-RDS, few long-lived Lambda-container pools → `#AdvisoryLocks`.
- RDS Proxy (recommended at Lambda scale for connection multiplexing) →
  `#RowLocks`.
Lambda's fan-out concurrency makes connection exhaustion a real risk; the docs
must steer, and the default should be safe for the common Lambda+Proxy case.

---

## Phase D — Backend selection & routing

- **D1** A platform must be able to choose Postgres per surface (e.g. DCB log on
  Postgres for exact semantics, QueryDb still on DynamoDB). Decide where the
  choice lives (platform config passed to `Platform.MakeWithConfig`) and make it
  explicit, not a global flag. Mixed deployments are a feature, not an edge case.
- **D2** Deploy-time command publishers tag messages with `meta.service`
  (target aggregate's spec name) for projection dispatch — verify the Postgres
  path doesn't silently break this routing (see the repeatedly-bit
  `meta.service`-dispatch memory). A `service`-mismatch is a silent no-op.

---

## Phase E — Example & CI

- **E1** Prove it end-to-end: deploy one plugin (aggregates or DCB) on RDS.
  Either extend a hybrid example or add `examples/online-shop-postgres/`.
  Keep example plugins test-only per repo convention (GWT tests, no ui/).
- **E2** CI deploy smoke that provisions a throwaway RDS (or Aurora Serverless
  v2 min-capacity for cost), runs migrate → append → replay → read-model query →
  teardown. Guard/skip when no AWS creds (keep default `pnpm test`
  dependency-free, as the local pg suite already does with `PG_URL`).

## Phase F — Docs

`docs/guides/postgres-aws-deployment.md`: provisioning options (RDS vs. Aurora
vs. Serverless v2), VPC/subnet/SG setup, Secrets Manager wiring, RDS Proxy +
lock-strategy guidance, cost notes, and a **decision section: managed Postgres
vs. DynamoDB** (exact DCB semantics & monotonic positions & relational tooling
vs. DynamoDB's serverless-native zero-VPC operational simplicity). Cross-link
from the platform-and-plugin guide and the done storage-adapter plan.

## Non-goals (v1)

- **New storage semantics** — none. The engine is done and validated; this plan
  is provisioning + wiring only.
- **Multi-region / global-database** RDS topologies.
- **Logical-decoding change feed** (still deferred — see the done plan's Phase D;
  the checkpointed LISTEN/NOTIFY feed is the AWS path too).
- **Automatic DynamoDB→Postgres data migration** — greenfield deploy or wipe;
  cross-backend event migration is a separate plan (cf. the alpha-wipe stance).
- **Managing an external/self-hosted Postgres** — this plan provisions AWS RDS/
  Aurora. Pointing the runtime at a pre-existing DB is already possible via the
  connection-string runtime; that's a config note, not this plan.

## Risks / open questions

- **VPC changes the whole Lambda deploy shape** (ENIs, cold-start latency,
  NAT for any outbound). Biggest divergence from the zero-VPC DynamoDB path —
  scope C1 first and honestly.
- **AppSync → Postgres read path** (B3): DynamoDB read models use direct AppSync
  resolvers; Postgres needs Lambda resolvers. Largest design unknown; may
  constrain which QueryDb features are reachable initially.
- **Change-feed relay on AWS** (B2): no Streams equivalent — a poller/relay
  Lambda or long-lived consumer is net-new infra with its own failure/restart
  and checkpoint-durability story.
- **Pooling at Lambda scale** (C2): connection exhaustion without RDS Proxy;
  advisory-lock pinning *with* it. The `#RowLocks` strategy is the hedge — make
  the Proxy path the documented default and test it.
- **Cost**: RDS is always-on (unlike DynamoDB on-demand). Aurora Serverless v2
  scales down but not to zero. The decision doc must be honest about this.
- **`xid8` cursors don't survive logical dump/restore** (carried from the done
  plan) — restore/DR runbooks must renumber cursors; note in the deployment
  guide.

## Sources

- Done plan: `docs/plans/done/postgres-storage-adapter.md` (engine design,
  live-validation results, deferred provisioning non-goal).
- Adapter shape: `reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb.res`
  (`storageMaker` = `{resources, operations}`).
- Change-feed API: `reventless/reventless-postgres/src/PgChangeFeed.res`.
- Schema provisioning: `reventless/reventless-postgres/src/PgSchema.res`
  (`ensureSchema`).
