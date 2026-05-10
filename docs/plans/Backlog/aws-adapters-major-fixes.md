# Plan: AWS Adapter Major Fixes

**Analysis**: [aws-adapters-broad-review.md](../../analysis/aws-adapters-broad-review.md) — table rows #7–#43.

Thirty-eight major-severity findings across the AWS adapter surface (37 from the per-adapter sections plus one cross-cutting observation, [XC-1](../../analysis/aws-adapters-broad-review.md#xc-1--major-operational--no-cloudwatch-alarms-no-lambda-concurrency-limits-anywhere) — no CloudWatch alarms or Lambda concurrency limits anywhere). Issues split into six workstreams (A — silent-data-loss, B — cost capping, C — hardening, D — operational sharp edges, F — observability, E — architectural followups) that are largely independent and can ship in parallel. Each workstream is its own PR (or short PR series) so reviewers can focus.

## Sibling plans

- [aws-adapters-critical-fixes.md](aws-adapters-critical-fixes.md) — must land first; Steps 5–6 below assume the Scheduler/Cloner critical fixes have shipped.
- [aws-adapters-minor-fixes.md](aws-adapters-minor-fixes.md) — minor cleanups; can run in parallel.

## Goals

- Close all silent-data-loss paths in adapters.
- Cap costs that scale with load (RCU, WCU, fan-out fees).
- Bring AWS resources up to baseline operational/security hygiene (encryption, scoped IAM, DLQs, alarms).
- Replace fragile patterns (`getUnsafe(0)`, swallow-and-return-empty, hardcoded data-source names) with deterministic alternatives.

## Non-goals

- Long-term architectural shifts (EventBridge Scheduler migration, SNS-to-Streams unification beyond ExtensionPoint events) — separate backlog items.
- Profiling-driven decisions (DDB-stream parallelism knobs are added but defaults are not tuned without production data).

---

## Workstream A — Silent-data-loss elimination

Six findings that all share one shape: the code receives an error, swallows it, and returns a "no data" sentinel that callers can't distinguish from genuine emptiness. This workstream closes them as a single PR series.

### A.1 — `QueryEngine` propagate errors (#7)

**File:** [`QueryEngine_DynamoDb.res:106-110, 138-142`](../../../reventless/reventless-aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res#L106-L110)

Both `query` and `scan` use `Effect.catchAll` to log and return `[]`. Replace with error propagation through the Effect channel. Callers that *want* "treat error as empty" must opt in explicitly.

Steps:
1. Drop the `catchAll` from both functions; let `DynamoDb_Error` propagate.
2. Audit every caller. Each must either:
   - Surface the error to its caller (almost always correct), or
   - Wrap with explicit `Effect.catchAll(_ => Effect.succeed([]))` and add a `// reason: ...` comment.
3. Mechanical migration. Run `pnpm run build` to find all type-error sites; fix one at a time.

**Tests:** add a test that mocks DynamoDB throwing; assert the Effect channel surfaces the error rather than producing `[]`.

**Risk:** broad blast radius. Recommend landing this on the `alpha` branch with one release of staging-bake before merging to `beta`.

### A.2 — `MCP_Lambda` `Stream.catchAll(Stream.empty)` (#42)

**File:** [`MCP_Lambda.res:211-213`](../../../reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res#L211-L213)

Same shape as A.1, but local to one Stream. Replace with explicit error surfacing via the Effect channel. Mostly a one-liner.

### A.3 — StateTopic / EventLogSubscription silent message loss (#10)

**Files:**
- [`StateTopic_AppSync.res:73-89`](../../../reventless/reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res#L73-L89)
- [`EventLogSubscription_AppSync.res:62-82`](../../../reventless/reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L62-L82)

Both handlers `console.error` on AppSync 5xx and continue. Lambda returns success; the source (DDB stream / SQS) marks the message processed; it's **lost** to UI subscribers.

Steps:
1. Track per-record success/failure in a results array.
2. For DynamoDB Streams: throw if any record failed → Lambda fails → DDB stream retries the shard window.
3. For SQS: return `{batchItemFailures: [{itemIdentifier: messageId}]}` (requires enabling `functionResponseTypes: ["ReportBatchItemFailures"]` on the EventSourceMapping).
4. Wire `DestinationConfig.OnFailure` to a DLQ on both EventSourceMappings.

### A.4 — DDB-stream filter silent drop (#33)

**File:** [`EventCollectorChannel_DynamoDbStream_Runtime.res:6-19`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res#L6-L19)

Steps:
1. Log a `WARN` when a record is dropped and its `eventName` is non-trivial (i.e. `INSERT`/`MODIFY`/`REMOVE` rather than something the filter expects to skip).
2. Add a deploy-time validation in `EventCollectorChannel_DynamoDbStream.res`'s `make` that the source table's `StreamViewType` is `NEW_IMAGE` or `NEW_AND_OLD_IMAGES`. Fail the Pulumi deploy with a clear error.

### A.5 — Task `Promise.all` partial failure (#11)

**File:** [`TaskBucket_S3_Runtime.res:1-11`](../../../reventless/reventless-aws/src/adapter/Task/TaskBucket_S3_Runtime.res#L1-L11)

Replace `Promise.all` with `Promise.allSettled`. Collect successful results; emit a metric for failed records; signal partial failure to Lambda via the standard `batchItemFailures` response (S3 events delivered through SQS support this).

### A.6 — Counter MODIFY drop policy (#46)

**File:** [`CounterHandler_DynamoDbStream_Runtime.res:86-89`](../../../reventless/reventless-aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res#L86-L89)

Currently `OLD_AND_NEW` images on a reference row are silently dropped. Decide policy:

- **If references are immutable** (write-once): assert at insertion time, document, and keep the drop with an INFO log.
- **If references are mutable**: compute `delta = newInc - oldInc` and apply it.

Recommendation: enforce immutability via a `ConditionExpression: attribute_not_exists(id)` on the original write. Cheaper than supporting deltas and matches the apparent intent.

---

## Workstream B — Cost capping

Eight findings that all reduce ongoing AWS spend. Independent of one another; pick off in any order. None require architecture changes.

### B.1 — Remove `consistentRead: true` default on QueryDb loads (#15)

**File:** [`QueryDbStorage_DynamoDb_Runtime.res:8-40`](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L8-L40)

Add a `~consistentRead=false` parameter to `load` / `loadStream`. Update the callers that genuinely need strong reads (typically same-handler save-then-load) to pass `~consistentRead=true` explicitly. Default everywhere else to `false`. Halves RCU on every projection load.

### B.2 — `batchWriteWithRetries` exponential backoff (#16)

**File:** [`Util_DynamoDb_Runtime.res:177-203`](../../../reventless/reventless-aws/src/util/Util_DynamoDb_Runtime.res#L177-L203)

Insert exponential backoff between attempts. Sketch:

```rescript
let rec attempt = (retry, requests) => {
  let backoffMs = retry == 0 ? 0 : Math.minInt(2000, 50 * Math.pow_int(~base=2, ~exp=retry))
  Effect.sleep(backoffMs->Duration.millis)
  ->Effect.flatMap(_ => batchWriteCommand(requests))
  ->Effect.flatMap(out =>
    switch out.unprocessedItems {
    | None | Some([]) => Effect.succeed()
    | Some(left) when retry >= 8 => Effect.fail(...)  // give up after 8 tries
    | Some(left) =>
      Effect.logWarn("batchWrite retry #" ++ retry->Int.toString)
      ->Effect.flatMap(_ => attempt(retry + 1, left))
    }
  )
}
```

Cap at 8 retries; emit a metric when retries > 3.

### B.3 — `writeMultiple` cap concurrency (#17)

**File:** [`QueryDbStorage_DynamoDb_Runtime.res:123-144`](../../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbStorage_DynamoDb_Runtime.res#L123-L144)

Replace `{"concurrency": "unbounded"}` with `{"concurrency": 4}` (or 8). Expose as a config knob with default 4.

### B.4 — `QueryEngine.scan` ceiling (#18)

**File:** [`QueryEngine_DynamoDb.res:114-144`](../../../reventless/reventless-aws/src/adapter/QueryEngine/QueryEngine_DynamoDb.res#L114-L144)

Add a max-item ceiling (default 5 000). Emit a `WARN` when scans return more than 1 000 items. Consider gating behind a `DEBUG` env-var flag for production.

### B.5 — Command subscription per-id filter (#19)

**File:** [`CommandSubscriptionResolvers_AppSync.res:22`](../../../reventless/reventless-aws/src/adapter/Api/CommandSubscriptionResolvers_AppSync.res#L22)

Generate `subscriptionFilter` on `id` from the resolver's request context when the command type has an id field. Optional fallback for command types without an id.

### B.6 — AppSync Events batched fetch (#20)

**Files:**
- [`StateTopic_AppSync.res:75-84`](../../../reventless/reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res#L75-L84)
- [`EventLogSubscription_AppSync.res:62-82`](../../../reventless/reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L62-L82)

Group records by computed channel; POST once per batch (`events: [...]`). 10× to 100× reduction in AppSync requests.

### B.7 — SNS `PublishBatch` (#21)

**File:** [`EventTopicPublisher_SNS_Runtime.res`](../../../reventless/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS_Runtime.res)

Add `PublishBatch` to `SNS_Helpers`; route group sends through it. Replace the `Stream.grouped(10) → Promise.all(map(publish))` pattern with one `PublishBatch` per group.

### B.8 — `Platform_UIDefinitions_Lambda` GSI on status (#22)

**Files:**
- [`Platform_UIDefinitions_Lambda.res:32-36`](../../../reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L32-L36)
- The Plugin read-model schema (likely in `reventless-core/src/admin/`)

Add a sparse GSI keyed on `status` (only `Connected` rows present). Switch the Lambda from `Scan` to `Query` against the GSI. Removes the linear-scan-per-call cost.

---

## Workstream C — Hardening (encryption, IAM, DLQ)

Five findings that bring AWS resources up to the conventional baseline. Mostly trivial code changes; the work is in the audit + rollout.

### C.1 — S3 bucket baseline (#27, #28, #29)

**File:** [`TaskBucket_S3.res:11-15, 128-149`](../../../reventless/reventless-aws/src/adapter/Task/TaskBucket_S3.res#L128-L149)

One PR, three changes:

1. Add SSE-S3 (or KMS, expose as a parameter) `serverSideEncryptionConfiguration`.
2. Enable `versioning` and attach a `BucketPublicAccessBlock` with all four flags `true`.
3. Lifecycle rule expiring non-current versions after 30 days, deleting after 90 days; auto-aborting incomplete multipart uploads after 7 days.
4. Parameterise `corsRules.allowedOrigins`; default to no cross-origin (or to a configurable list).
5. Accept `~filterPrefix` / `~filterSuffix` parameters for `onObjectCreated` / `onObjectRemoved`; pass through to S3 notification config.

### C.2 — SNS topics with KMS encryption (#30)

**Files:**
- [`EventTopicPublisher_SNS.res:7-14`](../../../reventless/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS.res#L7-L14)
- [`EventTopicPublisher_SNS_FIFO.res:5-11`](../../../reventless/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS_FIFO.res#L5-L11)

Add `kmsMasterKeyId: "alias/aws/sns"` (free, AWS-managed). Expose as parameter.

### C.3 — Scheduler IAM scope-down (#31)

**File:** [`ScheduledPublisher_CloudWatchEvents.res:16-22`](../../../reventless/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents.res#L16-L22)

Replace `events:*` on `*` with explicit `events:PutRule`, `events:DeleteRule`, `events:PutTargets`, `events:RemoveTargets` on `arn:aws:events:*:*:rule/<stack-prefix>-*`.

### C.4 — Drop CW Events principal from CommandGenerator Lambda (#32)

**File:** [`CommandGeneratorResolvers_AppSync.res:83-91`](../../../reventless/reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res#L83-L91)

Remove the unrelated `Lambda.Permission` granting CloudWatch Events principal. The Lambda is invoked by AppSync only.

### C.5 — Per-component DLQs + observability (#36)

**File:** [`Util_DeadLetterQueue.res`](../../../reventless/reventless-aws/src/util/Util_DeadLetterQueue.res)

Replace the two shared platform DLQs with per-component DLQs (or per-component-type at minimum: CommandTopicDLQ, EventCollectorDLQ, EventTopicDLQ).

DLQ handler:
1. Replace `console.error(...)` with structured JSON log (`@type: dead_letter`, `source`, `body`, `timestamp`).
2. Emit a CloudWatch metric (`ReventlessDeadLetterCount`, dimensioned by source).
3. Set `messageRetentionSeconds: 1209600` (14 days).
4. Optional: write to S3 for long-term archive (parameter, default off).

CloudWatch alarms (one per DLQ): trigger when `ApproximateNumberOfMessagesVisible > 0` for 5 min.

### C.6 — Logs:* scope-down (#8.8 in analysis)

**Files:**
- [`StateTopic_AppSync.res:137-141`](../../../reventless/reventless-aws/src/adapter/StateTopic/StateTopic_AppSync.res#L137-L141)
- [`EventLogSubscription_AppSync.res:181`](../../../reventless/reventless-aws/src/adapter/EventLogSubscription/EventLogSubscription_AppSync.res#L181)
- [`Platform_UIDefinitions_Lambda.res:86`](../../../reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L86)

Replace `logs:*` with explicit `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`. Tighten resource scope.

---

## Workstream D — Operational sharp edges

Twelve findings that fix sharp edges in the adapter wiring. Mostly mechanical; bundle into one PR per family.

### D.1 — `batchItemFailures` partial-batch reporting (#9)

**Files:**
- [`EventCollectorChannel_DynamoDbStream_Runtime.res:6-19`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_DynamoDbStream_Runtime.res#L6-L19)
- [`EventCollectorChannel_SQS_Runtime.res:36-45`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res#L36-L45)
- [`Util_EventSourceMapping.res:11-22`](../../../reventless/reventless-aws/src/util/Util_EventSourceMapping.res#L11-L22)

Steps:
1. Thread per-record success status through `handleEvents` (return `array<Result<unit, error>>` instead of just `unit`).
2. On failure: collect failing identifiers; return `{batchItemFailures: [...]}` from the Lambda handler.
3. Add `functionResponseTypes: ["ReportBatchItemFailures"]` and `bisectBatchOnFunctionError: true` to `Util_EventSourceMapping.subscribe`.
4. Add `destinationConfig.onFailure` parameter (a DLQ ARN) — pass through to ESM.

This is the single largest cost-reducer for projection-heavy workloads (eliminates N× re-projection).

### D.2 — EventCollector FIFO visibility timeout (#12)

**File:** [`EventCollectorChannel_SQS_FIFO.res:22`](../../../reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_FIFO.res#L22)

Raise from 30 s to 180 s (≥ 6× Lambda timeout). One-line fix; remove the `// TODO` marker.

### D.3 — Cloner `clientToken` (#13)

**File:** [`ClonerRunner_Fargate.res:100`](../../../reventless/reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L100) (the inline JS)

Derive `clientToken` from `ctx.identity.requestId` (or a hash of `restoreDateTime + user.sub`). Add to the `RunTaskCommand` parameters.

### D.4 — Scheduler `PutRule`+`PutTargets` atomicity (#14)

**File:** [`ScheduledPublisher_CloudWatchEvents_Runtime.res:37-97`](../../../reventless/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L37-L97)

`createSchedule`: wrap PutTargets in `Effect.catchAll`; on failure call `DeleteRuleCommand` to clean up.

`deleteSchedule`: treat `ResourceNotFoundException` from RemoveTargets as success; retry DeleteRule. Surface as a periodic reaper Lambda for orphaned rules (separate cron, scope: list rules with stack prefix that have no targets, delete them).

### D.5 — Scheduler multi-queue support (#41)

**File:** [`ScheduledPublisher_CloudWatchEvents_Runtime.res:36, 77`](../../../reventless/reventless-aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L36)

Replace `getUnsafe(0) // FIXME` with one `EventTarget` per queue resource. Or — if single-queue is the actual contract — assert at deploy time and remove the FIXME.

### D.6 — Counter unbounded `targetRefs` (#23)

**File:** [`CounterHandler_DynamoDbStream_Runtime.res:11-33`](../../../reventless/reventless-aws/src/adapter/Counter/CounterHandler_DynamoDbStream_Runtime.res#L11-L33)

Largest single change in this workstream. Splits Counter into two tables:

- `<Counter>Counts` (existing): the count + total summary, no history.
- `<Counter>SeenRefs` (new): one row per `(counterId, targetRef)`. Partition `counterId`, sort `targetRef`. Used for the idempotency check.

Migration steps:
1. Add the new table and its IAM grants.
2. Replace the `NOT contains(#targetRefs, ...)` condition with `Put({TableName: SeenRefs, ConditionExpression: "attribute_not_exists(targetRef)"})` in a `TransactWriteItems` alongside the count update.
3. Drop `targets` and `targetRefs` from the count item's update expression.
4. Migrate existing data: a one-shot Lambda that reads each existing counter row, fans `targetRefs` into the SeenRefs table, then strips them from the count row. Run before the new code deploys.
5. Remove the deprecated array attributes after all clients have migrated.

This is the most invasive change in the major-fixes plan. Expect ~1 week of work.

### D.7 — AppSync Events 240 KB payload limit (#24)

**Files:** Both AppSync publishers (StateTopic + EventLogSubscription).

Steps:
1. Compute `body.length` before publish.
2. If > 240 000 bytes, replace payload with a `{id, type, truncated: true, fetchUrl}` summary; the client must `fetch(fetchUrl)` to get the full payload.
3. The fetch URL points at a separate Lambda or a presigned S3 URL backed by an "oversized event" bucket.

Alternative (simpler, breaks reliability): reject at publisher with an explicit `OversizedEvent` error. Recommendation: ship the simpler path first, evolve to summary+fetch when an actual case appears.

### D.8 — MCP DCB history server-side filter (#25)

**File:** [`MCP_Lambda.res:257-268`](../../../reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res#L257-L268)

Replace `read(table)(~query=[], ~after?)` (full table scan, in-memory filter) with `read(table)(~query=[{tag: entityIdTag, value: entityId}], ~after?)` (server-side filter via the existing tag query path).

### D.9 — Cloner network config (#38)

**File:** [`ClonerRunner_Fargate.res:103-104`](../../../reventless/reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L103-L104)

Add `~securityGroupIds` and `~assignPublicIp` parameters; pass through to `awsvpcConfiguration`.

### D.10 — Cloner Lambda exec-role principal (#39)

**File:** [`ClonerRunner_Fargate.res:194-198`](../../../reventless/reventless-aws/src/adapter/Cloner/ClonerRunner_Fargate.res#L194-L198)

Verify the assume-role policy on `lambdaRole` includes `lambda.amazonaws.com`. Split into two named roles: `ClonerLambdaExecutionRole` (trust `lambda.amazonaws.com`) and `ClonerAppSyncInvokeRole` (trust `appsync.amazonaws.com`).

### D.11 — AppSync Events Cognito auth provider (#40)

**File:** [`AppSync_EventsApi.res:31-32`](../../../reventless/reventless-aws/src/adapter/Api/AppSync_EventsApi.res#L31-L32)

Add Cognito User Pool as a second `authProvider`. `connectionAuthModes` and `defaultSubscribeAuthModes` accept both AWS_IAM (existing Lambda producers) and `AMAZON_COGNITO_USER_POOLS` (browser subscribers).

Client-side change is out of scope for this plan; document the new auth mode in the docs site.

### D.12 — `Platform_UIDefinitions` pagination cap (#37)

**File:** [`Platform_UIDefinitions_Lambda.res:28-39`](../../../reventless/reventless-aws/src/adapter/Api/Platform_UIDefinitions_Lambda.res#L28-L39)

Cap accumulated items at 5 000. When the cap is hit, emit a header `X-Reventless-Truncated: true` so the UI can warn users; log a `WARN`.

---

## Workstream F — Observability

One cross-cutting finding from the analysis ([XC-1](../../analysis/aws-adapters-broad-review.md#xc-1--major-operational--no-cloudwatch-alarms-no-lambda-concurrency-limits-anywhere)). Pair with workstream C.5 (per-component DLQs) so the new DLQs ship with alarms from day one.

### F.1 — CloudWatch alarms + Lambda concurrency limits (XC-1)

**Files:** every Lambda-creating adapter (CommandTopic, EventCollector, EventTopic, QueryDb stream, Counter, Heartbeat, ScheduledPublisher, MCP, StateTopic, EventLogSubscription, Platform_UIDefinitions, Cloner). The Lambda layer builder ([`reventless-layer-builder`](../../../reventless/reventless-layer-builder)) is *not* in scope.

No CloudWatch alarms or `reservedConcurrency` settings exist anywhere today. A DDB-Stream replay or a misconfigured upstream can exhaust account-wide Lambda concurrency, taking down every Lambda in the account, with no alarm to notice.

Steps:

1. **Per-Lambda `reservedConcurrency` parameter.** Add `~reservedConcurrency: option<int>` to each adapter's `make` function. Default `None` (account default). Production deploys opt in to a per-Lambda cap.

2. **Standard alarm bundle.** A new `Util_Alarms` module exporting helpers:
   - `lambdaErrorRateAlarm(~lambda, ~thresholdPercent=5.0, ~periodSeconds=300)` — alarm if error rate > 5 % over 5 min.
   - `lambdaThrottleAlarm(~lambda, ~periodSeconds=60)` — any throttle in the last minute.
   - `lambdaDurationAlarm(~lambda, ~p99ThresholdMs)` — p99 duration above threshold.
   - `sqsQueueDepthAlarm(~queue, ~thresholdMessages=1000, ~periodSeconds=300)` — queue backlog.
   - `sqsMessageAgeAlarm(~queue, ~thresholdSeconds=600, ~periodSeconds=300)` — oldest message age (catches stuck consumers).
   - `dlqDepthAlarm(~dlq, ~periodSeconds=300)` — any message in the DLQ.
   - `dynamodbThrottleAlarm(~tableName, ~periodSeconds=60)` — `ReadThrottleEvents` or `WriteThrottleEvents` > 0.

3. **Per-component opt-in.** Each adapter's `make` accepts an optional `~alarms` parameter (record of which alarms to enable + thresholds). Default `None` (preserves current behaviour); production-grade callers pass `~alarms=Some(Util_Alarms.standardBundle)`.

4. **Alarm notification target.** Alarms publish to an SNS topic configurable per-platform. Default: a platform-level `<stack>-alarms` topic, subscriber-less by default. Operators wire their PagerDuty / Slack subscription externally.

5. **Documentation.** New page in `packages/doc/docs/inner-workings/observability.md` covering the alarm catalogue, recommended thresholds, and how to subscribe.

**Tests:** verify each `Util_Alarms.*` helper produces the expected `MetricAlarm` resource with correct dimensions. Per-adapter tests are unnecessary — opting in is a single parameter.

**Effort:** Medium (~3–5 days). Pair with workstream C.5 — the new per-component DLQs ship with `dlqDepthAlarm` from day one.

**Sequencing note:** F.1 depends on C.5 (per-component DLQs) for the DLQ alarms to have meaningful targets. Either land C.5 first, or land F.1 with the DLQ alarm helper deferred to after C.5.

---

## Workstream E — Architectural followups

Two findings that need design discussion, not just implementation.

### E.1 — SNS dual-write outbox for cross-plugin events (#8)

**Files:** [`EventTopicPublisher_SNS.res`](../../../reventless/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS.res), `Plugin_ExtensionPoint_Builder.res` (in core).

ExtensionPoint events use the SNS publisher, which is a non-transactional dual write (DDB commit then SNS publish). If SNS publish fails after commit, the event is durable but never reaches subscribers — silent loss across plugins.

Two options:

1. **Streams subscriber pattern:** treat ExtensionPoint events as DDB-Stream subscribers. Cross-plugin subscribers attach an EventCollector to the upstream EventLog stream directly. Removes SNS from the publish path. Caveat: changes the cross-plugin coupling shape.
2. **Outbox sweeper:** add a `pending_publish` attribute on the event row; a sweeper Lambda retries publishes until acknowledged. Keeps current shape but adds infrastructure.

Recommendation: option 1 if the new shape is acceptable to plugin authors; option 2 otherwise.

This is a multi-week design + implementation; treat as a separate spike before scheduling.

### E.2 — SNS fan-out cost documentation (#43)

**File:** [`docs/inner-workings/`](../../packages/doc/docs/inner-workings/) (the docs site)

Document the SNS-vs-Streams cost model. SNS publish $0.50/M (FIFO $1.00/M) plus per-subscriber delivery $0.40/M; DDB-Streams reads are $0.20/M unmetered per subscriber. Platforms with many ExtensionPoints + high event throughput see SNS dominate AWS bill. Recommend Streams fan-out where feasible.

This is a doc PR. No code change.

---

## Sequencing

Suggested order, balancing risk and reward:

1. **Workstream A first** (silent-data-loss). Single-PR-each, narrow-blast-radius. ~1 week total.
2. **Workstream C** (hardening). Mechanical, high signal-to-noise. ~3–4 days.
3. **Workstream F** (observability). Lands together with C.5 so new DLQs ship with alarms. ~3–5 days.
4. **Workstream B** (cost capping). Independent items; pick-off-able. Ship #15 (consistentRead) first as biggest win. ~1 week total.
5. **Workstream D.1–D.5, D.7–D.12** in parallel with D.6.
6. **Workstream D.6** (Counter table split) — separate week, requires data migration.
7. **Workstream E** — design spike, then plan, then implement.

Total span: 5–7 weeks at ~50 % engineering capacity.

## Verification

Each workstream PR must:
- `pnpm run build 2>&1 | grep -E "Warning|warning|error|Error"` — clean.
- New tests for the modified adapters.
- For workstream D.1 specifically: integration test against a real DDB-Stream event (`reventless-in-memory` adapter doesn't exercise this).
- For workstream D.6 specifically: full migration smoke test against a representative test environment before any prod migration.
