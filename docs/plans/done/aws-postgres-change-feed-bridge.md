# Design: AWS Postgres change-feed bridge (Phase B2)

**Status**: Design (2026-07-05). Part of `aws-postgres-rds-adapter.md`; this is the
B2 deep-design that the coupling finding in that plan showed is on the critical
path for *any* deployed Postgres vertical.
**Nature**: design doc — decisions + injection seam + phasing. No code yet.

## Why this is the gating piece

On AWS today, an entity's **write path and its entire event propagation are one
mechanism: the DynamoDB stream**. The EventLog/DcbEventLog table is created with
`streamViewType: NEW_IMAGE`; that native stream is wired (via a Lambda
event-source mapping) into the EventCollector Lambda, which fans out to read-model
projections, extension-point (SNS) events, and cross-plugin subscriptions.
`EventTopicPublisher.DynamoDbStream` *publishes nothing itself* — the stream is
the passive source.

Move storage to Postgres and that stream vanishes. So routing storage to Postgres
without replacing the stream ships a **silently broken** system: events land in
Postgres, the (empty) DynamoDB table's stream fires nothing, every projection and
cross-entity reaction no-ops. **The change-feed bridge is not optional polish — it
is the propagation path.**

## DCB-first (a hard constraint, not a preference)

Only the **DCB** log has a change feed. `dcb_append` (PgSchema) ends with
`PERFORM pg_notify('dcb_' || log_name, …)`, and `PgChangeFeed` provides the full
consumer API (`readBatch`/`drain`/`listen`/checkpoints via `dcb_subscription`),
emitting `DcbEventLog_Adapter.rawSequencedEvent` with monotonic `(xid8, position)`
cursors.

The **classic `event_log`** (aggregate path) has **no `pg_notify` and no feed** —
its only append hook is the in-process `onAppended` callback, which does not
survive the Lambda boundary. It *does* have a `global_seq bigint GENERATED ALWAYS
AS IDENTITY` column (a usable cursor), but a classic feed (notify trigger + reader
+ checkpoint) is **net-new `reventless-postgres` work**.

⇒ **The first deployed vertical is DCB, not aggregates.** The DCB feed already
exists and already emits the right shape; only the AWS relay + EventCollector
injection is missing. A classic-`event_log` feed is a deferred follow-up (its own
small reventless-postgres sub-plan), after which the aggregate deployed path
reuses this exact bridge.

## The injection seam

Traced end-to-end (DynamoDB path), the EventCollector consumes, per record, a JSON
event of shape:

```json
{ "id": "<entity-id>",
  "meta": { "service": "...", "time": "<pos>", "user": "...",
            "msgId": "<pos>", "correlationId": "<pos>", "ip": "..." },
  "event": "<EventType>#<payload-json>" }
```

produced by `Util_DynamoDbStream_Runtime.buildJsonEvent'` from the table's
NewImage. There is already a **selectable SQS EventCollector channel**:
`EventCollectorChannel` exposes `SQS`, `SQS_FIFO`, and `DynamoDbStream` variants;
the projection builders (`ReadModel_Builder_Single`,
`StateViewSliceRuntime_Builder_Single`) currently hardcode `DynamoDbStream`, and
`EventCollectorChannel_SQS_Runtime` already consumes the same JSON event shape
from an SQS body.

**Chosen seam (refined by B2.0b below): the relay feeds the plugin EventCollector
hub's SQS queue.** The relay transforms each `rawSequencedEvent` into the JSON shape
above and `SendMessage`s it to the SQS queue drained by the plugin EventCollector
Lambda (`AdminEventCollectorEntryPoint`); that hub then fans out to read-model
queues, aggregate command topics, and the cross-plugin SNS EventTopic — the full
propagation, from one message. (Rejected: invoking an entry point with a synthetic
DynamoDB-stream event — brittle shape-mimicry vs. the clean SQS body the SQS
handler already expects. Also rejected: the relay publishing SNS itself — leaves
SNS wiring in the collector where it belongs.) See the B2.0b resolution below for
why this one seam covers both projections and cross-plugin SNS.

### ⚠️ Correction (2026-07-05): the relay MUST drive cross-plugin SNS too

