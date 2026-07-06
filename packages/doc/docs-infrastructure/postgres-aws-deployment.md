# Managed Postgres on AWS (RDS)

How to deploy a Reventless platform whose storage runs on AWS-managed Postgres
(RDS) instead of DynamoDB — what gets provisioned, how to wire it into a
platform, and the operational trade-offs (VPC, secrets, pooling, cost).

> **Audience:** anyone deploying a Reventless platform to AWS on a relational
> store — for exact DCB semantics, monotonic positions, or an EU-managed
> Postgres — while staying on the same Pulumi/Lambda machinery as the DynamoDB
> path.

> **Status:** the deploy path is wired end-to-end for all three storage surfaces
> (classic EventLog, DCB EventLog, QueryDb). What is **not** yet exercised on a
> live stack is called out inline (RDS Proxy provisioning, Aurora, the live AWS
> boundary). The storage engine itself (`reventless-postgres`) is live-validated.

---

## When to choose Postgres vs. DynamoDB

Postgres is **additive**, not a replacement — DynamoDB stays the default, and a
platform can put some surfaces on Postgres and leave others on DynamoDB (see
[Backend selection](#backend-selection)). Choose per-surface:

| Consideration | Managed Postgres (RDS) | DynamoDB |
|---|---|---|
| **DCB append semantics** | Evaluates the real `DcbTag.query` **atomically** in one transaction | *Emulates* the append condition with per-(tag, event-type) fence sentinel rows |
| **Positions / cursors** | Monotonic by construction (`(xid8, bigint)`) | Stream-sequence based |
| **Operational shape** | Always-on instance **inside a VPC** (ENIs, subnets, SG) | Serverless, on-demand, **no VPC** |
| **Cost** | Always-on (even idle); Aurora Serverless v2 scales down but not to zero | Pay-per-request, scales to zero |
| **Cold start** | +VPC ENI attach latency on the Lambdas that touch it | No VPC penalty |
| **Tooling** | Full relational tooling, `psql`, standard backups/PITR | DynamoDB-native tooling |
| **Read path** | Reads route through an in-VPC Lambda AppSync resolver | Direct AppSync→DynamoDB resolvers |

Rule of thumb: reach for Postgres when you need **exact DCB consistency** or
relational tooling, and accept the VPC/always-on cost. Stay on DynamoDB for the
zero-VPC, scale-to-zero serverless default.

The DCB semantics rationale lives in the storage-engine design; this guide is
**provisioning + wiring only** — no new storage semantics.

---

## What `PgConnection` provisions

A single `PgConnection` component owns the database and everything a Lambda needs
to reach it. One `PgConnection` hosts **all three** storage surfaces (classic
`event_log`, DCB `dcb_event`, and the QueryDb `qdb_*` tables) in one database —
the per-surface adapters take a reference to it, they don't each provision a DB.

`PgConnection.make` creates:

- **The RDS instance** — engine `postgres`, with `manageMasterUserPassword` so
  RDS mints and rotates the master credentials in Secrets Manager (no plaintext
  password ever lands in Pulumi state).
- **A shared security group** with a self-referencing `5432` ingress rule. Every
  Lambda that touches Postgres attaches this **same** SG, so it can reach the DB
  without a separate client-SG round-trip.
- **A DB subnet group** over the private subnets you supply.
- **A one-shot schema-migration Lambda** (A3) plus an `aws.lambda.Invocation`
  that runs `PgSchema.ensureSchema` **inside the VPC** during `pulumi up` — see
  [Schema migration](#schema-migration).

Networking is an **input, not provisioned**: you supply an existing VPC id and
private subnets. A full VPC is a platform concern (use the framework `Vpc`
component or a `StackReference` to a shared network stack).

### `PgConnection.make` parameters

| Parameter | Default | Notes |
|---|---|---|
| `~name` | — | Resource name prefix |
| `~vpcId` | — | Existing VPC (Output/Input) |
| `~subnetIds` | — | Private subnets (array of Input); also echoed to the Lambda `vpcConfig` |
| `~databaseName` | `"reventless"` | Exact string — no prefix/suffix transform |
| `~username` | `"reventless_admin"` | RDS master username (not secret) |
| `~engineVersion` | `"16"` | Postgres major version |
| `~instanceClass` | `"db.t3.micro"` | Size up for production |
| `~allocatedStorage` | `20` | GB |
| `~multiAz` | `false` | Enable for production HA |
| `~storageEncrypted` | `true` | |
| `~backupRetentionPeriod` | `7` | Days |
| `~deletionProtection` | `true` | Blocks accidental deletion — production safeguard |
| `~skipFinalSnapshot` | `false` | Keeps a final snapshot on delete |
| `~lockStrategy` | `#AdvisoryLocks` | DCB append lock — see [Pooling & lock strategy](#connection-pooling--lock-strategy) |

Only `postgres` (RDS) is wired today. **Aurora / Aurora Serverless v2** is a
planned second engine behind the same `connectionConfig` output shape — the
Pulumi bindings exist but the wiring is not yet landed.

---

## Wiring it into a platform

`PgConnection` is provisioned in the platform stack and handed to
`Platform.MakeWithConfig` as `~pgConnection`. When present, **every** DCB and
classic aggregate EventLog and (non-admin) QueryDb on the platform is
Postgres-backed; absent, everything stays on DynamoDB (unchanged).

```rescript
// platform-aws/src/Main.res (illustrative — see the platform-and-plugin guide
// for the full platform assembly around this)

// 1. Provision the managed Postgres (supply your VPC + private subnets).
let pg = ReventlessAws.PgConnection.make(
  ~name="my-platform",
  ~vpcId=network.vpcId,
  ~subnetIds=network.privateSubnetIds,
  // ~lockStrategy=#RowLocks,   // if fronting with RDS Proxy — see below
)

// 2. Build the platform on it.
module Platform = ReventlessAws.Platform.MakeWithConfig({
  let splitApi = true
  let cloner = false
  let commandHandlerConfig: ReventlessCore.Runtime.commandHandlerConfigs = {}
  let pgConnection = Some(pg)
})
```

Everything else about the platform — plugins, AppSync API, admin components — is
unchanged from the DynamoDB path; see the
[Platform & Plugin Guide](/app/platform-and-plugin-guide).

### Backend selection

The choice is **per surface**, recorded before any plugin `construct` runs:

- DCB EventLogs → `DcbBackend`
- classic aggregate EventLogs → `EventLogBackend`
- QueryDbs → `QueryDbBackend` (admin read models are **exempt** — deploy-time
  consumers query them from *outside* the VPC during `pulumi up`, so they stay on
  DynamoDB).

Today `~pgConnection` flips all of the above together. Per-component mixing
(e.g. one aggregate on Postgres, the rest on DynamoDB) is supported by the
registry design and threaded per-handler in `HANDLER_CONFIG`, but the
platform-level toggle is whole-platform; finer selection is a refinement.

---

## Networking & VPC

This is the **biggest divergence** from the zero-VPC DynamoDB path. Any Lambda
that touches Postgres must run in the DB's VPC:

- The command Lambdas (aggregate & DCB), the read-model projection Lambdas, the
  QueryDb resolver Lambda, the change-feed relay, and the migration Lambda all
  get a `vpcConfig` built from `PgConnection.{securityGroupId, subnetIds}`.
- The execution role automatically gains the EC2 network-interface permissions
  AWS requires for VPC Lambdas (`ec2:CreateNetworkInterface`,
  `DescribeNetworkInterfaces`, `DeleteNetworkInterface`) — added by
  `RuntimeEnvironment_Lambda` whenever a `vpcConfig` is set.

Implications to plan for:

- **Cold-start latency**: VPC Lambdas attach an ENI. Modern AWS keeps this cheap
  (Hyperplane ENIs), but it is non-zero versus the DynamoDB path.
- **Outbound access**: a VPC Lambda has **no internet route by default**. It
  reaches Secrets Manager, SQS, AppSync Events, etc. only via a **NAT gateway**
  or **VPC endpoints**. Provision these in your network stack, or the cold-start
  secret fetch (and any other AWS API call) will hang and time out.

---

## Secrets & IAM

Credentials are the RDS-managed master secret (`manageMasterUserPassword`), never
plaintext. Each Postgres-touching Lambda role gets a single extra grant:

```
secretsmanager:GetSecretValue   on the DB's master-user secret ARN
```

At cold start, `PgRuntime.poolFor` resolves the password from Secrets Manager via
a **cached, rotation-safe provider** (pg calls it per physical connection) and
memoises **one pool per secret ARN per container**. The username, host, port, and
database are known at deploy time and travel in the Lambda env, so the pool builds
without first awaiting the secret.

---

## Schema migration

`reventless-postgres` ships an idempotent `PgSchema.ensureSchema` (every DDL
statement is `IF NOT EXISTS`). On AWS it runs at deploy time via a **one-shot
in-VPC migration Lambda** that `PgConnection.make` provisions automatically:

- An `aws.lambda.Invocation` invokes the migration Lambda once during
  `pulumi up`, **from inside the VPC** — so the deploy runner needs no network
  path to a private RDS instance. (This is why a Lambda was chosen over a Pulumi
  `command`/dynamic resource, which would have to connect from the runner.)
- It runs the **exact** `ensureSchema` the local backend runs at startup, so the
  AWS schema is byte-identical to local — zero drift.
- It re-runs whenever the migration code or the Reventless Lambda layer (which
  ships the DDL) changes; an unchanged re-run is a no-op.

No manual migration step is required — provisioning a `PgConnection` creates its
schema.

---

## Event propagation: the change-feed relay

DynamoDB drives read-model projections and cross-plugin propagation off **DynamoDB
Streams**. Postgres has no streams, so a **scheduled in-VPC relay Lambda**
(`PgChangeFeedRelay`) takes their place:

- An EventBridge rate rule triggers it on a schedule (**1-minute floor** — v1
  poll latency is therefore ≥ 1 minute; sub-minute latency needs a self-invoking
  loop or the Fargate-LISTEN upgrade, both follow-ups).
- Each tick drains every Postgres log (`dcb_event` and classic `event_log`) from
  its checkpoint, transforms each event into the same `{id, meta, event}` shape a
  DynamoDB-stream record would have, and `SendMessage`s it to the plugin
  **EventCollector SQS queue** — which then fans out to projections, aggregate
  command topics, and the cross-plugin SNS EventTopic.
- Checkpoints are **per-log** (`dcb_subscription` / `event_log_subscription`,
  keyed by a per-log subscriber), so a missed tick is caught next tick
  (at-least-once; projections are idempotent).

This is net-new AWS infra with its own restart/checkpoint-durability story — plan
for the ≥1-minute propagation latency in v1.

---

## The QueryDb read path

DynamoDB read models are served by **direct AppSync→DynamoDB resolvers**. Postgres
has no such data source, so reads route through a **shared in-VPC Lambda AppSync
data source** (`PgQueryResolver`):

- One resolver Lambda is provisioned per platform, registered as a single AppSync
  Lambda data source; every Postgres read model's GraphQL resolvers become thin
  `Invoke` templates pointing at it.
- At cold start it builds the shared pool, imports each read model's spec, and
  dispatches AppSync queries (getById, index list, connection pagination, byIds,
  cross-table `@resolves`/`@resolvesMany`, node) to the `QueryEnginePostgres`
  push-downs.
- Keyset pagination cursors are opaque (base64 of the last key) so clients can't
  depend on their shape.

**Live updates** (AppSync Events subscriptions) are published from the projection
Lambda after each save/delete — no stream required — mirroring the local Sqlite
backend.

Note: AppSync can fan out reads far harder than command Lambdas, which makes the
pooling decision below **load-bearing**, not optional.

---

## Connection pooling & lock strategy

Lambda fan-out concurrency makes connection exhaustion a real risk. The DCB append
path takes a per-transaction lock, and its strategy is a knob on `PgConnection`:

| Deployment shape | `~lockStrategy` | Why |
|---|---|---|
| **Direct-to-RDS** (few long-lived Lambda-container pools) | `#AdvisoryLocks` (default) | Transaction-scoped, lowest overhead |
| **RDS Proxy** (recommended at Lambda scale for connection multiplexing) | `#RowLocks` | Advisory locks are session state RDS Proxy **cannot multiplex** — they would pin connections; row locks are Proxy-safe |

Only the **DCB command** Lambda takes this lock; classic EventLog and QueryDb
appends don't. The strategy threads from `PgConnection.make(~lockStrategy)`
through to the DCB command Lambda automatically.

> **RDS Proxy provisioning is a documented fast-follow.** `PgConnection` does not
> yet stand up an RDS Proxy or swap the connection host to the Proxy endpoint —
> the `#RowLocks` knob it pairs with is in place, but wiring the Proxy resource is
> not landed. Until it is, use `#AdvisoryLocks` with direct-to-RDS and a modest
> `reservedConcurrency` on the command Lambdas to bound the pool count.

---

## Cost

RDS is **always-on** — you pay for the instance whether or not it serves traffic,
unlike DynamoDB's pay-per-request on-demand model. Aurora Serverless v2 scales
capacity down (but **not to zero**) and is the cost hedge once the engine is
wired. Size `~instanceClass`, `~allocatedStorage`, and `~multiAz` to the
workload, and remember the VPC NAT gateway is its own hourly + per-GB cost.

---

## Operational notes

- **`deletionProtection` defaults to `true`** — deliberate. To tear down a
  throwaway stack, pass `~deletionProtection=false` (and `~skipFinalSnapshot=true`
  to skip the final snapshot).
- **`xid8` cursors do not survive a logical dump/restore.** After a
  `pg_dump`/restore or a cross-instance DR failover, the DCB position space is
  renumbered — restore runbooks must account for this. (Physical snapshots / PITR
  preserve `xid8` and are unaffected.)
- **Greenfield only.** There is no automatic DynamoDB→Postgres data migration;
  deploy fresh or wipe. Cross-backend event migration is a separate concern.
- **Pointing at an external/self-hosted Postgres** (not RDS) is possible via the
  connection-string runtime directly — that is a config note, not this path.

---

## See also

- [Platform & Plugin Guide](/app/platform-and-plugin-guide) — the full platform
  and plugin assembly this wiring plugs into.
- [Per-Plugin AWS Deployment Guide](./deployment-guide.md) — per-plugin Pulumi
  stacks and CI.
- [AppSync Events & Live Updates](./appsync-events-live-updates.md) — the
  live-update path Postgres read models publish on.
- [AWS DCB EventLog adapter](./aws/adapters/dcbeventlog.md) — the DynamoDB DCB
  adapter this is an alternative to.
