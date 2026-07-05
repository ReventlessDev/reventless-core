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

## Suggested B2 phasing

| Step | Item |
|---|---|
| B2.0 | ✅ **Partly done (2026-07-05).** Resolved #2 (`id` = `derivePartitionKey(partitionTag, tags)`). #4 investigated and **corrected**: propagation is stream-driven (append-publish stubbed), so the relay must drive within-plugin projections AND cross-plugin SNS — see B2.0b. |
| B2.0b | ✅ **Done (2026-07-05).** Seam = the plugin EventCollector's SQS queue (`AdminEventCollectorEntryPoint`, already SQS-capable, fans out to SNS + read models + aggregates). Relay feeds that one queue; does not publish SNS directly. |
| B2.1 | ✅ **Done (2026-07-05).** `DcbEventLogStorage_Postgres_Runtime.opsFor` + `DcbCommandTopicEntryPoint.mjs` Postgres branch (storage swap only; propagation handled by the relay). Clean build, import smoke test, 139 tests green. |
| B2.2 | ✅ **Done (2026-07-05).** `PgChangeFeedRelay_Runtime`: `toEventCollectorJson` (rebuilds the DynamoDB-item dict → `buildJsonEvent'` for byte-identical output; `id` via `derivePartitionKey`) + `relay` (`PgChangeFeed.drain` → transform → injected `sendBatch`). Transform unit-tested against a golden `{id, meta, event}` body (2 tests). Clean build. |
| B2.3 | Relay deploy component + builder: in-VPC Lambda + schedule + IAM (`secretsmanager:GetSecretValue`, `sqs:SendMessage`); swap projection builders `EventCollectorChannel.DynamoDbStream` → `.SQS` when the DCB log is Postgres-backed (D1) |
| B2.4 | Local/integration test: append DCB events on Postgres → relay drains → projection updates (PG_URL-gated, like the existing pg suite) |
| B2.5 | Classic-`event_log` feed (notify + reader + checkpoint in reventless-postgres) — unlocks the aggregate deployed path on the same bridge — **separate follow-up** |

## Sources
- AWS propagation trace: `EventTopicPublisher_DynamoDbStream.res`,
  `EventCollectorChannel_DynamoDbStream.res`,
  `EventCollectorChannel_SQS_Runtime.res` (`handleDynamoDbOrSqsEvent`),
  `Util_DynamoDbStream_Runtime.res` (`buildJsonEvent'`),
  `EventMapperEntryPoint.mjs` / `AdminEventCollectorEntryPoint.mjs`.
- Feed API: `PgChangeFeed.res` (`readBatch`/`drain`/`listen`/checkpoints).
- Notify/feed gap: `PgSchema.res` (`pg_notify` in `dcb_append`; none on `event_log`).