An earlier draft claimed cross-plugin SNS was append-driven (from
`DcbEventLog_Operations.append` → `publishToEventTopic`) and therefore
backend-independent. **That is wrong for the deployed path.** The deployed command
Lambdas **stub the append-side publish to a no-op**:
`AggregateEntryPoint.mjs:151` injects `eventTopic: { publish: async () => {} }`,
and `DcbCommandTopicEntryPoint.mjs:108` injects `publishJson: async () => {}`.
The source-level `publishToEventTopic` in `DcbEventLog_Operations` runs, but its
`publishJson` does nothing in the Lambda.

**On AWS, ALL propagation is stream-driven**, not append-driven. The DynamoDB
stream drives *both*:
- within-plugin projections (EventCollector → read models, StateViewSlices,
  automations, side-effects), AND
- cross-plugin SNS (a stream-consuming EventMapper Lambda publishes to the SNS
  EventTopic via `EventTopicPublisher_SNS_Runtime`; `EventTopicPublisher_DynamoDbStream`
  is the passive stream-source extractor).

⇒ Moving DCB storage to Postgres removes the stream, so the relay must replace
**both** propagation paths — the within-plugin EventCollector *and* the
cross-plugin SNS EventTopic publish.

**B2.0b trace (2026-07-05) — resolved, one seam covers both.** The plugin-level
EventCollector Lambda (`AdminEventCollectorEntryPoint.mjs` — the general plugin
collector despite the name) is the single fan-out hub, and it is **already
SQS-capable**: it drains an SQS `queueUrl` via `handleDynamoDbOrSqsEvent`, and from
one decoded `{id, meta, event}` it drives the *entire* fan-out —
- cross-plugin SNS publish (`publishToEventTopic → EventTopicPublisher_SNS_Runtime.publish`),
- read-model EventCollector queue routing (`readModelQueueUrls`),
- aggregate command-topic routing (`publishToAggregates`),
- plugin extension-point routing.

⇒ **The relay feeds this one SQS queue** in the `{id, meta, event}` shape; the
existing Lambda then drives both projections and cross-plugin SNS. The relay does
**not** call `EventTopicPublisher_SNS_Runtime` directly (SNS wiring stays in the
collector). D1 wiring (B2.3) points the collector's event source at the relay-fed
SQS queue instead of the DCB DynamoDB stream — the Lambda code is unchanged
(already handles SQS input).

## The relay

A new deploy-time component + runtime entry point: **`PgChangeFeedRelay`**.

- **Runtime**: an in-VPC Lambda that, per invocation:
  1. builds/reuses the container pool (`PgRuntime.poolFor` — already landed),
  2. `PgChangeFeed.drain(pool, ~logName, ~subscriber="aws-eventcollector-relay",
     ~handle)`, where `handle`:
     - maps each `rawSequencedEvent` → the EventCollector JSON shape (position →
       `meta.{time,msgId,correlationId}`; `eventType`+`data` → `event`
       `"<type>#<json>"`; DCB `tags` → `id` — **exact `id` derivation for DCB is
       the first implementation task**; must match what the DCB DynamoDB-stream
       decoder produces for DCB events),
     - batch-`SendMessage` to the EventCollector SQS queue,
  3. `drain` advances the `dcb_subscription` checkpoint after each page.
  At-least-once: `drain` replays the last page on crash-before-checkpoint;
  EventCollector projections are already idempotent (event-sourced), so this is safe.

- **Trigger — decision needed** (v1 recommendation: **scheduled poll**):
  - *Scheduled EventBridge poll* (e.g. every 1–5 s): simplest, fully serverless,
    zero long-lived infra. Latency = poll interval. `pg_notify` unused on AWS in
    v1. **Recommended for v1.**
  - *Long-lived LISTEN consumer* (Fargate holding `PgChangeFeed.listen`): sub-second
    latency, but net-new always-on infra with its own restart/health story. A
    documented low-latency upgrade, not v1.

- **Deploy-time**: new builder wires the relay Lambda (in-VPC via
  `PgConnection.securityGroupId`/`subnetIds`; IAM `secretsmanager:GetSecretValue`
  + `sqs:SendMessage`), the schedule rule, and — critically — **switches the
  EventCollector's event source from the DynamoDB stream to the SQS queue** when
  the DCB log is Postgres-backed (the D1 selection surfaces here too).

## What B2 pulls in (scope reality)

1. **D1 storage selection for DCB** — a Postgres-backed DCB log must NOT create the
   `dcb_event` DynamoDB table + stream; storage is the shared `PgConnection`. This
   is the `DcbEventLogStorage.DynamoDb` → `Postgres` selector swap + builder threading.
