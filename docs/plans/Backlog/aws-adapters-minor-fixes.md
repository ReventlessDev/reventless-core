# Plan: AWS Adapter Minor & Nit Fixes

**Analysis**: [aws-adapters-broad-review.md](../../analysis/aws-adapters-broad-review.md) — table rows #44–#48, #50, #51, plus the cross-cutting cleanup list.

A grab-bag of minor-severity findings across the AWS adapter surface. Most are tiny mechanical changes with low risk; bundle them into themed PRs rather than landing each individually.

## Sibling plans

- [aws-adapters-critical-fixes.md](aws-adapters-critical-fixes.md) — must land first.
- [aws-adapters-major-fixes.md](aws-adapters-major-fixes.md) — can run in parallel.

## Goals

- Eliminate fragile patterns (`getUnsafe(0)`, hand-rolled SigV4 dates, hardcoded data-source names).
- Reduce code duplication (SigV4 helpers, data-source wiring, dead-letter handling).
- Document load-bearing conventions (mutable globals, deploy-time-only state).
- Tune knobs that have safer defaults (visibility timeouts, retention windows, batch knobs).

## Non-goals

- Architectural shifts (covered in major-fixes E.1, E.2).
- Profiling-driven defaults (DDB-stream parallelism factor, etc.) — defaults stay conservative; production data informs follow-ups.

---

## Bundle 1 — `Util_*` cleanup

Single PR. ~1–2 days.

### 1.1 — Shared SigV4 amzDate helper (#47, AppSync edge cleanup)

