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

**Chosen seam: D1 swaps projections to `EventCollectorChannel.SQS` when the DCB
log is Postgres-backed; the relay feeds that queue.** The relay transforms each
`rawSequencedEvent` into the JSON shape above and `SendMessage`s it to the
per-projection EventCollector SQS queue — reusing the existing SQS decode/project
handler untouched. (Rejected: invoking the entry point with a synthetic
DynamoDB-stream event — brittle shape-mimicry vs. the clean SQS body the SQS
channel already expects.)

### What the relay does NOT need to do: cross-plugin SNS

**Confirmed from code** (`DcbEventLog_Operations.res:129-132`): the append op runs
`Ops.storage.append(...)` then immediately `await publishToEventTopic(...)` —
i.e. the **cross-plugin SNS publish lives inside `DcbEventLog.append()`, not in
the stream/EventCollector**. The EventCollector does no SNS publishing (its
`eventTopics` are deploy-time config only). So when the DCB command Lambda runs on
Postgres (storage swapped to `DcbEventLogStorage_Postgres`, `DcbEventLog_Operations`
unchanged), cross-plugin SNS fan-out **happens automatically, backend-independent**.

The DynamoDB stream drives **only the within-plugin EventCollector** (read models,
StateViewSlices, automations, side-effects). That is the *sole* thing Postgres
breaks and the *sole* job of the relay. This resolves open decision #4 below.

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
- ✅ **#4 SNS fan-out** — NOT the relay's concern. Cross-plugin SNS is
  append-driven (`DcbEventLog.append` → `publishToEventTopic`) and survives the
  storage swap. The relay feeds the within-plugin EventCollector SQS queue only.

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
| B2.0 | ✅ **Done (2026-07-05).** Resolved decisions #2 (`id` = `derivePartitionKey(partitionTag, tags)`) and #4 (SNS is append-driven, not the relay's job; relay feeds the within-plugin `EventCollectorChannel.SQS` queue). |
| B2.1 | `DcbEventLogStorage_Postgres_Runtime` + `DcbCommandTopicEntryPoint.mjs` Postgres branch (mirrors the landed EventLog work) |
| B2.2 | `PgChangeFeedRelay` runtime: `drain` → transform (reuse `derivePartitionKey`) → SQS send; unit-test the transform against a golden `{id, meta, event}` EventCollector body |
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