2. **DcbEventLog Postgres runtime module** (the B2/B-DCB analogue of the
   already-landed `EventLogStorage_Postgres_Runtime`) — binds
   `DcbEventLogStorage_Postgres` read/append/readStream to the container pool for
   the `DcbCommandTopicEntryPoint.mjs` Postgres branch.
3. **The relay** (component + entry point + builder), above.
4. **C1** (env/IAM/VPC) for both the DCB command Lambda and the relay Lambda.
5. **The event-shape transform** (`rawSequencedEvent` → EventCollector JSON),
   verified against the DCB DynamoDB-stream decoder output.

## Resolved (was open, now settled by the B2.0 trace)

- ✅ **#2 `id` derivation** — the projection input JSON is
  `{id, meta, event: combineMessage(eventType, payload)}` (built by
  `Util_DynamoDbStream_Runtime.buildJsonEvent'`). For DCB the `id` is the
  DynamoDB partition key, which `DcbEventLogStorage_DynamoDb_Runtime.toItem`
  computes as `derivePartitionKey(partitionTag, tags)` (Simple → `"{key}:{value}"`;
  Composite → composite; no tags → `"dcb"`). **The relay reuses `derivePartitionKey`
  with the DCB log's `partitionTag`** (threaded in at deploy time by the builder).
  `meta` via `Message.decomposeMeta`; `position` → `meta.{time,msgId,correlationId}`.
- ✅ **#4 propagation — resolved (correctly, via B2.0b).** Propagation is
  stream-driven (append-publish stubbed), and the relay must drive both projections
  and cross-plugin SNS — but **one seam does it**: the relay feeds the plugin
  EventCollector's SQS queue (`AdminEventCollectorEntryPoint`, already SQS-capable),
  which fans out to SNS + read models + aggregates from a single `{id, meta, event}`
  message. Relay does not publish SNS directly. (An earlier note wrongly called SNS
  "append-driven"; corrected above.)

## Still-open decisions (to resolve before coding B2)

1. ✅ **Relay trigger — decided (2026-07-05): scheduled EventBridge poll for v1.**
   A rate rule (e.g. every 1–5 s) invokes the relay Lambda to drain the feed;
   fully serverless, zero long-lived infra, latency = poll interval. Fargate-LISTEN
   (`PgChangeFeed.listen`, sub-second) is a documented low-latency upgrade, not v1.
2. **Per-log vs shared relay**: one relay Lambda draining all Postgres DCB logs
   (loop over `logName`s) vs. one per log. Shared is cheaper; per-log isolates
   failure/latency. Lean shared with per-log checkpoints.
3. **SQS body shape**: confirm the exact SQS message body
   `EventCollectorChannel_SQS_Runtime` expects (the `{id, meta, event}` JSON, or a
   wrapper) — pin it with a golden fixture in B2.2 before wiring the relay send.

## B2.3c detailed design (D1 — the deploy-time Postgres selection seam)

**Status**: Implemented (2026-07-05). Decisions confirmed: **platform-level toggle**
(all DCB logs → Postgres when a `PgConnection` is supplied; aggregate EventLogs
stay on DynamoDB). **Storage-selection half landed as B2.3c** (changes 1–5 below);
**relay auto-wiring half landed as B2.3d** (changes 6–7 — the relay call, now fired
from both `makePlatform` and `deployPlugin`, + the sury `partitionTag` wire-format).
See the phasing table. Live-deploy validation remains (B2.4).

### The two facts that shape this step

1. **No deploy-time Postgres selection surface exists yet — anywhere.** `PgConnection`
   provisions RDS + returns `{connectionConfig, securityGroupId, subnetIds}`, but it
   is unwired: `Platform.res` never references it, and nothing at deploy time sets the
   `PG_CONNECTION` env that the B2.1 `DcbCommandTopicEntryPoint.mjs` Postgres branch
   reads. **B2.3c is the linchpin that makes the whole Postgres DCB vertical
   deployable**, not just an event-source rewire.
2. **A whole-platform "Postgres mode" would silently break aggregates.** The classic
   `event_log` feed is deferred to B2.5, so routing aggregate EventLogs to Postgres now
   lands events with no propagation — the exact failure this plan warns about. ⇒ the
   toggle is **DCB-scoped**: within one platform, DCB logs go to Postgres while
   aggregate EventLogs stay on DynamoDB.

### Why the selection lives AWS-side (reventless-core untouched)

