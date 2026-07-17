# AWS Adapters — Broad Correctness, Consistency, Performance & Cost Review

> Date: 2026-05-10
> Companion to: [dcb-dynamodb-consistency-check.md](./dcb-dynamodb-consistency-check.md), [aggregate-command-handling-review.md](./aggregate-command-handling-review.md), [appsync-resolver-js-as-strings.md](./appsync-resolver-js-as-strings.md), [done/aws-runtime-builders-review.md](./done/aws-runtime-builders-review.md)

## Plans

Findings are grouped into three execution plans by severity:

- **Critical** (6 items) → [`docs/plans/Backlog/aws-adapters-critical-fixes.md`](../plans/Backlog/aws-adapters-critical-fixes.md). Working bugs, security blockers, and runtime crashes latent in code that ships today.
- **Major** (38 items) → [`docs/plans/Backlog/aws-adapters-major-fixes.md`](../plans/Backlog/aws-adapters-major-fixes.md). Six workstreams: silent-data-loss elimination, cost capping, hardening (encryption/IAM/DLQ), operational sharp edges, observability, and architectural followups.
- **Minor & Nit** (~50 items + 2 cross-cutting) → [`docs/plans/Backlog/aws-adapters-minor-fixes.md`](../plans/Backlog/aws-adapters-minor-fixes.md). Themed cleanup bundles (Util_* helpers, QueryDb polish, CommandTopic/EventCollector polish, framework hygiene, etc.).

The plans are ordered for execution; each plan references the others as siblings.

## Scope

This review covers the AWS adapters under [`reventless/aws/src/adapter/`](../../reventless/aws/src/adapter/) that have **not** already been audited in a dedicated analysis. The DCB DynamoDB append path, the Aggregate command-handling path (EventLog DynamoDB / CommandTopic SQS-FIFO / EventTopic-DynamoDbStream), AppSync resolver mechanics, runtime builder structure, and Lambda layer/bundling are each covered in their own documents — issues found there are **not** repeated below.

For each finding the table at the end gives a deterministic execution order combining severity, blast radius, and effort. Section numbering is by adapter family for traceability; the priority table re-orders.

**Files reviewed (not previously audited):**

| Adapter family | Files |
|---|---|
| CommandTopic | [`CommandTopicChannel_SQS.res`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS.res), [`_Sync.res`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Sync.res), [`_Async.res`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Async.res), [`_Helpers.res`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_Helpers.res), [`CommandTopicRemoteChannel_SQS.res`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicRemoteChannel_SQS.res) |
| EventCollector | [`_DynamoDbStream*.res`](../../reventless/aws/src/adapter/EventCollector/), [`_SQS*.res`](../../reventless/aws/src/adapter/EventCollector/) |
| EventTopic (SNS) | [`EventTopicPublisher_SNS.res`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_SNS.res), [`_FIFO.res`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_SNS_FIFO.res), [`_Runtime.res`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_SNS_Runtime.res) |
| QueryDb / QueryEngine | [`QueryDbStorage_DynamoDb*.res`](../../reventless/aws/src/adapter/QueryDb/), [`QueryEngine_DynamoDb.res`](../../reventless/aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res), [`QueryInterceptor_Lambda.res`](../../reventless/aws/src/adapter/QueryDb/QueryInterceptor_Lambda.res) |
| Task | [`TaskBucket_S3*.res`](../../reventless/aws/src/adapter/Task/) |
| Cloner | [`ClonerRunner_Fargate*.res`](../../reventless/aws/src/adapter/Cloner/) |
| Counter | [`CounterHandler_DynamoDbStream*.res`](../../reventless/aws/src/adapter/Counter/) |
| StateTopic / EventLogSubscription | [`StateTopic_AppSync.res`](../../reventless/aws/src/adapter/StateTopic/StateTopic_AppSync.res), [`EventLogSubscription_AppSync.res`](../../reventless/aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res) |
| Heartbeat / ScheduledPublisher | [`HeartbeatRunner_CloudWatchEvents.res`](../../reventless/aws/src/adapter/Heartbeat/HeartbeatRunner_CloudWatchEvents.res), [`ScheduledPublisher_CloudWatchEvents*.res`](../../reventless/aws/src/adapter/ScheduledPublisher/) |
| MCP | [`MCP_Lambda.res`](../../reventless/aws/src/adapter/Mcp/MCP_Lambda.res) |
| Api | [`AppSync_EventsApi.res`](../../reventless/aws/src/adapter/Api/AppSync_EventsApi.res), [`AppSync_Resolver_*.res`](../../reventless/aws/src/adapter/Api/), [`CommandSubscriptionResolvers_AppSync.res`](../../reventless/aws/src/adapter/Api/CommandSubscriptionResolvers_AppSync.res), [`Platform_UIDefinitions_Lambda.res`](../../reventless/aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res) |
| CommandGenerator | [`CommandGeneratorResolvers*.res`](../../reventless/aws/src/adapter/CommandGenerator/), [`InboundTranslationResolvers_AppSync.res`](../../reventless/aws/src/adapter/CommandGenerator/InboundTranslationResolvers_AppSync.res) |

---

## 1. CommandTopic (non-FIFO + Sync/Async + RemoteChannel)

The FIFO dispatch path was reviewed in [aggregate-command-handling-review.md](./aggregate-command-handling-review.md). The findings here apply to the surrounding files only.