**Files:**
- [`StateTopic_AppSync.res:59`](../../../reventless/reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res#L59)
- [`EventLogSubscription_AppSync.res:46`](../../../reventless/reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L46)

Both files contain ~47 lines of duplicated JS-as-string SigV4 signing code, including a brittle `now.toISOString().replace(/[:\-]|\..../g, "").slice(0, 15) + "Z"` regex that depends on Node returning exactly three milliseconds digits.

Extract to a shared helper module. Reconstruct amzDate explicitly from `Date` getters instead of slicing ISO format:

```js
const pad = n => String(n).padStart(2, "0");
const now = new Date();
const dateStamp = `${now.getUTCFullYear()}${pad(now.getUTCMonth()+1)}${pad(now.getUTCDate())}`;
const amzDate = `${dateStamp}T${pad(now.getUTCHours())}${pad(now.getUTCMinutes())}${pad(now.getUTCSeconds())}Z`;
```

New shared file: `reventless-aws/src/util/Util_SigV4.res` exporting `signRequest(~service, ~region, ~method, ~url, ~body, ~accessKey, ~secretKey, ~sessionToken)`.

Both AppSync handlers consume the helper. Test coverage moves from "none" to "tested in one place."

### 1.2 — `fetch` AbortController timeout (#47)

**Files:** Same two AppSync handlers.

Wrap each `fetch` in an `AbortController` with a 5–10 s timeout. Stuck connections fail fast instead of blocking until Lambda timeout.

```js
const controller = new AbortController();
const timeoutId = setTimeout(() => controller.abort(), 10_000);
try {
  const res = await fetch(url, {...opts, signal: controller.signal});
  ...
} finally {
  clearTimeout(timeoutId);
}
```

### 1.3 — EventLogSubscription visibility timeout (#47)

**File:** [`EventLogSubscription_AppSync.res:101`](../../../reventless/reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L101)

Raise SQS visibility from 60 s to 180 s (≥ 6× Lambda timeout). One-line change.

### 1.4 — UTF-8 byte estimation in `SQS_Helpers` (#cross-cutting)

**File:** [`SQS_Helpers.res:131-182`](../../../reventless/reventless-aws/src/util/SQS_Helpers.res#L131-L182)

`messageBody.length` measures UTF-16 code units; SQS measures UTF-8 bytes. Multi-byte characters can push real bytes over 256 KB → `BatchRequestTooLong`.

Two options:
- **Conservative:** apply a 30 % safety margin: cap at 180 KB instead of 256 KB.
- **Accurate:** `new TextEncoder().encode(s).length`. Slightly more CPU per message; correct.

Recommendation: accurate. Cost is negligible for typical batch sizes.

Also broaden `SQS_Error.classify` to recognise `BatchRequestTooLong` as a non-retryable size error (currently classifies as `Permanent` but with no telemetry).

---

## Bundle 2 — QueryDb minor correctness

Single PR. ~1 day.

### 2.1 — `count` UpdateCommand reads `attributes.fieldName` (not `"count"`) (#4.6)

**File:** [`QueryDbStorage_DynamoDb_Runtime.res:187-225`](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L187-L225)

Replace the hardcoded `"count"` lookup with `getIntAttribute(fieldName)`. Apply `DynamoDb_Error.retrySchedule` instead of generic `messageFromUnknown`.

### 2.2 — Resolve `saveMode.Any` semantics (#4.7)

**File:** [`QueryDbStorage_DynamoDb_Runtime.res:63-95`](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L63-L95)

Decide one of:
- **Delete `Any`** if the variant has no semantic distinct from `Overwrite`. Migrate callers; delete the constructor in `ReventlessCore.QueryDb.saveMode`.
- **Implement upsert-with-version-condition** if `Any` was meant for "don't clobber stale state": add a `version` attribute, condition the put on `version == :expected`.

Recommendation: delete unless someone produces a use case. Less code wins.

### 2.3 — JSON stringify/parse round-trip (#4.8)

**Files:**
- [`QueryDbStorage_DynamoDb_Runtime.res:33-37`](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L33-L37)
- [`QueryEngine_DynamoDb.res:105, 137`](../../../reventless/reventless-aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res#L105)

Replace `js->JSON.stringifyAny->Option.getOr("")->JSON.parseOrThrow` with direct `Obj.magic` (or `JSON.Encode.object` if a typed cast is needed). Per-item CPU + GC pressure removed.

### 2.4 — `delete`'s sort-key encoding (#QD-6)

**File:** [`QueryDbStorage_DynamoDb_Runtime.res:260-267`](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L260-L267)

Drop the redundant `JSON.Encode.string` (the value is already JSON). Document the string-only contract on `subIdField` if it actually holds.

### 2.5 — `loadStream` cursor double-wrap (#QD-8)

**File:** [`QueryDbStorage_DynamoDb_Runtime.res:38`](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L38)

`Option.map(key => Some(key))` produces `option<option<key>>`. Add a comment explaining the outer-Option-terminates-pagination contract, or refactor to make it obvious.

### 2.6 — `streamRegistry` mutable global (#QD-10)

**File:** [`QueryDbStorage_DynamoDbStream.res:8`](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDbStream.res#L8)

Document at the declaration that this is deploy-time-only state. Long-term: thread through Pulumi state. Same comment applies to `EventTopicPublisher_SNS.res:5` `snsRegistry`.

### 2.7 — QueryEngine value-placeholder collision (#4.10)

**File:** [`QueryEngine_DynamoDb.res:32`](../../../reventless/reventless-aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res#L32)

Replace `:${fieldName}${idx}` with sequential `:v0`, `:v1`, … placeholders. Alias `#fieldName` as `#f0`, `#f1`, … on the attribute-name side too. Removes the failure mode where field names with `-`, `.`, etc. produce malformed expressions.

### 2.8 — `streamViewType` parameterisation (#4.9)

**File:** [`QueryDbStorage_DynamoDbStream.res:27`](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDbStream.res#L27)

Audit consumers. If only Counter's counts table reads OldImage, parameterise `~streamViewType` per QueryDb with default `NEW_IMAGE`. Halves stream payload for the common case.

---

## Bundle 3 — CommandTopic / EventCollector polish

Single PR. ~1 day.

### 3.1 — FIFO `messageDeduplicationId` explicit (#1.4)

**File:** [`Util_SQS_Runtime.res:33-34, 60-69`](../../../reventless/reventless-aws/src/util/Util_SQS_Runtime.res#L33-L34)

Set `messageDeduplicationId = meta.msgId` (already a UUID) on FIFO sends. Removes dependency on `contentBasedDeduplication` and the silent-drop risk on retries.

### 3.2 — `Stream.grouped` size for batched send (#1.5)

**Files:** [`CommandTopicChannel_SQS_FIFO.res:39-50`](../../../reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_FIFO.res#L39-L50) and siblings.

Drop the `Stream.grouped(10)` pre-chunk; pass the entire stream into `publishJsons` and let `sendMessagesParallel` slice. Or grow the group size to ~256.

### 3.3 — CommandTopic queue policy fix (#1.6)

**File:** [`CommandTopicChannel_Helpers.res:30-32`](../../../reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_Helpers.res#L30-L32)

The `arnEquals: AWS:SourceArn = lambdaArn` condition is vacuous (Lambda receivers don't set `aws:SourceArn`). Drop the misleading condition; add a `Deny *` plus `Allow` for the specific sender role if access restriction is the goal.

### 3.4 — `Util_SQS_Runtime.sendMessages` retry indexing (#1 minor)

**File:** [`Util_SQS_Runtime.res:73-108`](../../../reventless/reventless-aws/src/util/Util_SQS_Runtime.res#L73-L108)

Index by position rather than `meta.msgId`. Aligns with the delete-batch retry pattern.

### 3.5 — DDB-stream resource flatten (#2.7)

**Files:**
- [`EventCollectorChannel_DynamoDbStream.res:36`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream.res#L36)
- [`EventCollectorChannel_SQS.res:73`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS.res#L73)
- [`EventCollectorChannel_SQS_FIFO.res:51`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_FIFO.res#L51)

Replace `outputs.resources->Array.getUnsafe(0) // FIXME` with iteration over all resources. Each EventTopic resource gets its own IAM grant.

### 3.6 — `enqueueEvent` retry (#2.8)

**File:** [`EventCollectorChannel_SQS_Runtime.res:69-89`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res#L69-L89)

Route through `Util_SQS_Runtime.send` (which already handles retry/classify) instead of calling `sendMessage` directly.

### 3.7 — `enqueueEvent` delay validation (#2 minor)

**File:** [`EventCollectorChannel_SQS_Runtime.res:69`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res#L69)

Validate `delay` at the adapter boundary. Currently silently clamped at 900 s in `SQS_Helpers.validateDelay`.

### 3.8 — DDB-stream ESM knobs (#44)

**File:** [`Util_EventSourceMapping.res:11-22`](../../../reventless/reventless-aws/src/util/Util_EventSourceMapping.res#L11-L22)

Expose `~parallelizationFactor`, `~batchSize`, `~maxBatchingWindowInSeconds` as parameters. Default `parallelizationFactor=10`. Document that LATEST starting position means redeploys lose in-flight stream records during the detach/attach window — long-term seed-from-log is a separate spike.

---

## Bundle 4 — EventTopic SNS polish

Single PR. ~½ day.

### 4.1 — `Promise.allSettled` for SNS publish (#3.5)

**File:** [`EventTopicPublisher_SNS.res:32-36`](../../../reventless/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS.res#L32-L36)

Replace `Promise.all` with `Promise.allSettled`; collect per-message outcomes; retry only the failed subset (mirror `Util_SQS_Runtime.sendMessages` retry-loop design).

### 4.2 — FIFO SNS throttling classifier (#3.6)

**File:** [`SNS_Error.res`](../../../reventless/reventless-aws/src/util/SNS_Error.res)

Broaden the classifier to catch FIFO-specific throttling strings (`KMSThrottlingException`, FIFO throughput strings). Document the 300/s ceiling.

### 4.3 — Lift `safeGroupId` to a shared module (#3.7)

**File:** [`Util_SQS_Runtime.res`](../../../reventless/reventless-aws/src/util/Util_SQS_Runtime.res) → new `Util_GroupId.res`

The SNS publisher reuses `Util_SQS_Runtime.safeGroupId` for SNS FIFO message groups. The SHA-256-on-overflow logic is identical for SQS and SNS but the cross-module dependency is misleading. Lift to a shared `Util_GroupId.safe` and import from both adapters.

### 4.4 — `snsRegistry` lifecycle documentation (#3.7)

**File:** [`EventTopicPublisher_SNS.res:5`](../../../reventless/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS.res#L5)

Add a comment documenting that `snsRegistry` is deploy-time-only mutable state. Same treatment as 2.6.

---

## Bundle 5 — Counter polish

Single PR. ~1 day.

Note: Counter unbounded `targetRefs` is in the major-fixes plan (D.6). Items here are incidental to that work; can ship independently or merged with D.6.

### 5.1 — Schema-decode WARN (#7.4)

**File:** [`CounterHandler_DynamoDbStream_Runtime.res:81-84`](../../../reventless/reventless-aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res#L81-L84)

Log the schema-decode error at WARN with the offending JSON. Pick fail-closed (skip the record, let DLQ handle) over fail-open (default `inc=1` and produce wrong counts).

### 5.2 — `ConditionalCheckFailedException` swallow (#7.5)

**File:** [`CounterHandler_DynamoDbStream_Runtime.res:11-33`](../../../reventless/reventless-aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res#L11-L33)

Wrap in `try/catch`; treat `ConditionalCheckFailedException` as success-via-idempotency; log at INFO. Removes the perpetual-retry loop on idempotent re-deliveries.

### 5.3 — `handlerConfigJson` build via `Output.all` (#7.6)

**File:** [`CounterHandler_DynamoDbStream.res:35-39`](../../../reventless/reventless-aws/src/adapter/Counter/CounterHandler_DynamoDbStream.res#L35-L39)

Replace `String.replace(...)` injection with `Output.all((counts, channel, refsArn, countsArn))->Output.apply(...)` building the JSON atomically. Removes the brittle template-string dependency.

### 5.4 — Hoist Lambda init (#7 minor)

**File:** [`CounterHandler_DynamoDbStream_Runtime.res:9, 56-62`](../../../reventless/reventless-aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res#L9)

Hoist `tableName`, `referencesARN`, `countsARN` from per-invocation to module scope. One cold-start read each instead of per-call.

---

## Bundle 6 — Task / S3 polish

Single PR. ~½ day. (Major S3 hardening — bucket SSE/versioning/PAB/CORS/notification filters — is in major-fixes C.1.)

### 6.1 — S3 key URL-decode (#5.6)

**File:** [`TaskBucket_S3_Runtime.res:6`](../../../reventless/reventless-aws/src/adapter/Task/TaskBucket_S3_Runtime.res#L6)

S3 events encode space as `+`. Replace `+` with space *before* `decodeURIComponent`, or document the constraint that keys cannot contain literal spaces. Recommendation: do the replace; users shouldn't have to know.

### 6.2 — `Write` mode split (#5.5)

**File:** [`TaskBucket_S3.res:34-49`](../../../reventless/reventless-aws/src/adapter/Task/TaskBucket_S3.res#L34-L49)

Split `bucketMode == Write` into:
- `WriteOnly` — `s3:PutObject` + `s3:AbortMultipartUpload`.
- `Write` (existing) — adds `s3:DeleteObject`.

Add `s3:AbortMultipartUpload` to all Write modes. Also add a lifecycle rule auto-aborting incomplete multipart uploads after 7 days (already covered by C.1).

---

## Bundle 7 — Cloner / Scheduler polish

Single PR. ~½ day.

### 7.1 — Cloner CPU/memory parameters (#6.5)

**File:** [`ClonerRunner_Fargate.res:154-156, 186-187`](../../../reventless/reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L154-L156)

Accept `~cpu` and `~memory` parameters with sensible defaults (1024 / 4096).

### 7.2 — Cloner log group retention (#6.5)

**File:** [`ClonerRunner_Fargate.res:158-165`](../../../reventless/reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L158-L165)

Pre-create the log group as a Pulumi resource with `retentionInDays: 30`.

### 7.3 — Cloner contextual error message (#6 nit)

**File:** [`ClonerRunner_Fargate.res:181-183`](../../../reventless/reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L181-L183)

Wrap `JSON.stringifyAny` `Option.getOrThrow` in a custom error with the field name.

### 7.4 — Heartbeat `sourceArn` (#9.8)

**File:** [`HeartbeatRunner_CloudWatchEvents.res:38-46`](../../../reventless/reventless-aws/src/adapter/Heartbeat/HeartbeatRunner_CloudWatchEvents.res#L38-L46)

Add `sourceArn: cloudwatchEventRule.arn->Pulumi.Output.asInput` to the `Lambda.Permission`. Restricts invocation surface from "any rule in the account" to "this specific rule."

### 7.5 — Heartbeat EventTarget out of `Pulumi.Output.apply` (#9.9)

**File:** [`HeartbeatRunner_CloudWatchEvents.res:75-85`](../../../reventless/reventless-aws/src/adapter/Heartbeat/HeartbeatRunner_CloudWatchEvents.res#L75-L85)

Lift the EventTarget creation out of the `apply` block. Use `arn: lambdaArn->Pulumi.Output.asInput`.

### 7.6 — Heartbeat idempotency key (#9.minor)

**File:** [`HeartbeatRunner_CloudWatchEvents.res`](../../../reventless/reventless-aws/src/adapter/Heartbeat/HeartbeatRunner_CloudWatchEvents.res)

Include a deterministic idempotency key (e.g. truncated rule timestamp) in the heartbeat send. Heartbeat consumers should be idempotent regardless, but explicit dedup helps.

---

## Bundle 8 — MCP polish

Single PR. ~½ day. (Major MCP work — JWT signature, rate limiting, error propagation, server-side filters — is in critical-fixes Step 6 and major-fixes A.2 + B.* + D.8.)

### 8.1 — `consistentRead: false` on event-history reads (#10.5)

**File:** [`MCP_Lambda.res:207`](../../../reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res#L207)

Add a `~consistentRead=false` parameter. Browse use cases don't need strong consistency; saves 50 % RCU.

### 8.2 — `correlationId` from request header (#10.6)

**File:** [`MCP_Lambda.res:419`](../../../reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res#L419)

Accept `correlationId` argument; populate from `X-Request-Id` (or whatever the MCP client sends) at the handler boundary. Plumb through `runEffect`.

### 8.3 — `extractEntityId` URI template parsing (#10.7)

**File:** [`MCP_Lambda.res:132-136`](../../../reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res#L132-L136)

Parse against the registered `uriTemplate` rather than positional last-segment. Handles trailing slash, encoded slashes, multi-param templates correctly.

### 8.4 — `parsePaginationParams` use `URLSearchParams` (#10.8)

**File:** [`MCP_Lambda.res:139-157`](../../../reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res#L139-L157)

Replace ad-hoc `String.split("=")` with `URL` / `URLSearchParams`. Decodes percent-encoded values correctly (e.g. base64 cursors with `=`).

### 8.5 — `Effect.runPromise` with service context (#10 nit)

**File:** [`MCP_Lambda.res:222`](../../../reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res#L222)

Route through `runEffect` so the Effect inherits `RequestContext` (correlation id) instead of running with no service context.

---

## Bundle 9 — AppSync resolver polish

Single PR. ~½ day.

### 9.1 — Consolidate Native vs Retrying resolver (#11.7)

**Files:**
- [`AppSync_Resolver_Native.res`](../../../reventless/reventless-aws/src/adapter/Api/AppSync_Resolver_Native.res)
- [`AppSync_Resolver_Retrying.res`](../../../reventless/reventless-aws/src/adapter/Api/AppSync_Resolver_Retrying.res)
- All callers

Pick one. Recommendation: Retrying (handles the schema-propagation race transparently). Delete Native; migrate `Platform_UIDefinitions_Lambda` to Retrying.

### 9.2 — `Retrying.read_` real read (#11.8)

**File:** [`AppSync_Resolver_Retrying.res:437-444`](../../../reventless/reventless-aws/src/adapter/Api/AppSync_Resolver_Retrying.res#L437-L444)

Call `GetResolverCommand`; return real state. On `NotFoundException` return empty props so Pulumi recreates. Gate on Pulumi version (≤3.224.0 has a documented crash).

### 9.3 — Broaden `runWithRaceRetry` (#11.9)

**File:** [`AppSync_Resolver_Retrying.res:204`](../../../reventless/reventless-aws/src/adapter/Api/AppSync_Resolver_Retrying.res#L204)

Add throttling-aware retries (`LimitExceededException`, `ThrottlingException`) with a separate jitter strategy.

### 9.4 — Broaden `isAlreadyExistsError` (#11 nit)

**File:** [`AppSync_Resolver_Retrying.res:150`](../../../reventless/reventless-aws/src/adapter/Api/AppSync_Resolver_Retrying.res#L150)

Match `ConflictException` variants too. Currently only `BadRequestException` "Only one resolver" is caught.

### 9.5 — Delete-handler ARN regex (#11 nit)

**File:** [`AppSync_Resolver_Retrying.res:386-393`](../../../reventless/reventless-aws/src/adapter/Api/AppSync_Resolver_Retrying.res#L386-L393)

Replace position-based ARN parsing with regex parsing + typed error.

### 9.6 — `dns.http` `getOrThrow` (#11.6)

**File:** [`AppSync_EventsApi.res:67`](../../../reventless/reventless-aws/src/adapter/Api/AppSync_EventsApi.res#L67)

Replace `Option.getOr("")` with `getOrThrow(~message="…")`. Crashes loudly at deploy time instead of at first runtime fetch.

### 9.7 — Subscription resolver as `NONE` data source (#11.4)

**File:** [`CommandSubscriptionResolvers_AppSync.res:22-28`](../../../reventless/reventless-aws/src/adapter/Api/CommandSubscriptionResolvers_AppSync.res#L22-L28)

Create a single shared `NONE` data source for subscription resolvers (UNIT subscription with `setSubscriptionFilter`). Removes per-DS rate-limit contention with mutation resolvers.

### 9.8 — Plugin-prefixed data source names (#11.11)

**Files:**
- [`CommandGeneratorResolvers_AppSync.res:217`](../../../reventless/reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res#L217)
- [`InboundTranslationResolvers_AppSync.res:57`](../../../reventless/reventless-aws/src/adapter/CommandGenerator/InboundTranslationResolvers_AppSync.res#L57)

Prefix `"DcbMutation"` / `"InboundTranslation"` with the plugin name. Removes collision risk on multi-plugin platforms.

### 9.9 — `commandName` from explicit pair (#11.12)

**File:** [`CommandGeneratorResolvers_AppSync.res:131-136`](../../../reventless/reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res#L131-L136)

Thread an explicit `(commandName, fieldName)` pair from the schema generator instead of re-deriving via `String.split("_")`.

### 9.10 — InboundTranslation SQS-send policy (#11.13)

**File:** [`InboundTranslationResolvers_AppSync.res`](../../../reventless/reventless-aws/src/adapter/CommandGenerator/InboundTranslationResolvers_AppSync.res)

Verify whether the inbound-translation Lambda needs SQS-send permissions. If yes, thread SQS resources through `make` and add the policy. If no, document that the resolver is read-only.

### 9.11 — `Platform_UIDefinitions` minor polish

**File:** [`Platform_UIDefinitions_Lambda.res`](../../../reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res)

Several minor items in the analysis (#9.3 missing-env throws, #9.4 memory profile, #9.5 GSI scope, #9.6 sanitize errors). Bundle into the same PR.

---

## Bundle 10 — Cross-cutting polish

Single PR. ~½ day.

### 10.1 — DLQ retention 14 days (#cross-cutting)

**File:** [`Util_DeadLetterQueue.res:8-23`](../../../reventless/reventless-aws/src/util/Util_DeadLetterQueue.res#L8-L23)

Set `messageRetentionSeconds: 1209600`. Default 4 days drops poison messages before investigators can examine them.

This may already be covered by major-fixes C.5 (per-component DLQs); coordinate.

### 10.2 — Queue retention parameterisation (#cross-cutting)

**Files:** Every `*_SQS*.res` queue maker.

Expose `~messageRetentionSeconds` parameter. Document the trade-off between cost and outage tolerance.

### 10.3 — Consolidate duplicated data-source wiring (#11.10)

**Files:**
- [`CommandGeneratorResolvers_AppSync.res:115-128, 184-230`](../../../reventless/reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res#L115-L128)
- [`InboundTranslationResolvers_AppSync.res:21-69`](../../../reventless/reventless-aws/src/adapter/CommandGenerator/InboundTranslationResolvers_AppSync.res#L21-L69)

Factor a shared `makeLambdaDataSource(~name, ~lambda, ~api, ~opts)` helper. Three near-identical role/policy/data-source blocks become one.

### 10.4 — `EventCollectorChannel_DynamoDbStream` `enqueueEventNotSupported` (#cross-cutting nit)

**File:** [`EventCollectorChannel_DynamoDbStream.res:38-46`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream.res#L38-L46)

Replace silent no-op `Promise.resolve()` with explicit `Effect.fail("not supported by DynamoDbStream variant")`. Surfaces misuse instead of swallowing it.

### 10.5 — Silent `Effect.catchAll` on delete batch (#cross-cutting nit)

**File:** [`EventCollectorChannel_SQS_Runtime.res:42-44`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res#L42-L44)

Log the error message at WARN before swallowing.

### 10.6 — `CommandGeneratorResolvers_AppSync_NoOp` msgId (#10.6)

**File:** [`CommandGeneratorResolvers_AppSync_NoOp.res:8`](../../../reventless/reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync_NoOp.res#L8)

Generate a unique msgId per call (uuid) or use a sentinel like `"admin-noop-" ++ uuidv4()`. Removes the "stuck command" UI artifact when callers correlate by msgId.

### 10.7 — `CommandGeneratorResolvers_AppSync_Runtime` inline (#10 nit)

**File:** [`CommandGeneratorResolvers_AppSync_Runtime.res`](../../../reventless/reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync_Runtime.res)

One-line wrapper around `generateCommand`. Inline at the call site or remove.

### 10.8 — `Effect.runSync(logError)` in CommandTopic (#1.minor)

**File:** [`CommandTopicChannel_SQS_Runtime.res:38-43`](../../../reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res#L38-L43)

Integrate the error log into the surrounding `Effect.flatMap` chain instead of `Effect.runSync` (which can drop log lines on Lambda freeze).

---

## Bundle 11 — Cross-cutting framework hygiene

Two findings from the analysis cross-cutting section. Independent but related — both move toward "deploys work the way operators expect, observably."

### 11.1 — Structured JSON logger (XC-2)

**Analysis:** [XC-2](../../analysis/aws-adapters-broad-review.md#xc-2--minor-operational--no-structured-logging)

Every `console.error("...", JSON.stringify(event))` call site is a free-form string. CloudWatch Logs Insights queries cannot extract fields without bespoke parsers per call site.

Steps:

1. Add a small `Util_Logger` module:
   ```rescript
   module Logger: {
     type t
     let make: (~source: string) => t
     let info: (t, ~correlationId: option<string>=?, ~fields: dict<JSON.t>=?, string) => unit
     let warn: (t, ~correlationId: option<string>=?, ~fields: dict<JSON.t>=?, string) => unit
     let error: (t, ~correlationId: option<string>=?, ~fields: dict<JSON.t>=?, string) => unit
   }
   ```
   Output is one JSON line per log: `{"@timestamp": ..., "level": "error", "source": "EventCollector", "msg": "...", "correlationId": "...", ...fields}`.

2. Migrate `console.error` / `console.log` call sites adapter by adapter. Don't try to land in one PR — each adapter PR can include its own migration.

3. Document the field schema in `packages/doc/docs/inner-workings/logging.md` with sample CloudWatch Insights queries.

**Effort:** Small (helper) + Medium (migration over time, opportunistic). The helper itself ships in this bundle; the migration is gradual.

### 11.2 — `reventlessLayerArn` deploy-time check (XC-3)

**Analysis:** [XC-3](../../analysis/aws-adapters-broad-review.md#xc-3--minor-operational--lambdareventlesslayerarn-is-option-everywhere)

**Files:** every adapter that constructs a Lambda Function with `reventlessLayerArn: option<string>`. Sample sites:
- [`StateTopic_AppSync.res:180`](../../../reventless/reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res#L180)
- [`EventLogSubscription_AppSync.res:220`](../../../reventless/reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L220)
- [`Platform_UIDefinitions_Lambda.res:113`](../../../reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L113)

Add a deploy-time assertion that the layer ARN is `Some(_)` when running against production stacks. Suggested implementation in a shared helper:

```rescript
let assertLayerArn = (layerArn: option<string>) =>
  switch (Pulumi.getStack(), layerArn) {
  | ("prod", None) | ("production", None) =>
    JsError.throwWithMessage("reventlessLayerArn must be Some in production stacks — missing layer bloats Lambda bundles by ~30 MB")
  | _ => ()
  }
```

Call sites use `assertLayerArn(args.reventlessLayerArn)` early in `make`.

**Effort:** Tiny.

---

## Sequencing

Bundles are independent. Suggested order based on size and risk:

1. **Bundle 2 (QueryDb minor)** — well-contained, low-risk.
2. **Bundle 4 (SNS polish)** — small, isolated.
3. **Bundle 7 (Cloner / Scheduler polish)** — small, after critical-fixes Steps 4–5 land.
4. **Bundle 6 (Task / S3 polish)** — small, after major-fixes C.1 lands.
5. **Bundle 1 (Util_*)** — moderate, requires extracting shared helpers.
6. **Bundle 3 (CommandTopic / EventCollector polish)** — moderate, depends on critical-fixes Step 2.
7. **Bundle 5 (Counter polish)** — coordinate with major-fixes D.6.
8. **Bundle 8 (MCP polish)** — after critical-fixes Step 6 (JWT) lands.
9. **Bundle 9 (AppSync resolver polish)** — moderate, requires careful audit.
10. **Bundle 10 (Cross-cutting polish)** — last.
11. **Bundle 11 (Cross-cutting framework hygiene)** — 11.2 (layer-ARN check) is a quick win that can land any time; 11.1 (logger) helper ships standalone, migration is gradual.

Total span: 1–2 weeks depending on capacity (excluding gradual logger migration).

## Verification

For each bundle:
- `pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"` — clean.
- New tests where reasonable; for trivial renames/parameter additions, compiler enforcement is sufficient.

## Out of scope

- All critical findings → [aws-adapters-critical-fixes.md](aws-adapters-critical-fixes.md)
- All major findings → [aws-adapters-major-fixes.md](aws-adapters-major-fixes.md)
- Long-term architectural items (EventBridge Scheduler migration, SNS-to-Streams unification) — separate plans, gated on production-data signals.