Storage is a **compile-time functor parameter**
(`Platform_Admin.Make(…, DcbEventLogStorage.DynamoDb, EventTopicPublisher.DynamoDbStream, …)`
at `Platform.res:1127-1128`; same at `Plugin.res:24`), threaded into
`Plugin_Builder.Make` → `Dcb_Builder.Make` → `DcbEventLog_Builder.Make`. We do **not**
swap functors conditionally (painful in ReScript's module language) and we do **not**
add a `pgConnection` field to core's `platformHooks` (the `PgConnection.t` type lives in
reventless-aws). Instead:

- The AWS storage module becomes **selectable at build time via an AWS-side ref**
  (`DcbBackend`), set by the platform before any `construct` runs. `DcbEventLogStorage`
  gains a `Selectable` module whose `make` reads the ref and dispatches to `DynamoDb.make`
  (unchanged) or a new `Postgres.make`. The functor arg at `Platform.res:1127` /
  `Plugin.res:24` becomes `DcbEventLogStorage.Selectable`.
- The core `DcbEventLog_Builder` only ever consumes `storage.resources` (→ EventTopic
  `storageResources` + `outputs.resources`) and `storage.operations`. Both tolerate the
  Postgres shape (empty resources, pool-bound ops) with **no core change**.

This confines B2.3c to reventless-aws.

### The event-source rewire falls out for free

`EventCollectorChannel_Helpers.res:248` creates a DynamoDB-stream ESM **per
`dynamoDbStreamResource`**. A Postgres DCB log's storage returns **no** stream resource,
so its DCB EventTopic (still built with the `DynamoDbStream` publisher, now a harmless
passive marker) contributes no stream → **no ESM is created**. The collector already
drains its own SQS queue (`EventCollectorChannel_Helpers.res:260-263`). So "point the
EventCollector at the relay-fed queue" reduces to **the relay `SendMessage`s to the
collector's existing SQS queue URL** — no ESM surgery, no publisher swap.

### Concrete AWS-side changes

1. **`DcbBackend.res`** (new, reventless-aws) — a module holding
   `ref<option<pgSelection>>` where `pgSelection = { connectionConfig, securityGroupId,
   subnetIds }` (echoed from `PgConnection.t`). Set once by the platform; read by the
   selectable storage, the DCB-command runtime env builder, and `makePlatform`'s relay
   wiring. Mirrors the existing `apiConfigRef` / hooks-ref pattern in `Platform.res`.
2. **`DcbEventLogStorage_Postgres.res`** (new) — a deploy-time `storageMaker` returning
   `{ resources: [], operations }`; operations bound to the pool via
   `DcbEventLogStorage_Postgres_Runtime` (B2.1) + the ref's `connectionConfig`. Creates
   **no** table and **no** stream.
3. **`DcbEventLogStorage.res`** — add `module Postgres = DcbEventLogStorage_Postgres`
   and `module Selectable` (reads `DcbBackend`, dispatches). Repoint the functor args
   (`Platform.res:1127`, `Plugin.res:24`) to `.Selectable`.
4. **`Platform.MakeWithConfig`** — add `pgConnection: option<PgConnection.t>` to its
   Config; when `Some`, set `DcbBackend` and echo `securityGroupId`/`subnetIds` so DCB
   Lambdas land in-VPC (the `~vpcConfig` seam landed in B2.3b).
5. **DCB command Lambda env** — in the AWS `PluginRuntime_Builder` (`forDcbCommandTopic`
   / `registerDcbTableName`), when Postgres inject `PG_CONNECTION` (from
   `connectionConfig`) + the DB-access SG/subnets into the DcbCommandTopic Lambda, so the
   B2.1 Postgres branch activates. The `onDcbEventLogCreated` hook
   (`Platform.res:1002`, currently `resources->Array.getUnsafe(0)` for the table name)
   branches on Postgres — there is no table; register the PG connection instead.
6. **Relay provisioning** — in `makePlatform`, when `DcbBackend` is set, gather the
   per-DCB-log `{connectionConfig, logName (= name ++ "DcbEventLog"), subscriber,
   targetQueueUrl/Arn (= collector SQS queue), partitionTag}` and call
   `PgChangeFeedRelay_Builder.make` once (shared relay, per-log checkpoints).