### 1.1 — **Critical, Correctness** — receipt-handle / parsed-body mispairing
[`CommandTopicChannel_SQS_Runtime.res:7-21`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res#L7-L21). The handler builds two parallel arrays:

```rescript
let jsons = records->Array.filterMap(record => …)  // drops parse failures
let topicItems =
  records->Array.map(record => record.receiptHandle)
  ->Array.zip(jsons)
```

`Array.zip` truncates to the shorter input. If record `N` fails JSON parse, every subsequent receipt handle is paired with the **wrong** body: handle `N+1` zips with `jsons[N]` (which was record `N+2`'s body), and the trailing handle is silently dropped from the delete batch. End result: a successful command is reported via the wrong handle, the *bad* record is not retried (its handle was just deleted), and the surplus tail handle remains visible until the SQS visibility timeout, then redelivers — but its body has just been processed under another handle's identity. This corrupts both the success-path and the DLQ-redrive-path.

**Fix:** combine parse + handle pairing into a single `Array.filterMap` returning `(handle, json)` together, or fail the entire batch on parse error.
**Effort:** Tiny.

### 1.2 — **Major, Correctness** — non-FIFO CommandTopic has no per-aggregate ordering
[`CommandTopicChannel_SQS.res:42-55`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS.res#L42-L55). A standard SQS queue provides no ordering and no dedup. `Aggregate_Callback` relies on FIFO `MessageGroupId` for "commands for the same aggregate are dispatched serially" — that's what bounds the OCC retry budget. With this variant, two consumers concurrently process commands for the same aggregate; both replay-decide-append, hit OCC conflict, and after `maxConflictRetries=3` × `maxReceiveCount=5` commands DLQ. There is no header comment documenting "use only for stateless command processors."

**Fix:** delete the non-FIFO variant if no caller actually needs it; otherwise add a deploy-time guard preventing wiring to an Aggregate.
**Effort:** Tiny (delete) / Small (guard).

### 1.3 — **Major, Correctness** — `_Sync` registration race
[`CommandTopicChannel_SQS_Sync.res:22, 60-75`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Sync.res#L22). `handleCmdsRef` is a module-level `ref<option<…>>` populated by `handleChannelEvent` and read by `publishJsonsAndWait`, both wired through `Pulumi.Output.apply` chains. Initialization order is not deterministic. The fall-back path (`None => sendToSqs + Pending`) is described as "for PerAggregate where resolver and handler are in separate Lambdas" but in reality also fires on Single during the wiring race window.

**Fix:** distinguish "single-process inline" from "remote dispatch" at deploy-time via a flag, not a runtime ref.
**Effort:** Small.

### 1.4 — **Minor, Correctness** — FIFO sends rely on `contentBasedDeduplication`
[`Util_SQS_Runtime.res:33-34, 60-69`](../../reventless/aws/src/util/Util_SQS_Runtime.res). `sendFifoMessage` and `makeBatchEntryFifo` never set `messageDeduplicationId`. With `contentBasedDeduplication=true` SQS hashes the body — but a transient retry (`Effect.retry(SQS_Error.sendRetrySchedule)`) can collide with a *previous* send within the 5-minute window if the body is byte-identical, silently dropping the resend. Bodies include `meta.msgId` and `meta.time`, which usually differ — but the design relies on accidental variation rather than explicit dedup.

**Fix:** set `messageDeduplicationId = meta.msgId` (already a UUID) explicitly.
**Effort:** Tiny.

### 1.5 — **Minor, Performance** — `Stream.grouped(10)` underuses the parallel batcher
[`CommandTopicChannel_SQS_FIFO.res:39-50`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_FIFO.res#L39-L50) and siblings. Producers pre-chunk to 10 then call `publishJsons` sequentially per group, even though `sendMessagesParallel` already handles the 10-msg + 256 KB cap *and* parallelises within a group. Tiny payloads pay extra round-trips.

**Fix:** raise the group size (e.g. 256) or stream straight into `publishJsons` and let the batcher slice.
**Effort:** Small.

### 1.6 — **Minor, Operational** — vacuous `arnEquals` on queue policy
[`CommandTopicChannel_Helpers.res:30-32`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_Helpers.res). `aws:SourceArn = lambdaArn` only matches when a service-of-service push sets that header; a generic `sqs:SendMessage` from any IAM principal is unconstrained. The condition reads strict but does nothing.

**Fix:** add `Deny *` plus `Allow` for the specific sender role, or drop the misleading condition.
**Effort:** Small.

---

## 2. EventCollector (DynamoDbStream + SQS variants)

### 2.1 — **Critical, Correctness** — no `batchItemFailures` on stream / SQS event collectors
[`EventCollectorChannel_DynamoDbStream_Runtime.res:6-19`](../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res), [`EventCollectorChannel_SQS_Runtime.res:36-45`](../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res). Handlers return a single Effect over the whole batch. A poison record fails the entire invocation, redelivering the full shard window (DDB Streams) or all 10 SQS records, forcing N× projection re-application. The standard ESM pattern (`functionResponseTypes: ["ReportBatchItemFailures"]`) lets Lambda return only the failing `SequenceNumber` / `messageId` so the rest advances. Neither path uses it. There is also no `DestinationConfig.OnFailure` configured; after `MaximumRetryAttempts` poison events vanish silently.

**Fix:** thread per-record success status through `handleEvents`; return `{batchItemFailures: […]}` from the Lambda; configure on-failure DLQ on the ESM.
**Effort:** Medium.

### 2.2 — **Major, Correctness** — DDB-stream filter silently drops `REMOVE` and key-only records
[`EventCollectorChannel_DynamoDbStream_Runtime.res:6-19`](../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res). `filterMap` discards records where `eventSource ≠ "aws:dynamodb"` *and* records without `NewImage`. If the source table's `StreamViewType` is misconfigured (`KEYS_ONLY` or `OLD_IMAGE`), the EventCollector silently processes nothing and projections never update. There is no warning, no deploy-time validation.

**Fix:** log a warning when a record with a non-trivial `eventName` is dropped; assert at deploy-time that the table's stream is `NEW_IMAGE` or `NEW_AND_OLD_IMAGES`.
**Effort:** Small.

### 2.3 — **Major, Correctness** — non-FIFO EventCollector queue is unordered for stateful projections
[`EventCollectorChannel_SQS.res:44`](../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_SQS.res). SNS→SQS fan-out is unordered. ReadModels using `Set` are tolerant; ReadModels using `Update` against prior state silently corrupt when two events for the same entity arrive out of order. There is no documentation of the caveat at the file head.

**Fix:** document the ordering caveat or add a deploy-time guard binding the variant to order-independent projections only.
**Effort:** Small (doc) / Medium (guard).

### 2.4 — **Major, Operational** — shared platform-wide DLQs collapse observability
[`Util_DeadLetterQueue.res:7-35`](../../reventless/aws/src/util/Util_DeadLetterQueue.res). Two single shared DLQs (one standard, one FIFO) collect poison messages from every CommandTopic *and* every EventCollector. The handler is `console.error("DEAD LETTER ITEM:", JSON.stringify(event))` with no metric, no alarm, no archive. A flooding EventCollector masks unrelated CommandTopic poison events.

**Fix:** per-component DLQs (or per-component-type at minimum); CloudWatch metric on each receipt; 14-day retention; optional S3 archive.
**Effort:** Medium.

### 2.5 — **Major, Correctness** — `EventCollectorChannel_SQS_FIFO` 30 s visibility too short
[`EventCollectorChannel_SQS_FIFO.res:22`](../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_SQS_FIFO.res#L22) (`// TODO fix timeout`). 30 s is shorter than the worst-case projection time; the message reappears mid-processing, a second consumer reads it, and FIFO's "exactly-once-per-group" promise is silently downgraded to "idempotent-or-corrupt."

**Fix:** raise to ≥ Lambda timeout × 6 (the convention used elsewhere — 180 s).
**Effort:** Tiny.

### 2.6 — **Minor, Operational** — DDB-stream ESM has no parallelism / batching knobs
[`Util_EventSourceMapping.res:11-22`](../../reventless/aws/src/util/Util_EventSourceMapping.res). Defaults: `parallelizationFactor=1`, `batchSize=100`, `batchWindow=0`, `startingPosition: LATEST`. Hot aggregates serialise on a single shard; LATEST means redeploys lose any in-flight stream records during the detach/attach window.

**Fix:** expose `parallelizationFactor` / `batchSize` / `maxBatchingWindowInSeconds` knobs; default `parallelizationFactor=10`. Long-term: seed read models from EventLog directly on cold start instead of trusting LATEST.
**Effort:** Small (knobs) / Medium (seed-from-log).

### 2.7 — **Minor, Correctness** — `Array.getUnsafe(0)` drops sibling resources
[`EventCollectorChannel_DynamoDbStream.res:36`](../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream.res), [`EventCollectorChannel_SQS.res:73`](../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_SQS.res), [`_FIFO.res:51`](../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_SQS_FIFO.res). All three carry `// FIXME` comments next to `outputs.resources->Array.getUnsafe(0)`. EventTopic outputs with multiple resources (e.g. SNS + DLQ pair) silently exclude the others from the IAM grant.

**Fix:** flatten over all resources.
**Effort:** Tiny.

### 2.8 — **Minor, Operational** — `enqueueEvent` doesn't reuse retry/classify logic
[`EventCollectorChannel_SQS_Runtime.res:69-89`](../../reventless/aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res). Calls `Util_SQS_Runtime.sendMessage` directly (no retry on transient SQS hiccups). Compare with `Util_SQS_Runtime.send` which wraps in `Effect.retry(SQS_Error.sendRetrySchedule)` (10 attempts, exponential-jittered). Tasks/Schedulers/external-input adapters that route through `enqueueEvent` see transient SQS failures bubble straight to callers.

**Fix:** route through `Util_SQS_Runtime.send`.
**Effort:** Small.

---

## 3. EventTopic — SNS publishers

The DynamoDbStream variant of EventTopic is reviewed in `aggregate-command-handling-review.md`. The SNS variants are different beasts.

### 3.1 — **Major, Correctness** — non-transactional dual-write outbox for cross-plugin events
[`EventTopicPublisher_SNS.res:7`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_SNS.res), [`EventTopicPublisher_SNS_FIFO.res:3`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_SNS_FIFO.res). Unlike the DynamoDB-Streams variant (transactional outbox tied to the EventLog), the SNS variant is a non-transactional dual write: app code writes to the EventLog *and then* publishes to SNS. If SNS publish fails after the DDB commit, the event is durable but never reaches subscribers. `Plugin_ExtensionPoint_Builder` (the cross-plugin event broadcaster) is wired through SNS — so cross-plugin events can be lost silently.

**Fix:** treat ExtensionPoint events as a Streams subscriber (already-transactional) rather than a primary publisher; or implement an explicit outbox-with-sweeper.
**Effort:** Large.

### 3.2 — **Major, Performance / Cost** — no `PublishBatch` (10× round-trips and connection cost)
[`EventTopicPublisher_SNS_Runtime.res`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_SNS_Runtime.res). `publish` issues one `PublishCommand` per event. SNS `PublishBatch` accepts 10 messages per call; the helper does not use it. The current `Stream.grouped(10) → Promise.all` chain still issues 10 concurrent `PublishCommand`s, that's 10× API request count, 10× TLS cost, and a higher chance of throttling.

**Fix:** add `PublishBatch` to `SNS_Helpers`.
**Effort:** Small.

### 3.3 — **Major, Cost** — SNS fan-out is ~10× DDB-Streams fan-out per subscriber
SNS publish $0.50/M (FIFO $1.00/M) + per-subscriber delivery $0.40/M (SQS) = ~$2.50/M for 5 SQS subscribers. DDB-Streams reads are $0.20/M and unmetered per subscriber. Platforms with many ExtensionPoints + high event throughput see SNS dominate AWS bill.

**Fix:** documentation of cost model; prefer DDB-Streams fan-out where applicable.
**Effort:** Tiny (doc) / Large (architectural shift).

### 3.4 — **Major, Operational/Security** — SNS topics created without KMS encryption
[`EventTopicPublisher_SNS.res:7-14`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_SNS.res), [`EventTopicPublisher_SNS_FIFO.res:5-11`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_SNS_FIFO.res). No `kmsMasterKeyId` set — messages stored in plaintext at rest. Compliance issue (SOC 2 / HIPAA / PCI) for any deployment carrying sensitive event payloads.

**Fix:** opt into AWS-managed `aws/sns` KMS key by default; expose override.
**Effort:** Tiny.

### 3.5 — **Minor, Correctness** — `Promise.all` aborts on first publish failure
[`EventTopicPublisher_SNS.res:32-36`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_SNS.res). On failure of message 6 of 10, the throw aborts the remaining 4. Producer cannot tell which messages published.

**Fix:** `Promise.allSettled` + per-message retry of failures (mirror `Util_SQS_Runtime.sendMessages`).
**Effort:** Small.

### 3.6 — **Minor, Operational** — FIFO SNS 300/s ceiling not in error classifier
[`SNS_Error.res`](../../reventless/aws/src/util/SNS_Error.res). Bursty event flows on FIFO SNS hit the 300/s ceiling with throttle messages that are not all matched by the current classifier; failures pass through as `Permanent` instead of `Transient`.

**Fix:** broaden the classifier; document the ceiling.
**Effort:** Tiny.

### 3.7 — **Minor, Operational** — `snsRegistry: Set.t<string>` is a deploy-time mutable global
[`EventTopicPublisher_SNS.res:5`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_SNS.res). Mutable module-level state used by a Phase 5 deploy hook. Test isolation broken; preview/up cycles accumulate; runtime reads see an empty registry.

**Fix:** thread a deploy-time registry through Pulumi state, or document its lifecycle clearly.
**Effort:** Small.

---

## 4. QueryDb / QueryEngine

### 4.1 — **Major, Correctness** — `QueryEngine` swallows DynamoDB errors as `[]`
[`QueryEngine_DynamoDb.res:106-110`](../../reventless/aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res#L106-L110), [`:138-142`](../../reventless/aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res#L138-L142). Both `query` and `scan` log the error and return `[]`. Translation slices, automation processes, and admin tools that compose on top of QueryEngine cannot distinguish "no results" from "DynamoDB threw." Net effect on a transient throttle: ghost decisions ("entity does not exist → create it"). Same class of silent-failure bug as the historical `appendUnconditional` fence-bypass.

**Fix:** propagate errors as `Result.Error` (or throw); audit every caller. Provide an explicit opt-in `treatErrorAsEmpty` flag for callers that genuinely want it.
**Effort:** Small (mechanical) — but **wide blast radius** because every read path is affected.

### 4.2 — **Major, Cost** — `consistentRead: true` hardcoded on every QueryDb load
[`QueryDbStorage_DynamoDb_Runtime.res:8-40`](../../reventless/aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res). 2× RCU and added latency per call. Read-models are projections — they're already eventually consistent vs. the EventLog. Strong reads only matter for the rare "save-then-load in the same handler" case.

**Fix:** make `consistentRead` a per-call parameter, default `false`.
**Effort:** Small.

### 4.3 — **Major, Performance / Cost** — `Util_DynamoDb_Runtime.batchWriteWithRetries` has no backoff
[`Util_DynamoDb_Runtime.res:177-203`](../../reventless/aws/src/util/Util_DynamoDb_Runtime.res). The recursive `attempt(retry, requests)` loop immediately re-issues `unprocessedItems` with no delay. The outer `Effect.retry(retrySchedule)` only fires on *thrown* errors — DynamoDB returns `200 OK` with a non-empty `unprocessedItems`, which is not an error, so the schedule never fires. Under partition throttling this becomes a tight loop amplifying WCU pressure.

**Fix:** insert exponential backoff between attempts (50 ms × 2^retry, capped ~2 s); cap retries at 8; emit a metric/log on `retry > 3`.
**Effort:** Tiny.

### 4.4 — **Major, Performance / Cost** — `writeMultiple` unbounded concurrency
[`QueryDbStorage_DynamoDb_Runtime.res:123-144`](../../reventless/aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L123-L144). `Effect.all(batchEffects, {"concurrency": "unbounded"})` fans out every 25-item chunk simultaneously. A 1000-item projection issues 40 parallel `BatchWriteItem` calls against the same table from one Lambda — easily saturating per-table WCU.

**Fix:** cap concurrency (`{"concurrency": 4}` or 8); expose as a config knob.
**Effort:** Tiny.

### 4.5 — **Major, Cost / Performance** — `QueryEngine.scanByTableName` is unbounded
[`QueryEngine_DynamoDb.res:114-144`](../../reventless/aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res#L114-L144). Empty `filterConfigs` + generous `limit` → full-table scan, paginated to completion, materialised by `Stream.runCollect`. No segment parallelism, no max-page ceiling, no warning. A UI or admin tool that hits `scan(~filterConfigs=[])` against a multi-million-row table will burn read capacity without warning.

**Fix:** ceiling on max-page or max-item; `WARN` log when scans return >1 000 items; consider gating behind a feature flag.
**Effort:** Small.

### 4.6 — **Minor, Correctness** — `count`'s `UpdateCommand` reads hardcoded `"count"` field
[`QueryDbStorage_DynamoDb_Runtime.res:187-225`](../../reventless/aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L187-L225). The `ReturnValues: UPDATED_NEW` branch reads `attributes.count` while the field name passed in is `fieldName`. Any caller using a non-default field name silently surfaces `NotCountedOnStorage("Invalid updateOutput in count")` even though the write succeeded.

**Fix:** read `attributes->getIntAttribute(fieldName)`. Also apply `DynamoDb_Error.retrySchedule` instead of generic `messageFromUnknown`.
**Effort:** Tiny.

### 4.7 — **Minor, Correctness** — `saveMode.Any` and `Overwrite` collapse
[`QueryDbStorage_DynamoDb_Runtime.res:63-95`](../../reventless/aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L63-L95). The constructor exists but produces identical behaviour. If `Any` was meant for "upsert without clobber on stale state," the implementation is missing.

**Fix:** delete the variant or implement `Any` with a `version` condition.
**Effort:** Small.

### 4.8 — **Minor, Performance** — JSON stringify/parse round-trip per item
[`QueryDbStorage_DynamoDb_Runtime.res:33-37`](../../reventless/aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L33-L37) and [`QueryEngine_DynamoDb.res:105, 137`](../../reventless/aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res#L105). Each item is `js->JSON.stringifyAny->Option.getOr("")->JSON.parseOrThrow`. CPU + GC pressure per item; the SDK already returns a marshalled JS object.

**Fix:** `Obj.magic` or `JSON.Encode.object` directly.
**Effort:** Tiny.

### 4.9 — **Minor, Cost** — `streamViewType=NEW_AND_OLD_IMAGES` always
[`QueryDbStorage_DynamoDbStream.res:27`](../../reventless/aws/src/adapter/QueryDb/QueryDbStorage_DynamoDbStream.res). Doubles per-record stream payload vs. `NEW_IMAGE`. Most consumers (Counter references, StateTopic_AppSync) only need `NEW_IMAGE`.

**Fix:** parameterise per QueryDb; default `NEW_IMAGE`; opt into both only where the consumer reads OldImage.
**Effort:** Small.

### 4.10 — **Minor, Correctness** — value-placeholder collision in filter expressions
[`QueryEngine_DynamoDb.res:32`](../../reventless/aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res#L32). `:${fieldName}${idx}` interpolates user-controlled field names into placeholder identifiers. DynamoDB allows only `[a-zA-Z0-9_]` in placeholder names; field names with `-`, `.`, or reserved characters produce a malformed expression and a hard 400.

**Fix:** sequential `:v0`, `:v1`, … placeholders; alias `#f0`, `#f1`, … on the attribute-name side too.
**Effort:** Tiny.

---

## 5. Task Bucket (S3)

### 5.1 — **Major, Operational/Security** — bucket has no encryption, versioning, or PublicAccessBlock
[`TaskBucket_S3.res:128-149`](../../reventless/aws/src/adapter/Task/TaskBucket_S3.res#L128-L149). `S3.Bucket.make` sets only `corsRules`. No SSE-S3/KMS, no versioning, no `PublicAccessBlock`. For a bucket carrying user uploads, this is below baseline.

**Fix:** enable SSE (S3 default, optional KMS); enable versioning; attach `BucketPublicAccessBlock` with all four flags `true`; lifecycle rule to expire non-current versions (30→90 d).
**Effort:** Small.

### 5.2 — **Major, Operational** — CORS allows any origin
[`TaskBucket_S3.res:132-145`](../../reventless/aws/src/adapter/Task/TaskBucket_S3.res#L132-L145). `allowedOrigins: ["*"]` permits any web origin to call `HEAD`/`GET`. Combined with the missing PublicAccessBlock, a leaked presigned URL is exploitable from any origin.

**Fix:** parameterise CORS; default to no cross-origin or to the platform's known UI hostnames.
**Effort:** Small.

### 5.3 — **Major, Cost / Performance** — Lambda subscribes to *every* object created/removed
[`TaskBucket_S3.res:11-15`](../../reventless/aws/src/adapter/Task/TaskBucket_S3.res#L11-L15). No prefix/suffix filter on the S3 notification. Every object change fires the Lambda; user code filters in-process, paying $0.005/10 k S3 events + Lambda invocation cost N×.

**Fix:** accept `~filterPrefix` / `~filterSuffix` parameters and pass through to S3 notification config.
**Effort:** Small.

### 5.4 — **Major, Correctness** — `Promise.all` partial failure abandons successful records
[`TaskBucket_S3_Runtime.res:1-11`](../../reventless/aws/src/adapter/Task/TaskBucket_S3_Runtime.res). S3 batches up to 10 records per invocation. `Promise.all([…])` rejects on the first failure, abandoning successful ones to be reprocessed via DLQ/retry. Without idempotency keys downstream, this produces duplicate commands.

**Fix:** `Promise.allSettled`; emit successful actions; report partial failure via batch-item-failure response.
**Effort:** Small.

### 5.5 — **Minor, Operational** — `Write` mode grants both Put and Delete
[`TaskBucket_S3.res:34-49`](../../reventless/aws/src/adapter/Task/TaskBucket_S3.res#L34-L49). Ingest buckets that should be append-only get delete privilege. Missing `s3:AbortMultipartUpload` allows orphan parts to accrue storage cost; no lifecycle rule auto-aborts them.

**Fix:** split `Write` (Put only) from `Delete` (Put+Delete); add `AbortMultipartUpload`; lifecycle rule auto-aborting incomplete multipart uploads after 7 d.
**Effort:** Small.

### 5.6 — **Minor, Correctness** — `decodeURIComponent` may double-decode keys
[`TaskBucket_S3_Runtime.res:6`](../../reventless/aws/src/adapter/Task/TaskBucket_S3_Runtime.res). S3 events encode space as `+`; `decodeURIComponent` does not decode `+`. Keys with literal spaces survive S3 transport as `+` and stay that way after decode, breaking key-equality comparisons.

**Fix:** replace `+` with space before `decodeURIComponent`, or document the constraint.
**Effort:** Tiny.

---

## 6. Cloner (Fargate)

### 6.1 — **Critical, Correctness** — `ClonerRunner_Fargate_Runtime.res` uses `Pulumi.Output.get` at runtime
[`ClonerRunner_Fargate_Runtime.res:21-22`](../../reventless/aws/src/adapter/Cloner/ClonerRunner_Fargate_Runtime.res#L21-L22). `taskDefinition->Pulumi.Output.get` is a deploy-time API. At Lambda runtime the binding is no longer a Pulumi.Output; this throws or returns `undefined`. The file is currently dead code (the inline JS in `ClonerRunner_Fargate.res:92-113` is what's deployed), but anyone enabling it will hit a runtime crash on first call.

**Fix:** delete the dead file *or* rewrite to read `process.env.TASK_DEFINITION_ARN` / `CLUSTER_ARN` (the env-var pattern the inline JS already uses).
**Effort:** Small.

### 6.2 — **Major, Correctness** — `RunTaskCommand` has no `clientToken` (no idempotency)
[`ClonerRunner_Fargate.res:100`](../../reventless/aws/src/adapter/Cloner/ClonerRunner_Fargate.res). ECS dedups `RunTask` invocations within a 10-minute window per `clientToken`. Without one, a Lambda retry (transient timeout, AppSync retry) launches **two** Fargate tasks. Each task incurs Fargate cost and may produce duplicate clones, corrupting the target environment.

**Fix:** derive `clientToken` from `ctx.identity.requestId` or hash of `restoreDateTime + user`.
**Effort:** Tiny.

### 6.3 — **Major, Operational** — No SecurityGroup, no `assignPublicIp` config
[`ClonerRunner_Fargate.res:103-104`](../../reventless/aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L103-L104). Falls back to VPC default security group (which may be over- or under-permissive). Private subnets without a NAT can't pull the image or call AWS APIs; `assignPublicIp` is unspecified, leaving behaviour subnet-dependent.

**Fix:** thread `securityGroupIds` and `assignPublicIp` through the maker.
**Effort:** Small.

### 6.4 — **Major, Correctness** — Lambda execution role uses AppSync principal
[`ClonerRunner_Fargate.res:194-198`](../../reventless/aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L194-L198). The execution role is constructed with `servicePrincipal=AWS.AppSync.principal`. Lambda execution roles must trust `lambda.amazonaws.com`. May be working accidentally because `makeWithDefaultPolicy` adds Lambda's principal regardless — needs verification.

**Fix:** verify the assume-role policy includes `lambda.amazonaws.com`. Split into `ClonerLambdaExecutionRole` and `ClonerAppSyncInvokeRole` for clarity.
**Effort:** Small.

### 6.5 — **Minor, Cost** — `cpu / memory` hardcoded; no log group retention
[`ClonerRunner_Fargate.res:154-165`](../../reventless/aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L154-L165). 1 vCPU + 4 GB hardcoded; auto-created log group never expires.

**Fix:** parameterise CPU/memory; pre-create log group with `retentionInDays: 30`.
**Effort:** Tiny.

### 6.6 — **Minor, Operational** — Inline JS Lambda is unmaintainable
[`ClonerRunner_Fargate.res:92-113`](../../reventless/aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L92-L113). 22 lines of JS in a template literal. The ReScript runtime (6.1) exists side-by-side and is dead. Two implementations can drift; the JS version has no tests; environment variables stringly coupled.

**Fix:** consolidate on the `_Runtime.res` file (after fixing 6.1) via `RuntimeEnvironment_Lambda.makeFromCodeAsset`, or extract the JS to a sibling `.mjs` asset.
**Effort:** Medium.

---

## 7. Counter

### 7.1 — **Major, Cost / Operational** — `targets` and `targetRefs` grow unbounded
[`CounterHandler_DynamoDbStream_Runtime.res:16-17`](../../reventless/aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res#L16-L17). Every successful `addToCounterTarget` `list_append`s to `targets` and `targetRefs` while bumping `count` and `total`. The arrays are never compacted. At ~30 bytes per UUID `targetRef`, the 400 KB DynamoDB item limit caps a counter at ~13 k increments, after which writes fail with `ValidationException: Item size has exceeded the maximum allowed size`.

**Fix:** split history into a separate table (`partition=counterId, sort=targetRef`), or drop history entirely and rely on the events stream for audit. Document the cap if neither is feasible.
**Effort:** Medium.

### 7.2 — **Major, Performance / Cost** — `NOT contains(#targetRefs, :targetRef)` is O(n) per write
[`CounterHandler_DynamoDbStream_Runtime.res:32`](../../reventless/aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res#L32). DynamoDB evaluates `contains` on a list by linear scan; WCU charges scale with item size. At 10 k entries, a single update costs ~10 WCU instead of ~1.

**Fix:** combine with 7.1 — maintain a separate "seen refs" table with a single-key check.
**Effort:** Medium (combines with 7.1).

### 7.3 — **Major, Correctness** — references `MODIFY` events silently dropped
[`CounterHandler_DynamoDbStream_Runtime.res:86-89`](../../reventless/aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res#L86-L89). `OLD_AND_NEW` images on a reference row (i.e., update of `inc`) are logged "ignoring duplicate id" and skipped. If references are ever updated post-insert, the count silently desyncs.

**Fix:** decide policy explicitly. If references are immutable (write-once), assert and document. If mutable, compute `delta = newInc - oldInc` and apply.
**Effort:** Small.

### 7.4 — **Minor, Correctness** — schema-decode errors fall back to `inc=1`
[`CounterHandler_DynamoDbStream_Runtime.res:81-84`](../../reventless/aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res#L81-L84). `exception _err → inc=1` hides upstream bugs (event schema drift, malformed projections) and produces wrong counts.

**Fix:** log the decode error at WARN with offending JSON; fail-closed (skip record + DLQ) rather than silent default.
**Effort:** Tiny.

### 7.5 — **Minor, Correctness** — no retry-with-tolerance on `ConditionalCheckFailedException`
[`CounterHandler_DynamoDbStream_Runtime.res:11-33`](../../reventless/aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res#L11-L33). Idempotent re-delivery throws unhandled `ConditionalCheckFailedException`; the stream retries forever (until bisect-on-error narrows the bad record), then silently advances.

**Fix:** swallow the exception explicitly as success-via-idempotency; log at INFO.
**Effort:** Tiny.

### 7.6 — **Minor, Operational** — `handlerConfigJson` string-replace injection
[`CounterHandler_DynamoDbStream.res:35-39`](../../reventless/aws/src/adapter/Counter/CounterHandler_DynamoDbStream.res#L35-L39). `String.replace("\"countsStreamArn\":\"\"", "…")` is fragile to whitespace/quote drift. If the empty template string changes, the replace silently no-ops.

**Fix:** use `Output.all` to gather values and build the JSON atomically.
**Effort:** Tiny.

---

## 8. StateTopic_AppSync / EventLogSubscription_AppSync

### 8.1 — **Major, Correctness** — silent message loss on AppSync 5xx
[`StateTopic_AppSync.res:73-89`](../../reventless/aws/src/adapter/StateTopic/StateTopic_AppSync.res#L73-L89), [`EventLogSubscription_AppSync.res:62-82`](../../reventless/aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L62-L82). Both handlers `console.error` on `!res.ok` and continue. Lambda returns success, the source (DDB stream / SQS) deletes/advances, and the message is **lost** to UI subscribers. No `DestinationConfig.OnFailure`, no batch-item-failure response.

**Fix:** track per-record failures, throw to fail the batch (DDB stream) or return `batchItemFailures` (SQS); wire `DestinationConfig.OnFailure` to a DLQ.
**Effort:** Small.

### 8.2 — **Major, Operational** — AppSync Events 240 KB subscription payload limit unenforced
Both `StateTopic_AppSync` and `EventLogSubscription_AppSync` publish whole event payloads through AppSync Events. AppSync drops messages exceeding 240 KB silently. Large events (PDF metadata, image manifests, bulk imports) vanish from UI subscribers.

**Fix:** size check before publish; truncate to a summary (`{id, type, truncated: true}`) and trigger a fetch on the client side; or reject at publisher with an explicit error.
**Effort:** Small.

### 8.3 — **Major, Performance / Cost** — per-record HTTP fetch (no batching)
[`StateTopic_AppSync.res:75-84`](../../reventless/aws/src/adapter/StateTopic/StateTopic_AppSync.res#L75-L84), [`EventLogSubscription_AppSync.res:62-82`](../../reventless/aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L62-L82). One fetch + SigV4 signing per record. AppSync `/event` accepts arrays (`events: [...]`) and bills per request. Up to 100 records (DDB Streams) or 10 (SQS) become 100/10 requests instead of 1.

**Fix:** group by channel and POST once per batch.
**Effort:** Tiny.

### 8.4 — **Major, Correctness** — SigV4 amzDate slicing is brittle
[`StateTopic_AppSync.res:59`](../../reventless/aws/src/adapter/StateTopic/StateTopic_AppSync.res#L59), [`EventLogSubscription_AppSync.res:46`](../../reventless/aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L46). `now.toISOString().replace(/[:\-]|\..../g, "").slice(0, 15) + "Z"` produces `YYYYMMDDTHHMMSSZ` *only if* `toISOString` returns exactly three milliseconds digits. If a future Node renders four (or no) ms digits, the slice desynchronises with `dateStamp` and AWS rejects with `SignatureDoesNotMatch`.

**Fix:** build amzDate explicitly: `dateStamp + "T" + hh + mm + ss + "Z"` from `Date` getters. Factor into a shared SigV4 helper (the same code is duplicated in both files).
**Effort:** Tiny.

### 8.5 — **Minor, Operational** — visibility timeout < 6× Lambda timeout
[`EventLogSubscription_AppSync.res:101, 237`](../../reventless/aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L101). 60 s SQS visibility against a 30 s Lambda timeout (2× ratio). AWS guidance is ≥ 6×. A Lambda that approaches its 30 s timeout will trigger SQS redelivery before completion → duplicate AppSync events to UI clients.

**Fix:** raise SQS visibility to ≥ 180 s.
**Effort:** Tiny.

### 8.6 — **Minor, Performance / Cost** — SNS-to-SQS subscription has no filter policy
[`EventLogSubscription_AppSync.res:148`](../../reventless/aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L148). Every event fans to every subscriber's queue + Lambda invocation, regardless of subscriber interest. AppSync client-side filters can mitigate at delivery time but Lambda cost is already burned.

**Fix:** optional `filterPolicy` parameter (e.g. on `eventType`, aggregate name).
**Effort:** Small.

### 8.7 — **Minor, Correctness** — fetch with no `AbortController` timeout
Both handlers call `fetch(...)` with no timeout. A stuck connection blocks until Lambda timeout (30 s), then SQS/DDB redrives.

**Fix:** wrap with `AbortController` + 5–10 s timeout.
**Effort:** Tiny.

### 8.8 — **Minor, Operational** — `logs:*` is too broad
[`StateTopic_AppSync.res:137-141`](../../reventless/aws/src/adapter/StateTopic/StateTopic_AppSync.res#L137-L141), [`EventLogSubscription_AppSync.res:181`](../../reventless/aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L181), [`Platform_UIDefinitions_Lambda.res:86`](../../reventless/aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L86). Grants `logs:*` cluster-wide; only `CreateLogGroup`, `CreateLogStream`, `PutLogEvents` are needed.

**Fix:** narrow to the three actions; tighten resource scope.
**Effort:** Tiny.

---

## 9. Heartbeat / ScheduledPublisher (CloudWatch Events)

### 9.1 — **Critical, Correctness** — `Daily(hour, minute)` cron expression is invalid
[`ScheduledPublisher_CloudWatchEvents_Runtime.res:19`](../../reventless/aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L19). Emits `cron(M H * * * *)`. CloudWatch Events cron requires *exactly one* of day-of-month and day-of-week to be `?`. AWS rejects with `Cron expressions must have exactly one of D or DOW must be ?`. The `Daily` schedule simply does not work.

**Fix:** `Daily(h, m) => cron(${m} ${h} * * ? *)`.
**Effort:** Tiny.

### 9.2 — **Critical, Correctness** — `role.arn->Pulumi.Output.get` at Lambda runtime
[`ScheduledPublisher_CloudWatchEvents_Runtime.res:42`](../../reventless/aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L42). `Pulumi.Output.get` is a deploy-time extraction. The runtime function `createSchedule` is called from a Lambda creating CloudWatch rules dynamically — the role binding is no longer a Pulumi.Output. Same dead-code risk pattern as Cloner 6.1.

**Fix:** thread role ARN through environment variables; read `process.env.SCHEDULER_ROLE_ARN` in the runtime.
**Effort:** Small.

### 9.3 — **Major, Correctness** — `PutRule` + `PutTargets` not atomic
[`ScheduledPublisher_CloudWatchEvents_Runtime.res:37-63`](../../reventless/aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L37-L63). PutRule succeeds, PutTargets fails (throttling, network) → ghost rule with no targets, accruing `events.RuleEvaluations` charges and never firing. No rollback.

**Fix:** wrap PutTargets in try/catch; on failure call `DeleteRuleCommand`. Add `Effect.retry`.
**Effort:** Small.

### 9.4 — **Major, Correctness / Cost** — `deleteSchedule` partial failure window
[`ScheduledPublisher_CloudWatchEvents_Runtime.res:67-97`](../../reventless/aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L67-L97). RemoveTargets fails → `Effect.runPromise` throws, rule + targets stay. DeleteRule won't succeed while targets are attached.

**Fix:** treat `ResourceNotFoundException` from RemoveTargets as success; retry DeleteRule; surface as a periodic reaper for orphaned rules.
**Effort:** Small.

### 9.5 — **Major, Security** — `events:*` over-permission
[`ScheduledPublisher_CloudWatchEvents.res:16-22`](../../reventless/aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents.res#L16-L22). Grants `events:*` cluster-wide; only `PutRule`, `DeleteRule`, `PutTargets`, `RemoveTargets` are needed. A compromised runtime can manipulate any rule in the account.

**Fix:** narrow actions; restrict resource to `arn:aws:events:*:*:rule/<stack-prefix>-*`.
**Effort:** Tiny.

### 9.6 — **Major, Correctness** — `// FIXME` `Array.getUnsafe(0)` on queue resources
[`ScheduledPublisher_CloudWatchEvents_Runtime.res:36, 77`](../../reventless/aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L36). Multi-queue Schedulers silently target only the first queue.

**Fix:** create one EventTarget per queue, or assert single-queue at deploy time.
**Effort:** Small.

### 9.7 — **Critical, Correctness/Operational** — `resolvedResource.urn` carries an ARN by convention
[`HeartbeatRunner_CloudWatchEvents.res:55`](../../reventless/aws/src/adapter/Heartbeat/HeartbeatRunner_CloudWatchEvents.res#L55), [`ScheduledPublisher_CloudWatchEvents.res:43`](../../reventless/aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents.res#L43). The field name is `urn`; the value is an ARN by convention (cross-checked with `Util_SQS.findResolvedResource`). A Pulumi URN cannot match an IAM ARN; if the convention ever drifts the IAM grants silently fail to match. No type-level enforcement.

**Fix:** rename `urn → arn`, or wrap in a phantom-typed `Arn.t`. Add a deploy-time assert that the value starts with `arn:`.
**Effort:** Medium.

### 9.8 — **Minor, Security** — Lambda permission grants events principal without `sourceArn`
[`HeartbeatRunner_CloudWatchEvents.res:38-46`](../../reventless/aws/src/adapter/Heartbeat/HeartbeatRunner_CloudWatchEvents.res#L38-L46). Any rule in the account can invoke the heartbeat Lambda.

**Fix:** add `sourceArn: cloudwatchEventRule.arn->Pulumi.Output.asInput`.
**Effort:** Tiny.

### 9.9 — **Minor, Operational** — EventTarget creation inside `Pulumi.Output.apply`
[`HeartbeatRunner_CloudWatchEvents.res:75-85`](../../reventless/aws/src/adapter/Heartbeat/HeartbeatRunner_CloudWatchEvents.res#L75-L85). Resources created inside `apply` don't show up cleanly in the Pulumi resource graph; Pulumi warns about this pattern.

**Fix:** lift the EventTarget creation out of the apply via `arn->Pulumi.Output.asInput`.
**Effort:** Tiny.

### 9.10 — **Long-term** — migrate to EventBridge Scheduler
CloudWatch Events scheduled rules are deprecated in favor of EventBridge Scheduler ($1/M invocations). Scheduler offers `OneTimeSchedule`, `FlexibleTimeWindow`, native per-target retry/DLQ — addressing 9.3, 9.4, 9.6, and the `Single` semantic ambiguity for free.
**Effort:** Large.

---

## 10. MCP Lambda

### 10.1 — **Critical, Security** — JWT signature is not verified
[`MCP_Lambda.res:338-385`](../../reventless/aws/src/adapter/Mcp/MCP_Lambda.res#L338-L385). `decodeJwtClaims` is a `%raw` JS that base64url-decodes the payload and returns it. Authorisation in `dispatchTool` (line 399) reads `sub`, `cognito:username`, `cognito:groups` from this payload. The comment defers signature verification to "Lambda authorizer / API Gateway Cognito authorizer" — but the file's deploy-time placeholder shows a Lambda **Function URL**, where the only auth options are `AWS_IAM` or `NONE`. Neither verifies a JWT in the `Authorization` header. With `authType: None` (mentioned as suitable for development), an attacker forges any Cognito identity by base64-encoding a payload with arbitrary claims; per-tool ACLs are entirely bypassed.

**Fix:** before any production deploy, verify the JWT signature using `aws-jwt-verify` against the configured Cognito User Pool's JWKS. Cache JWKS, invalidate on `kid` rotation. Reject expired tokens, missing `aud`. Or place the function behind API Gateway with a Cognito authorizer.
**Effort:** Small.

### 10.2 — **Major, Cost / Security** — no rate limiting / abuse protection
[`MCP_Lambda.res:478-481`](../../reventless/aws/src/adapter/Mcp/MCP_Lambda.res#L478-L481). `rateLimitConfig` is declared as deploy-time intent but has no runtime enforcement. A noisy or malicious MCP client can flood `dispatchTool`, triggering the full backend pipeline per call.

**Fix:** per-identity sliding-window counter (DynamoDB / Redis); `reservedConcurrency` as a coarse cap.
**Effort:** Medium.

### 10.3 — **Major, Correctness/Operational** — `Stream.catchAll(... Stream.empty)` swallows DynamoDB errors
[`MCP_Lambda.res:211-213`](../../reventless/aws/src/adapter/Mcp/MCP_Lambda.res#L211-L213). On transient throttle, the stream is replaced by empty; the function returns "no events." Same pattern as QueryEngine 4.1 — callers cannot distinguish empty from error.

**Fix:** propagate the typed error.
**Effort:** Tiny.

### 10.4 — **Major, Performance / Cost** — `readDcbEventLogHistory` filters in memory after a broad query
[`MCP_Lambda.res:257-268`](../../reventless/aws/src/adapter/Mcp/MCP_Lambda.res#L257-L268). Calls `read(table)(~query=[], ~after?)` (empty query — fetches **all** events), then filters by tag value in app code. Hits scan pricing across many round-trips at scale.

**Fix:** push the entity-id tag into the query so DynamoDB filters server-side.
**Effort:** Small.

### 10.5 — **Minor, Cost** — `consistentRead: true` on every event-history read
[`MCP_Lambda.res:207`](../../reventless/aws/src/adapter/Mcp/MCP_Lambda.res#L207). 2× RCU for a browse use case where eventual is almost always acceptable.

**Fix:** parameterise `consistentRead`, default `false`.
**Effort:** Tiny.

### 10.6 — **Minor, Operational** — `correlationId` always passes `"unknown"`
[`MCP_Lambda.res:419`](../../reventless/aws/src/adapter/Mcp/MCP_Lambda.res#L419). `runEffect(None, ...)` strips request correlation through MCP → SQS → backend.

**Fix:** accept `correlationId` from request header, plumb through.
**Effort:** Tiny.

### 10.7 — **Minor, Correctness** — `extractEntityId` blindly takes URI last segment
[`MCP_Lambda.res:132-136`](../../reventless/aws/src/adapter/Mcp/MCP_Lambda.res#L132-L136). Fails on trailing slash (empty entityId), encoded slashes (`%2F`), and multi-param URI templates (collapses to the last param).

**Fix:** parse against the registered `uriTemplate`.
**Effort:** Small.

---

## 11. Api (AppSync) and CommandGenerator resolvers

### 11.1 — **Major, Operational** — IAM-only auth excludes browser clients
[`AppSync_EventsApi.res:31-32`](../../reventless/aws/src/adapter/Api/AppSync_EventsApi.res#L31-L32). `connectionAuthModes` and `defaultSubscribeAuthModes` are AWS_IAM. Browsers without a Cognito Identity Pool cannot subscribe.

**Fix:** add Cognito User Pool as a second auth provider for subscriber authentication.
**Effort:** Small (server) + Medium (client integration).

### 11.2 — **Major, Performance / Cost** — `Platform_UIDefinitions_Lambda` uses `Scan` with `contains`
[`Platform_UIDefinitions_Lambda.res:32-36`](../../reventless/aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L32-L36). `Scan` on a Plugin read-model with `contains(#status, :connected)` filter — a non-key filter applied after reading, so RCU is paid for every item in the table.

**Fix:** sparse GSI on `status` (only `Connected` rows); `Query` the GSI.
**Effort:** Small.

### 11.3 — **Major, Operational** — `Platform_UIDefinitions_Lambda` uncapped pagination
[`Platform_UIDefinitions_Lambda.res:28-39`](../../reventless/aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L28-L39). `do { … } while(exclusiveStartKey)` with no max-item ceiling. Pathological table → 30 s Lambda timeout returns partial result; >6 MB accumulation exceeds AppSync resolver response cap.

**Fix:** cap at e.g. 5 000 items + truncation header.
**Effort:** Small.

### 11.4 — **Major, Performance / Cost** — `CommandSubscriptionResolvers_AppSync` has no subscription filter
[`CommandSubscriptionResolvers_AppSync.res:22`](../../reventless/aws/src/adapter/Api/CommandSubscriptionResolvers_AppSync.res#L22). All connected clients receive every `onPlugin_Agg_Cmd` event regardless of which aggregate id they care about. AppSync charges per delivered subscription message — multiplier on N clients × M events.

**Fix:** generate `subscriptionFilter` on `id` from the request when callers have one. Make optional for command types without an id.
**Effort:** Small.

### 11.5 — **Major, Security** — `CommandGeneratorResolvers_AppSync` adds CloudWatch Events principal to AppSync-invoked Lambda
[`CommandGeneratorResolvers_AppSync.res:83-91`](../../reventless/aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res#L83-L91). A `Lambda.Permission` with principal `AWS.CloudwatchEventRule.principal` is added — but this Lambda is invoked by AppSync DataSource, not CloudWatch Events. The permission is dead weight in the right case but creates an unintended invocation surface for any CloudWatch Events rule in the account.

**Fix:** drop the unrelated permission.
**Effort:** Tiny.

### 11.6 — **Major, Correctness** — `Pulumi.Output.get` on `dns.http`
[`AppSync_EventsApi.res:67`](../../reventless/aws/src/adapter/Api/AppSync_EventsApi.res#L67). `dns.http->Option.getOr("")` — if `None`, the endpoint becomes `https://`. Every Lambda using this URL crashes at fetch time.

**Fix:** `getOrThrow` with a typed deploy-time error.
**Effort:** Tiny.

### 11.7 — **Minor, Operational** — two resolver implementations side-by-side
`AppSync_Resolver_Native` (Cloud Control) and `AppSync_Resolver_Retrying` (custom dynamic provider) both ship; some callers use one, some the other. Inconsistent — operationally one path will continue to leak the schema-propagation race.

**Fix:** consolidate on Retrying (handles the race) or accept Native + retry on `pulumi up --refresh`.
**Effort:** Small.

### 11.8 — **Minor, Operational** — `AppSync_Resolver_Retrying.read_` always reports present
[`AppSync_Resolver_Retrying.res:437-444`](../../reventless/aws/src/adapter/Api/AppSync_Resolver_Retrying.res#L437-L444). By design, `read_` lies; `pulumi refresh` cannot drift-detect a manually deleted resolver. Comment acknowledges this.

**Fix:** call `GetResolverCommand` and return real state; on `NotFoundException` return empty props for Pulumi to recreate. Gate on Pulumi version (≤3.224.0 has a documented crash).
**Effort:** Small.

### 11.9 — **Minor, Operational** — `runWithRaceRetry` ignores throttling
[`AppSync_Resolver_Retrying.res:204`](../../reventless/aws/src/adapter/Api/AppSync_Resolver_Retrying.res#L204). Retries on `NotFoundException` / "No field named" only. `LimitExceededException` (CreateResolver 25 TPS account default) and `ThrottlingException` are the more common failure modes on a deploy with hundreds of resolvers.

**Fix:** broaden retry conditions with a separate jitter strategy for throttling.
**Effort:** Small.

### 11.10 — **Minor, Operational** — duplicated data-source/role wiring across CommandGenerator / DCB / InboundTranslation
[`CommandGeneratorResolvers_AppSync.res:115-128, 184-230`](../../reventless/aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res#L115-L128), [`InboundTranslationResolvers_AppSync.res:21-69`](../../reventless/aws/src/adapter/CommandGenerator/InboundTranslationResolvers_AppSync.res#L21-L69). Three near-identical "create role + attach policy + create data source" blocks. Drift risk.

**Fix:** factor a shared `makeLambdaDataSource` helper.
**Effort:** Small.

### 11.11 — **Minor, Correctness** — hard-coded data-source names collide on multi-plugin
[`CommandGeneratorResolvers_AppSync.res:217 ("DcbMutation")`](../../reventless/aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res#L217), [`InboundTranslationResolvers_AppSync.res:57 ("InboundTranslation")`](../../reventless/aws/src/adapter/CommandGenerator/InboundTranslationResolvers_AppSync.res#L57). Multiple plugins on the same API collide.

**Fix:** prefix with plugin name.
**Effort:** Tiny.

### 11.12 — **Minor, Correctness** — `commandName` extracted from field-name suffix
[`CommandGeneratorResolvers_AppSync.res:131-136`](../../reventless/aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res#L131-L136). Splits on `_` and takes the last segment — a command `Inventory_Reserve_Item` becomes `Item`. Works for the current convention but fragile.

**Fix:** thread the explicit `(commandName, fieldName)` pair from the schema generator instead of re-deriving.
**Effort:** Small.

### 11.13 — **Minor, Operational** — InboundTranslation has no SQS-send policy
[`InboundTranslationResolvers_AppSync.res`](../../reventless/aws/src/adapter/CommandGenerator/InboundTranslationResolvers_AppSync.res). Unlike `CommandGeneratorResolvers_AppSync` (lines 47-63), only attaches a data-source-invoke-Lambda policy. If the inbound-translation Lambda needs to write to SQS (composes with the DCB command path), runtime fails with AccessDenied.

**Fix:** verify intent; if SQS sends are required, thread resources through.
**Effort:** Tiny.

---

## Cross-cutting observations

These observations span multiple adapters or affect framework-wide concerns. Each is folded into a plan; the section serves as a discoverability index for the cross-cutting concerns.

### XC-1 — **Major, Operational** — no CloudWatch alarms, no Lambda concurrency limits anywhere

No `aws.cloudwatch.MetricAlarm` resources are created by any adapter. No Lambda Function has `reservedConcurrency` set. A DDB-Stream replay (e.g. after a manual restore), a misconfigured upstream, or a runaway producer can exhaust account-wide Lambda concurrency, taking down every Lambda in the account. There is no alarm to notice.

**Fix:** opt-in alarm and concurrency-limit knobs on each adapter, with sensible defaults. CloudWatch metric alarms on each component's error rate, DLQ depth, and approximate message age. Plan: [major F.1](../plans/Backlog/aws-adapters-major-fixes.md#f1--cloudwatch-alarms--lambda-concurrency-limits-xc-1).

### XC-2 — **Minor, Operational** — no structured logging

Every `console.error("...", JSON.stringify(event))` is a free-form string. CloudWatch Logs Insights queries cannot extract fields without bespoke parsers per call site. A consistent JSON logger applied across handlers would let operators query `@type:dead_letter`, `correlationId:xyz` uniformly.

**Fix:** small `Util_Logger` module emitting structured JSON (`{level, time, msg, correlationId, source, ...fields}`); migrate `console.error` / `console.log` call sites adapter by adapter. Plan: [minor Bundle 11.1](../plans/Backlog/aws-adapters-minor-fixes.md#111--structured-json-logger-xc-2).

### XC-3 — **Minor, Operational** — `Lambda.reventlessLayerArn` is `option` everywhere

The Lambda layer carrying the framework runtime is referenced as `option<string>` throughout adapter Lambda definitions ([`StateTopic_AppSync.res:180`](../../reventless/aws/src/adapter/StateTopic/StateTopic_AppSync.res#L180), [`EventLogSubscription_AppSync.res:220`](../../reventless/aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L220), [`Platform_UIDefinitions_Lambda.res:113`](../../reventless/aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L113)). Adapters work without the layer — silently — because they fall back to bundling the framework into each Lambda's code asset. There is no deploy-time test that the layer is actually present in production builds. Misconfigured deploys ship without the layer and bloat each Lambda's bundle by ~30 MB.

**Fix:** add a deploy-time assertion that the layer ARN is `Some(_)` in production stacks (gated by `Pulumi.getStack()`); fail the deploy with a clear error if missing. Plan: [minor Bundle 11.2](../plans/Backlog/aws-adapters-minor-fixes.md#112--reventlesslayerarn-deploy-time-check-xc-3).

### XC-4 — already covered

- **SigV4 amzDate duplicated** (47 lines × 2) → [minor Bundle 1.1](../plans/Backlog/aws-adapters-minor-fixes.md#11--shared-sigv4-amzdate-helper-47-appsync-edge-cleanup).
- **Queues lack `messageRetentionSeconds`** (default 4 days drops events on outage) → [minor Bundle 10.1, 10.2](../plans/Backlog/aws-adapters-minor-fixes.md#101--dlq-retention-14-days-cross-cutting).
- **UTF-16 byte estimation underestimates SQS 256 KB cap** ([`SQS_Helpers.res:131-182`](../../reventless/aws/src/util/SQS_Helpers.res#L131-L182)) → [minor Bundle 1.4](../plans/Backlog/aws-adapters-minor-fixes.md#14--utf-8-byte-estimation-in-sqs_helpers-cross-cutting).

---

## Priority table

Ordered for execution. Rows fall into bands: Correctness blockers (Critical) → silent-data-loss / dual-write hazards (Major correctness) → cost amplifiers → operational hardening → documentation/cleanup. Inside each band, prefer cheaper items.

The **Plan** column points to the workstream that owns each item. `critical` = [aws-adapters-critical-fixes.md](../plans/Backlog/aws-adapters-critical-fixes.md), `major` = [aws-adapters-major-fixes.md](../plans/Backlog/aws-adapters-major-fixes.md), `minor` = [aws-adapters-minor-fixes.md](../plans/Backlog/aws-adapters-minor-fixes.md).

| # | Finding | Class | Severity | Effort | Plan | Why this position |
|---|---|---|---|---|---|---|
| 1 | [10.1](#101--critical-security--jwt-signature-is-not-verified) MCP JWT signature unverified | Security / Correctness | Critical | Small | [critical Step 6](../plans/Backlog/aws-adapters-critical-fixes.md#step-6--mcp-jwt-signature-verification-1) | Security blocker — any auth-mode-`None` deploy is exploitable. |
| 2 | [9.1](#91--critical-correctness--dailyhour-minute-cron-expression-is-invalid) `Daily(h, m)` cron expression invalid | Correctness | Critical | Tiny | [critical Step 1](../plans/Backlog/aws-adapters-critical-fixes.md#step-1--daily-cron-expression-fix-2) | Tiny cost, fixes a feature that does not work today. |
| 3 | [1.1](#11--critical-correctness--receipt-handle--parsed-body-mispairing) `Array.zip` receipt-handle mispairing in `_SQS_Runtime` | Correctness | Critical | Tiny | [critical Step 2](../plans/Backlog/aws-adapters-critical-fixes.md#step-2--receipt-handle--body-mispairing-3) | Silent body-vs-handle desync corrupts both success and DLQ paths. |
| 4 | [6.1](#61--critical-correctness--clonerrunner_fargate_runtimeres-uses-pulumioutputget-at-runtime) Cloner runtime `Pulumi.Output.get` (dead code) | Correctness | Critical | Small | [critical Step 3](../plans/Backlog/aws-adapters-critical-fixes.md#step-3--delete-dead-clonerrunner_fargate_runtimeres-4) | Dead today; fixing prevents the next person from re-enabling and crashing production. |
| 5 | [9.2](#92--critical-correctness--rolearn-pulumioutputget-at-lambda-runtime) Scheduler runtime `Pulumi.Output.get` | Correctness | Critical | Small | [critical Step 4](../plans/Backlog/aws-adapters-critical-fixes.md#step-4--scheduler-runtime-pulumioutputget-5) | Same class as #4; live in the only path that creates rules dynamically. |
| 6 | [9.7](#97--critical-correctnessoperational--resolvedresourceurn-carries-an-arn-by-convention) `resolvedResource.urn` carries an ARN by convention | Correctness | Critical | Medium | [critical Step 5](../plans/Backlog/aws-adapters-critical-fixes.md#step-5--resolvedresourceurn--typed-arnt-6) | Type-system gap; one rename change fixes Heartbeat + Scheduler IAM matching robustness. |
| 7 | [4.1](#41--major-correctness--queryengine-swallows-dynamodb-errors-as-) `QueryEngine` swallows errors as `[]` | Correctness | Major | Small | [major A.1](../plans/Backlog/aws-adapters-major-fixes.md#a1--queryengine-propagate-errors-7) | Wide blast radius — every translation slice / automation reads through this. Same shape as the historical fence-bypass bug. |
| 8 | [3.1](#31--major-correctness--non-transactional-dual-write-outbox-for-cross-plugin-events) SNS publishers are non-transactional dual-write | Correctness | Major | Large | [major E.1](../plans/Backlog/aws-adapters-major-fixes.md#e1--sns-dual-write-outbox-for-cross-plugin-events-8) | Silent loss of cross-plugin events; covers the only fan-out path that is not transactional. |
| 9 | [2.1](#21--critical-correctness--no-batchitemfailures-on-stream--sqs-event-collectors) `batchItemFailures` partial-batch reporting | Correctness | Critical | Medium | [major D.1](../plans/Backlog/aws-adapters-major-fixes.md#d1--batchitemfailures-partial-batch-reporting-9) | Single fix removes N× re-projection on poison events; also enables on-failure DLQ wiring. |
| 10 | [8.1](#81--major-correctness--silent-message-loss-on-appsync-5xx) StateTopic / EventLogSubscription silent message loss on AppSync 5xx | Correctness | Major | Small | [major A.3](../plans/Backlog/aws-adapters-major-fixes.md#a3--statetopic--eventlogsubscription-silent-message-loss-10) | UI subscribers see partial state; no DLQ catches it. |
| 11 | [5.4](#54--major-correctness--promiseall-partial-failure-abandons-successful-records) Task `Promise.all` partial-failure | Correctness | Major | Small | [major A.5](../plans/Backlog/aws-adapters-major-fixes.md#a5--task-promiseall-partial-failure-11) | Duplicate commands on retry without idempotency. |
| 12 | [2.5](#25--major-correctness--eventcollectorchannel_sqs_fifo-30s-visibility-too-short) EventCollector FIFO 30 s visibility timeout | Correctness | Major | Tiny | [major D.2](../plans/Backlog/aws-adapters-major-fixes.md#d2--eventcollector-fifo-visibility-timeout-12) | Silently downgrades FIFO exactly-once-per-group to "idempotent or corrupt." |
| 13 | [6.2](#62--major-correctness--runtaskcommand-has-no-clienttoken-no-idempotency) Cloner `RunTaskCommand` no `clientToken` | Correctness | Major | Tiny | [major D.3](../plans/Backlog/aws-adapters-major-fixes.md#d3--cloner-clienttoken-13) | Cheap idempotency on a dollar-expensive operation. |
| 14 | [9.3](#93--major-correctness--putrule--puttargets-not-atomic) + [9.4](#94--major-correctness--cost--deleteschedule-partial-failure-window) Scheduler PutRule/PutTargets + delete non-atomic | Correctness / Cost | Major | Small | [major D.4](../plans/Backlog/aws-adapters-major-fixes.md#d4--scheduler-putruleputtargets-atomicity-14) | Two fixes ship together; eliminates ghost rules. |
| 15 | [4.2](#42--major-cost--consistentread-true-hardcoded-on-every-querydb-load) `consistentRead: true` hardcoded on QueryDb loads | Cost | Major | Small | [major B.1](../plans/Backlog/aws-adapters-major-fixes.md#b1--remove-consistentread-true-default-on-querydb-loads-15) | **Negative** — halves RCU on every projection read. High-volume cost-saver. |
| 16 | [4.3](#43--major-performance--cost--util_dynamodb_runtimebatchwritewithretries-has-no-backoff) `batchWriteWithRetries` no backoff | Cost / Perf | Major | Tiny | [major B.2](../plans/Backlog/aws-adapters-major-fixes.md#b2--batchwritewithretries-exponential-backoff-16) | Negative (kills retry-amp loop) — one-line ish; removes an amplifier under throttling. |
| 17 | [4.4](#44--major-performance--cost--writemultiple-unbounded-concurrency) `writeMultiple` unbounded concurrency | Cost / Perf | Major | Tiny | [major B.3](../plans/Backlog/aws-adapters-major-fixes.md#b3--writemultiple-cap-concurrency-17) | Same shape as #16; cheap cap. |
| 18 | [4.5](#45--major-cost--performance--queryenginescanbytablename-is-unbounded) `QueryEngine.scan` unbounded | Cost | Major | Small | [major B.4](../plans/Backlog/aws-adapters-major-fixes.md#b4--queryenginescan-ceiling-18) | One ceiling + warning — admin tools can't accidentally drain RCU. |
| 19 | [11.4](#114--major-performance--cost--commandsubscriptionresolvers_appsync-has-no-subscription-filter) Command subscription has no filter | Cost / Perf | Major | Small | [major B.5](../plans/Backlog/aws-adapters-major-fixes.md#b5--command-subscription-per-id-filter-19) | Per-id filter pushdown; high savings on multi-client setups. |
| 20 | [8.3](#83--major-performance--cost--per-record-http-fetch-no-batching) AppSync Events per-record fetch | Cost / Perf | Major | Tiny | [major B.6](../plans/Backlog/aws-adapters-major-fixes.md#b6--appsync-events-batched-fetch-20) | Free win; no architectural change. |
| 21 | [3.2](#32--major-performance--cost--no-publishbatch-10-round-trips-and-connection-cost) SNS `PublishBatch` not used | Cost / Perf | Major | Small | [major B.7](../plans/Backlog/aws-adapters-major-fixes.md#b7--sns-publishbatch-21) | 10× API request reduction on event fan-out. |
| 22 | [11.2](#112--major-performance--cost--platform_uidefinitions_lambda-uses-scan-with-contains) `Platform_UIDefinitions` Scan + filter | Cost / Perf | Major | Small | [major B.8](../plans/Backlog/aws-adapters-major-fixes.md#b8--platform_uidefinitions_lambda-gsi-on-status-22) | Sparse GSI removes a scaling cliff. |
| 23 | [7.1](#71--major-cost--operational--targets-and-targetrefs-grow-unbounded) + [7.2](#72--major-performance--cost--not-containstargetrefs-targetref-is-on-per-write) Counter unbounded `targetRefs` | Cost / Operational | Major | Medium | [major D.6](../plans/Backlog/aws-adapters-major-fixes.md#d6--counter-unbounded-targetrefs-23) | Item-size cap is a hard production wall at ~13k targets per counter. |
| 24 | [8.2](#82--major-operational--appsync-events-240-kb-subscription-payload-limit-unenforced) AppSync 240 KB payload limit | Operational | Major | Small | [major D.7](../plans/Backlog/aws-adapters-major-fixes.md#d7--appsync-events-240-kb-payload-limit-24) | Silent UI breakage on large events. |
| 25 | [10.4](#104--major-performance--cost--readdcbeventloghistory-filters-in-memory-after-a-broad-query) MCP DCB history full-scan | Cost / Perf | Major | Small | [major D.8](../plans/Backlog/aws-adapters-major-fixes.md#d8--mcp-dcb-history-server-side-filter-25) | Push entity-id tag into DynamoDB query. |
| 26 | [10.2](#102--major-cost--security--no-rate-limiting--abuse-protection) MCP no rate limiting | Cost / Security | Major | Medium | [critical Step 6 follow-up](../plans/Backlog/aws-adapters-critical-fixes.md#step-6--mcp-jwt-signature-verification-1) | Open abuse vector; lands together with JWT verification. |
| 27 | [5.1](#51--major-operationalsecurity--bucket-has-no-encryption-versioning-or-publicaccessblock) S3 bucket missing baseline hardening | Operational / Security | Major | Small | [major C.1](../plans/Backlog/aws-adapters-major-fixes.md#c1--s3-bucket-baseline-27-28-29) | Compliance & blast radius. |
| 28 | [5.2](#52--major-operational--cors-allows-any-origin) S3 CORS `*` | Operational | Major | Small | [major C.1](../plans/Backlog/aws-adapters-major-fixes.md#c1--s3-bucket-baseline-27-28-29) | Tightens presigned-URL exposure. |
| 29 | [5.3](#53--major-cost--performance--lambda-subscribes-to-every-object-createdremoved) S3 notifications no prefix filter | Cost / Perf | Major | Small | [major C.1](../plans/Backlog/aws-adapters-major-fixes.md#c1--s3-bucket-baseline-27-28-29) | Per-event Lambda cost reduction. |
| 30 | [3.4](#34--major-operationalsecurity--sns-topics-created-without-kms-encryption) SNS topics no KMS | Security | Major | Tiny | [major C.2](../plans/Backlog/aws-adapters-major-fixes.md#c2--sns-topics-with-kms-encryption-30) | Compliance baseline. |
| 31 | [9.5](#95--major-security--events-over-permission) Scheduler `events:*` over-permission | Security | Major | Tiny | [major C.3](../plans/Backlog/aws-adapters-major-fixes.md#c3--scheduler-iam-scope-down-31) | One-line permission scope-down. |
| 32 | [11.5](#115--major-security--commandgeneratorresolvers_appsync-adds-cloudwatch-events-principal-to-appsync-invoked-lambda) CommandGenerator stray CW Events principal | Security | Major | Tiny | [major C.4](../plans/Backlog/aws-adapters-major-fixes.md#c4--drop-cw-events-principal-from-commandgenerator-lambda-32) | Dead permission with unintended invocation surface. |
| 33 | [2.2](#22--major-correctness--ddb-stream-filter-silently-drops-remove-and-key-only-records) DDB-stream silent drop on misconfig | Correctness | Major | Small | [major A.4](../plans/Backlog/aws-adapters-major-fixes.md#a4--ddb-stream-filter-silent-drop-33) | Deploy-time check + warning log; prevents "projections never update" mystery. |
| 34 | [2.3](#23--major-correctness--non-fifo-eventcollector-queue-is-unordered-for-stateful-projections) Non-FIFO EventCollector ordering caveat | Correctness | Major | Small/Medium | [major workstream A](../plans/Backlog/aws-adapters-major-fixes.md#workstream-a--silent-data-loss-elimination) | Documentation or guard. |
| 35 | [1.2](#12--major-correctness--non-fifo-commandtopic-has-no-per-aggregate-ordering) Non-FIFO CommandTopic ordering | Correctness | Major | Tiny | [major workstream A](../plans/Backlog/aws-adapters-major-fixes.md#workstream-a--silent-data-loss-elimination) | Likely just delete the variant. |
| 36 | [2.4](#24--major-operational--shared-platform-wide-dlqs-collapse-observability) Shared platform DLQs | Operational | Major | Medium | [major C.5](../plans/Backlog/aws-adapters-major-fixes.md#c5--per-component-dlqs--observability-36) | Observability uplift; pair with metric/alarm work. |
| 37 | [11.3](#113--major-operational--platform_uidefinitions_lambda-uncapped-pagination) `Platform_UIDefinitions` uncapped pagination | Operational | Major | Small | [major D.12](../plans/Backlog/aws-adapters-major-fixes.md#d12--platform_uidefinitions-pagination-cap-37) | Truncation header beats silent partial result. |
| 38 | [6.3](#63--major-operational--no-securitygroup-no-assignpublicip-config) Cloner no security group / public-ip | Operational | Major | Small | [major D.9](../plans/Backlog/aws-adapters-major-fixes.md#d9--cloner-network-config-38) | Subnet-dependent deploys are fragile. |
| 39 | [6.4](#64--major-correctness--lambda-execution-role-uses-appsync-principal) Cloner Lambda exec-role principal | Correctness | Major | Small | [major D.10](../plans/Backlog/aws-adapters-major-fixes.md#d10--cloner-lambda-exec-role-principal-39) | Verify + split roles. |
| 40 | [11.1](#111--major-operational--iam-only-auth-excludes-browser-clients) AppSync Events IAM-only auth | Operational | Major | Small | [major D.11](../plans/Backlog/aws-adapters-major-fixes.md#d11--appsync-events-cognito-auth-provider-40) | Browser subscribe-path. |
| 41 | [9.6](#96--major-correctness----fixme-arraygetunsafe0-on-queue-resources) Scheduler `getUnsafe(0)` on queue resources | Correctness | Major | Small | [major D.5](../plans/Backlog/aws-adapters-major-fixes.md#d5--scheduler-multi-queue-support-41) | Closes the `// FIXME` against multi-queue Schedulers. |
| 42 | [10.3](#103--major-correctnessoperational--streamcatchall-streamempty-swallows-dynamodb-errors) MCP `Stream.catchAll(Stream.empty)` | Correctness | Major | Tiny | [major A.2](../plans/Backlog/aws-adapters-major-fixes.md#a2--mcp_lambda-streamcatchallstreamempty-42) | Same class as 4.1. |
| 43 | [3.3](#33--major-cost--sns-fan-out-is-10-ddb-streams-fan-out-per-subscriber) SNS fan-out cost | Cost | Major | Tiny (doc) / Large (architectural) | [major E.2](../plans/Backlog/aws-adapters-major-fixes.md#e2--sns-fan-out-cost-documentation-43) | Doc first; architectural shift later. |
| 44 | [2.6](#26--minor-operational--ddb-stream-esm-has-no-parallelism--batching-knobs) DDB-stream ESM no parallelism knobs | Perf | Minor | Small/Medium | [minor Bundle 3](../plans/Backlog/aws-adapters-minor-fixes.md#38--ddb-stream-esm-knobs-44) | Knobs are cheap; LATEST-vs-seed is a separate ask. |
| 45 | [4.6](#46--minor-correctness--counts-updatecommand-reads-hardcoded-count-field) — [4.10](#410--minor-correctness--value-placeholder-collision-in-filter-expressions) QueryDb minor correctness items | Correctness | Minor | Tiny each | [minor Bundle 2](../plans/Backlog/aws-adapters-minor-fixes.md#bundle-2--querydb-minor-correctness) | Bundle as a single follow-up PR. |
| 46 | [7.3](#73--major-correctness--references-modify-events-silently-dropped) Counter MODIFY drop policy | Correctness | Major | Small | [major A.6](../plans/Backlog/aws-adapters-major-fixes.md#a6--counter-modify-drop-policy-46) | Explicit policy; doc or implement. |
| 47 | [8.4](#84--major-correctness--sigv4-amzdate-slicing-is-brittle) + [8.5](#85--minor-operational--visibility-timeout--6-lambda-timeout) + [8.7](#87--minor-correctness--fetch-with-no-abortcontroller-timeout) AppSync edge cleanup | Correctness / Operational | Mixed | Tiny each | [minor Bundle 1](../plans/Backlog/aws-adapters-minor-fixes.md#bundle-1--util_-cleanup) | Bundle into shared SigV4 helper + visibility timeout + fetch AbortController. |
| 48 | [9.10](#910--long-term--migrate-to-eventbridge-scheduler) Migrate to EventBridge Scheduler | Operational | Long-term | Large | (separate spike) | Profile-gated; defer until scale demands. |
| 49 | [XC-1](#xc-1--major-operational--no-cloudwatch-alarms-no-lambda-concurrency-limits-anywhere) No CloudWatch alarms / Lambda concurrency limits | Operational | Major | Medium | [major F.1](../plans/Backlog/aws-adapters-major-fixes.md#f1--cloudwatch-alarms--lambda-concurrency-limits-xc-1) | Cross-cutting; no alarm exists to notice a runaway. Pair with C.5 DLQ work for one observability PR series. |
| 50 | [XC-2](#xc-2--minor-operational--no-structured-logging) No structured logging | Operational | Minor | Small (helper) + Medium (migration) | [minor Bundle 11.1](../plans/Backlog/aws-adapters-minor-fixes.md#111--structured-json-logger-xc-2) | Helper is small; migration touches every adapter. Land helper first, migrate as call sites are touched. |
| 51 | [XC-3](#xc-3--minor-operational--lambdareventlesslayerarn-is-option-everywhere) `reventlessLayerArn` `option` without deploy-time check | Operational | Minor | Tiny | [minor Bundle 11.2](../plans/Backlog/aws-adapters-minor-fixes.md#112--reventlesslayerarn-deploy-time-check-xc-3) | One-line deploy-time assert; prevents silent 30 MB bundle bloat. |

---

## What can ship in parallel

- **Tiny + zero-impact items** (#2, #3, #12, #13, #20, #30–32, #42) — independent quick wins that any contributor can pick off.
- **QueryEngine error propagation (#7)** is independent of all storage adapters but touches every read-path caller — single PR with broad test coverage.
- **Cost-savers (#15, #16, #17, #18, #19, #20, #21, #22)** are independent of one another and ship in any order; #15 has the highest expected-value-per-day.
- **Counter redesign (#23)** is independent of everything else and unblocks production scale.
- **MCP-wide hardening (#1, #25, #26, #42)** cluster — one branch can land them together.
- **AppSync edge cleanup (#47)** is independent of #11.x — both edges can be touched in parallel.
- **Observability work (#36 — shared DLQs)** is the gating piece for several operational follow-ups; do early so the rest get good telemetry from day one.

## Cost-driven order: rank by net 6-month value

If you optimise for *value over a 6-month horizon* (correctness blockers first, then runtime savings net of dev cost):

1. **#1, #2, #3, #4, #5** — non-negotiable correctness blockers; tiny effort each (with #1 small).
2. **#15** — `consistentRead: true` removal halves RCU on every projection read; small effort, high RCU savings.
3. **#20, #21** — AppSync Events / SNS batching; one-line wins each.
4. **#22, #19** — scaling-cliff removals on Plugin RM scan and command subscriptions.
5. **#9** — `batchItemFailures` cuts projection re-work and unblocks on-failure DLQs.
6. **#23** — Counter unbounded list; medium effort but a hard production wall.
7. **#7** — QueryEngine error propagation; mechanical with wide blast radius.
8. **#36** — shared DLQs; observability uplift.
9. **#27, #28, #29** — S3 hardening together.
10. **#48** — EventBridge Scheduler migration; defer until scheduling load justifies.

The "by priority" table above lists the canonical execution order driven by class (correctness → silent-data-loss → cost-savers → hardening → cleanup). The "by 6-month value" list above re-shuffles for cost-aware planning when capacity is tight.