7. **partitionTag threading** (was the B2.3b caveat) — add `partitionTag` to the
   builder's `relayLog` and serialize it into `HANDLER_CONFIG.logs[]`. The runtime +
   entry point already consume `l.partitionTag`; only the deploy-side is missing.

### Open verification points (resolve during implementation)

- Confirm `EventTopic_Builder` + `EventTopicPublisher_DynamoDbStream` tolerate empty
  `storageResources` (expected: passive registration → no ESM; no crash).
- Confirm where the collector's SQS queue URL/ARN is available at `makePlatform` time,
  and that per-plugin DCB `logName` + `partitionTag` are reachable there (the
  `onDcbEventLogCreated` / `onDcbSlicesCreated` hooks already surface the DcbEventLog
  component — extend them to collect relay inputs).
- The `partitionTag` for the relay must equal the one the DCB storage used
  (`derivePartitionKey` parity — already the B2.2 invariant).

### What cannot be unit-tested here

The full path needs a live RDS + VPC deploy (**B2.4**, `PG_URL`-gated). B2.3c ships the
wiring + a clean build + import smoke tests; end-to-end (append on Postgres → relay drains
→ projection updates) is B2.4.

## Suggested B2 phasing

| Step | Item |
|---|---|
| B2.0 | ✅ **Partly done (2026-07-05).** Resolved #2 (`id` = `derivePartitionKey(partitionTag, tags)`). #4 investigated and **corrected**: propagation is stream-driven (append-publish stubbed), so the relay must drive within-plugin projections AND cross-plugin SNS — see B2.0b. |
| B2.0b | ✅ **Done (2026-07-05).** Seam = the plugin EventCollector's SQS queue (`AdminEventCollectorEntryPoint`, already SQS-capable, fans out to SNS + read models + aggregates). Relay feeds that one queue; does not publish SNS directly. |
| B2.1 | ✅ **Done (2026-07-05).** `DcbEventLogStorage_Postgres_Runtime.opsFor` + `DcbCommandTopicEntryPoint.mjs` Postgres branch (storage swap only; propagation handled by the relay). Clean build, import smoke test, 139 tests green. |
| B2.2 | ✅ **Done (2026-07-05).** `PgChangeFeedRelay_Runtime`: `toEventCollectorJson` (rebuilds the DynamoDB-item dict → `buildJsonEvent'` for byte-identical output; `id` via `derivePartitionKey`) + `relay` (`PgChangeFeed.drain` → transform → injected `sendBatch`). Transform unit-tested against a golden `{id, meta, event}` body (2 tests). Clean build. |
| B2.3a | ✅ **Done (2026-07-05).** `PgChangeFeedRelayEntryPoint.mjs` (scheduled poll): reads `HANDLER_CONFIG.logs[]`, drains each DCB log via `relay`, sends each `{id, meta, event}` body to the plugin EventCollector SQS queue (`sendMessage`, standard queue). Import + empty-config smoke tests pass. |
| B2.3b | ✅ **Done (2026-07-05).** `PgChangeFeedRelay_Builder.make(~logs, ~securityGroupId, ~subnetIds, ~intervalMinutes)`: bundles the entry point, provisions the in-VPC relay Lambda (via `makeFromCodeAsset ~vpcConfig`) + EventBridge rate rule + `Permission` + `EventTarget` + IAM (`secretsmanager:GetSecretValue`, `sqs:SendMessage` over all logs' secrets/queues); serializes `HANDLER_CONFIG.logs[]` from Outputs. **Also landed C1 core:** `makeFromCodeAsset` gained `~vpcConfig` (threaded to `Lambda.Function`) + auto EC2-ENI IAM for VPC Lambdas. **Caveat:** EventBridge rate floor = 1 min, so v1 latency ≥ 1 min (`partitionTag` in HANDLER_CONFIG still TODO — B2.3c supplies it). |
| B2.3c | ✅ **Done (2026-07-05) — storage-selection half.** Deploy-time DCB Postgres selection introduced AWS-side (reventless-core untouched): `DcbBackend` selection ref; `DcbEventLogStorage_Postgres` (deploy-time storage → **no** table/stream, empty `resources`, pool-bound ops); `DcbEventLogStorage.Selectable` dispatches on the ref and is now the functor arg at `Platform.res` + `Plugin.res`. Platform toggle `Platform.MakeWithConfig(~pgConnection)` sets `DcbBackend`. DCB command Lambda (`StateChangeSliceRuntime_Builder_Single.forDcbCommandTopic`) Postgres branch: `dcbEventLogTableName` = canonical log_name `<plugin>DcbEventLog`, HANDLER_CONFIG `pgConnection` object, in-VPC `vpcConfig`, `secretsmanager:GetSecretValue` IAM. `onDcbEventLogCreated` guarded (no table in PG mode). Because Postgres storage returns no stream resource, the DCB→collector DynamoDB-stream ESM auto-drops. Clean build, 147 tests green. |
| B2.3d | ✅ **Done (2026-07-05) — relay auto-wiring half.** `partitionTag` wire-format = **sury `@schema`** added to `partitionTag`/`compositePartitionSpec`/`derivedPartitionTag` (reventless-spec); the relay builder serialises it into `HANDLER_CONFIG.logs[].partitionTag` and `PgChangeFeedRelay_Runtime.relay` parses it back via `derivedPartitionTagSchema` (round-trip unit-tested, +2 tests). Collection = a **`DcbBackend` relay registry**, filled AWS-side in two steps during each plugin build: `DcbEventLogStorage_Postgres.make` records `{logName, partitionTag}`; `PluginRuntime_Builder.forPluginEventCollector` attaches that plugin's EventCollector SQS queue (keyed by `logName`, recovered from the `<plugin>Plugin` component name). `Platform` provisions one shared relay via `provisionPgChangeFeedRelay()`, called from **both** `makePlatform` (monolithic) and `deployPlugin` (plugin-stack). `relayLog` gained `partitionTag` (the B2.3b TODO). Clean build, 149 tests green. **Now end-to-end at the wiring level** — flipping `~pgConnection` stores DCB in Postgres *and* provisions propagation. Live-deploy validation is B2.4. |
| B2.4 | ✅ **Done (2026-07-05).** `PgChangeFeedRelay_IntegrationTest` (`PG_URL`-gated, skips otherwise): appends DCB events to a real `dcb_event` log → `PgChangeFeedRelay_Runtime.relayWithPool` drains the feed → transforms → injected `sendBatch` captures the `{id, meta, event}` bodies. Verifies the emitted bodies (id/event/meta), the checkpoint (second drain sees nothing), and the sury `partitionTag` wire-format pinning the `id` on a multi-tag event. `relay` was refactored to extract a pool-injectable `relayWithPool` (deployed `relay` stays the thin Secrets-Manager wrapper). Ran green against Postgres 16 (3/3). The remaining untested surface is the AWS boundary itself (SQS SendMessage + the in-VPC Lambda + EventCollector fan-out), which needs a live stack deploy. |
| B2.5 | ✅ **Done (2026-07-05).** Classic-`event_log` feed in reventless-postgres — the aggregate-path analogue of `PgChangeFeed`. Purely additive: `event_log` gains `transaction_id xid8 DEFAULT pg_current_xact_id()` (auto-stamped, no append change) + a `(log_name, transaction_id, global_seq)` index + `event_log_subscription` checkpoints + a statement-level `AFTER INSERT` trigger firing `pg_notify('evlog_<log>')`. New `EventLogChangeFeed` reader (readBatch/loadCheckpoint/saveCheckpoint/listen/drain) applies the same **xmin read barrier** as the DCB feed over a `<xid8>:<global_seq>` cursor — `global_seq` alone (an IDENTITY assigned pre-commit) would let a late-committing lower value be skipped. PG_URL-gated tests (fields+checkpoint, concurrent-appends-exactly-once) green against Postgres 16 (10/10). Design: `docs/plans/done/postgres-classic-eventlog-change-feed.md`. **Downstream (not B2.5):** the AWS classic relay + deploy-time classic-backend selection — the "aggregate deployed path reuses this bridge" step, tracked by the parent `aws-postgres-rds-adapter.md`. |

## Sources
- AWS propagation trace: `EventTopicPublisher_DynamoDbStream.res`,
  `EventCollectorChannel_DynamoDbStream.res`,
  `EventCollectorChannel_SQS_Runtime.res` (`handleDynamoDbOrSqsEvent`),
  `Util_DynamoDbStream_Runtime.res` (`buildJsonEvent'`),
  `EventMapperEntryPoint.mjs` / `AdminEventCollectorEntryPoint.mjs`.
- Feed API: `PgChangeFeed.res` (`readBatch`/`drain`/`listen`/checkpoints).
- Notify/feed gap: `PgSchema.res` (`pg_notify` in `dcb_append`; none on `event_log`).
