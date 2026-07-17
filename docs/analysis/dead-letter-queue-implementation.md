# Dead Letter Queue Implementation — Analysis

**Status:** Analysis (no implementation steps here — see "Cross-references" for the planned work)
**Date:** 2026-05-12
**Scope:** The DLQ wiring in the AWS adapters (`reventless/aws/`). The in-memory adapter has no DLQ concept; this is AWS-specific.

---

## TL;DR

- The unit is the **Pulumi stack**, not the platform. `Util_DeadLetterQueue.res` builds its queues as *module-level bindings* — a ReScript/JS module is a per-program singleton — so every stack that pulls the module in (any stack with a CommandTopic or EventCollector, i.e. every plugin stack and the platform-admin stack) gets **exactly two DLQs**: one standard SQS queue (`DeadLetterQueue`) and one FIFO SQS queue (`FIFODeadLetterQueue`), both in [`Util_DeadLetterQueue.res`](../../reventless/aws/src/util/Util_DeadLetterQueue.res).
- Reventless deploys **one Pulumi stack per plugin** (`catalog-aws`, `ordering-aws`, …) plus a separate platform-admin stack (`Platform.deployPlugin` vs `Platform.deployPlatform`; see `examples/online-shop-hybrid/deploy-manifest.yaml`). So a platform with N plugins has ~`2 × (N + 1)` DLQs — **not two globally**. Within any one plugin stack, though, those two DLQs are shared by *all* of that plugin's CommandTopics, EventCollectors, and EventLogSubscriptions.
- Every consumer queue (CommandTopic in 4 variants, EventCollector in 2–3 variants, EventLogSubscription→AppSync) sets a `redrivePolicy` with `maxReceiveCount=5` pointing at one of the stack's two DLQs.
- The DLQ "handler" is a 3-line Lambda: `console.error("DEAD LETTER ITEM:", JSON.stringify(event))`. No metric, no alarm, no retention override, no archive, no redrive-back tooling.
- **Do we need two queues?** Yes — the split is *FIFO vs standard*, which is forced by AWS (a FIFO source queue's DLQ must itself be FIFO; a standard source queue's DLQ must be standard), and Reventless has both kinds of source queue in a single stack. You cannot collapse to one. The thing that's wrong isn't the count *two* — it's that those two are shared across **all component types within a plugin stack**: when something DLQs you can't tell whether it's the Orders aggregate's CommandTopic or the Orders read model's EventCollector without parsing bodies, and a flooding EventCollector drowns unrelated CommandTopic failures. (Cross-*plugin* attribution is already fine — different plugins are different stacks with different DLQs.) The right shape is *per-component-type* DLQs within each stack, each still split FIFO/standard where the source needs it.
- Error handling and monitoring are essentially absent. Concrete improvements below; the planned fix is workstream **C.5** in [`aws-adapters-major-fixes.md`](../plans/Backlog/aws-adapters-major-fixes.md), paired with the alarm bundle in **F.1**.

---

## 1. What exists today

### 1.0 Deployment topology — the scoping unit is the stack

Reventless splits an AWS deployment into multiple Pulumi stacks: a **platform-admin stack** (`Main.res` → `Platform.deployPlatform` — admin components, scheduler, shared AppSync API) and **one stack per plugin** (`Main.res` → `Platform.deployPlugin`). See `examples/online-shop-hybrid/` (`platform-aws/`, `catalog-aws/`, `ordering-aws/`) and its `deploy-manifest.yaml` (which also encodes plugin deploy order). The runtime strategies (Single / PerAggregate / Micro) only affect *Lambda packaging within* a plugin stack — they do not merge plugins into one stack.

`Util_DeadLetterQueue.res` builds `queue`, `fifoQueue`, the handler Lambda, the two event-source mappings, and the IAM policies as **top-level module bindings** — they run when the module is first imported into a Pulumi program, exactly once per program. Any stack whose dependency graph includes a CommandTopic-SQS channel or an EventCollector-SQS channel pulls `Util_DeadLetterQueue` in (the channel adapters reference `Util_DeadLetterQueue.fifoQueue.arn` etc.). Every plugin has ≥ 1 aggregate → ≥ 1 CommandTopic → it pulls the module in; the platform-admin stack has the admin Plugin aggregate → it pulls it in too.

**Net effect:** **two DLQs per stack** → ≈ `2 × (numPlugins + 1)` DLQs per platform. Not two for the whole platform. Cross-*plugin* poison is naturally separated (catalog's DLQ ≠ ordering's DLQ); cross-*component-type* poison within a plugin is not.

### 1.1 The two per-stack DLQs

[`Util_DeadLetterQueue.res`](../../reventless/aws/src/util/Util_DeadLetterQueue.res) creates, at module-eval time (module-level side effects — itself a smell; see §3.6):

| Queue | Name | Type | Visibility timeout | Encryption | Retention | Dedup |
|---|---|---|---|---|---|---|
| `queue` | `DeadLetterQueue` | standard | 180 s | `sqsManagedSseEnabled: false` | AWS default (4 days) | n/a |
| `fifoQueue` | `FIFODeadLetterQueue` | FIFO | 180 s | `sqsManagedSseEnabled: false` | AWS default (4 days) | content-based |

A single Lambda (`DeadLetterQueue`, nodejs22.x, 128 MB, 30 s timeout, on the Reventless layer) is subscribed to **both** queues via `Util_EventSourceMapping.subscribeSqs`. Its entire body:

```js
export const handler = async (event) => {
  console.error("DEAD LETTER ITEM:", JSON.stringify(event));
};
```

IAM is reasonably tight (queue policies scope `sqs:ReceiveMessage/DeleteMessage/GetQueueAttributes` to the handler's `SourceArn`; the role gets logging + send/receive on the two queue ARNs). Note the role/policy plumbing is gated behind a single `Pulumi.Output.all5(...).apply(...)` — it works but couples five outputs into one closure unnecessarily.

There is a `// TODO: move DeadLetterQueue creation into separate Adapter and use it from Plugin_Builder` at the top of the file — i.e. the current author already flagged that this should be a proper adapter, not a globally-evaluated module.

### 1.2 Who points at which DLQ

All consumers use the same redrive shape:

```rescript
redrivePolicy: Util_DeadLetterQueue.<queue|fifoQueue>.arn
  ->Pulumi.Output.apply(dlqArn =>
    PulumiAws.SQS.Queue.RedrivePolicy.make(~deadLetterTargetArn=dlqArn, ~maxReceiveCount=5))
  ->Pulumi.Output.asInput
```

| Consumer adapter | Source queue type | DLQ used | Source visibility timeout |
|---|---|---|---|
| `CommandTopicChannel_SQS_FIFO` | FIFO | `fifoQueue` | 180 s (`6*30`) |
| `CommandTopicChannel_SQS_Async` | FIFO | `fifoQueue` | (see file) |
| `CommandTopicChannel_SQS` | standard | `queue` | (see file) |
| `CommandTopicChannel_SQS_Sync` | standard | `queue` | (see file) |
| `EventCollectorChannel_SQS_FIFO` | FIFO | `fifoQueue` | 30 s (`// TODO fix timeout`) |
| `EventCollectorChannel_SQS` | standard | `queue` | 120 s |
| `EventLogSubscription_AppSync` (SQS buffer) | standard | `queue` | 60 s |

`maxReceiveCount=5` everywhere. No `bisectBatchOnFunctionError`, no `maximumRetryAttempts`, no `functionResponseTypes: [ReportBatchItemFailures]`, no `destinationConfig.onFailure` — even though the Pulumi bindings for all of those exist in [`EventSourceMapping.res`](../../rescript/rescript-pulumi-aws/src/Lambda/EventSourceMapping.res). The DDB-Stream sources (EventLog → EventTopic) have **no DLQ at all** — a poison stream record retries until the 24 h stream-record TTL and is then lost (covered separately in the aggregate command-handling review and broad review §2.1).

### 1.3 Retry semantics (for reference)

SQS redrive is *receive*-counted, not *error*-counted: a message is moved to the DLQ after 5 receives during which the consumer failed to `DeleteMessage` it before the visibility timeout elapsed. With Lambda+SQS event-source mapping, a thrown handler error → the whole batch's messages stay un-deleted → they redeliver after the visibility window → after 5 such cycles → DLQ. There is no backoff between cycles beyond the visibility timeout itself. For the FIFO CommandTopic this interacts with the OCC retry budget: `maxConflictRetries` (3) × `maxReceiveCount` (5) bounds how many times a conflicting command is attempted before it DLQs.

---

## 2. What works well

1. **It exists and it's wired consistently.** Every SQS-backed consumer has a redrive policy with the same `maxReceiveCount`. Nothing falls on the floor at the SQS layer — poison messages have a terminal home rather than redelivering forever.
2. **FIFO/standard pairing is correct.** FIFO source queues point at the FIFO DLQ and standard at the standard DLQ, which is the constraint AWS enforces. Ordering of poison messages within a message group is preserved on the FIFO side, which matters if you ever redrive.
3. **IAM is least-privilege-ish.** The queue policies pin the consuming Lambda by `SourceArn`; the Lambda role only has logging + the two queue ARNs. No `Resource: "*"`.
4. **`contentBasedDeduplication` on the FIFO DLQ** means a redelivered-then-DLQ'd message isn't duplicated in the DLQ if its body is byte-identical.
5. **One handler, one Lambda** — trivially cheap; nothing to operate. (This is also the source of the weaknesses below; it's a fine *default*, just not a fine *only* option.)
6. **The author already knows the shape is wrong** — the TODO and the existence of the C.5 backlog item mean this isn't an unrecognised gap.

---

## 3. What could be improved

### 3.1 Observability is zero — `console.error` is not monitoring

A DLQ that nobody watches is a data-loss queue with extra steps. There is:
- no CloudWatch metric on DLQ arrivals (so no dashboard, no "messages in DLQ" number anywhere except CloudWatch's built-in `ApproximateNumberOfMessagesVisible`, which nobody is alarmed on);
- no alarm — a platform can accumulate thousands of dead messages and the first signal is a customer complaint;
- no structured log — `JSON.stringify(event)` of a raw SQS batch event is not queryable; you can't filter by source component, by error type, by aggregate id.

### 3.2 Per-stack sharing across component types collapses attribution

Within a plugin stack, two buckets serve every CommandTopic, every EventCollector, and the EventLogSubscription buffer. So if the `Orders` aggregate's CommandTopic starts DLQ-ing because of a deserialization bug, those messages sit in the same FIFO DLQ as a misbehaving `OrdersByStatus` read model's EventCollector. You can't alarm "the Orders command path is failing" separately from "the Orders projection path is failing". You can't drain one without scanning the other. You can't set a different retention or a different redrive policy per component type. The blast radius of *one noisy component* is *all DLQ observability for that plugin*. (Across plugins it's already fine — different stacks, different DLQs — so this is narrower than "the whole platform", but still the dominant operability gap once a plugin has more than one component.)

### 3.3 No redrive tooling

There is no "redrive back to source" path — not the SQS-native `StartMessageMoveTask`, not a script, not a runbook. Once a message is in the DLQ, recovering it after you fix the bug is a manual console exercise. (For FIFO this is genuinely fiddly because you must preserve message-group ordering.)

### 3.4 Retention is the AWS default (4 days)

Nothing sets `messageRetentionSeconds`. A poison message that arrives Friday night is gone by Wednesday. For a DLQ — whose entire purpose is "hold this until a human looks" — 14 days (`1209600`) is the conventional floor.

### 3.5 No batch-item-failure reporting on the consumers

Because the consumers don't return `{batchItemFailures: [...]}` and the ESMs don't set `functionResponseTypes: [ReportBatchItemFailures]`, a single bad message in a batch of 10 fails the whole batch — the 9 good messages redeliver and re-execute (re-running idempotent-but-not-free work) and accrue receive counts toward *their own* DLQ threshold. A truly poison message can drag 9 innocent ones to the DLQ with it over enough cycles. (This is broad-review §2.1 / §1.1; mentioned here because it directly inflates DLQ traffic.)

### 3.6 The module-level side-effect construction

`Util_DeadLetterQueue.res` builds real Pulumi resources at module evaluation time, so merely `open`-ing or referencing the module from any adapter pulls the DLQ into the stack. That's why it can't be parameterised (no encryption toggle, no retention, no per-stack naming, no "use my existing DLQ"), can't be omitted (e.g. a stack that wires only a read model still gets both queues), and can't be tested in isolation. The TODO says it: this should be a `*_Adapter` consumed by `Plugin_Builder`.

### 3.7 No encryption

`sqsManagedSseEnabled: false` on both DLQs. Dead-lettered command/event bodies contain full domain payloads (and `meta`). If the platform encrypts its primary queues/tables it should encrypt the DLQs too — they hold the same data, just older.

### 3.8 No DLQ for DDB-Stream sources

EventLog→EventTopic uses a DynamoDB Streams event-source mapping with no `destinationConfig.onFailure`. A poison stream record blocks the shard, retries until 24 h, then vanishes. This is arguably the most dangerous gap because it's *silent* and the data is *already committed*. (Tracked in the aggregate command-handling review; flagged here for completeness — a "DLQ" story isn't complete without it.)

---

## 4. Do we really need two different queues?

**Two is the floor, given AWS constraints — but the split should be by component-type, not just FIFO-vs-standard, and the count should grow with the number of component types, not be fixed at two.**

### Why you can't go to one

AWS requires a FIFO queue's redrive target to be FIFO and a standard queue's target to be standard. Reventless has both kinds of source queue:
- **FIFO** sources: the FIFO CommandTopic (per-aggregate ordering via `MessageGroupId` — this is load-bearing for OCC) and the FIFO EventCollector.
- **Standard** sources: the non-FIFO CommandTopic variants, the non-FIFO EventCollector, the EventLogSubscription→AppSync buffer.

So you need *at least one of each*. Collapsing to a single queue is not an option without dropping FIFO entirely, which you can't.

### Why two-per-stack isn't *enough* either

The current "two per stack" buys you nothing on the *within-plugin* attribution axis — see §3.2. The useful unit is **(component-type) × (FIFO|standard, where applicable)**, per stack:

| Component type | FIFO DLQ | Standard DLQ |
|---|---|---|
| CommandTopic | `CommandTopicDLQ.fifo` | `CommandTopicDLQ` |
| EventCollector | `EventCollectorDLQ.fifo` | `EventCollectorDLQ` |
| EventLogSubscription (AppSync buffer) | — | `EventLogSubscriptionDLQ` |
| EventTopic / DDB-Stream onFailure (new — see §3.8) | — | `EventTopicDLQ` |

That's ~5–7 queues *per stack* (so ~5–7 × (numPlugins + 1) per platform), still all fanning into **one** DLQ-processor Lambda within each stack (the handler doesn't care which queue an event came from beyond stamping a `source` dimension). The cost delta of a few empty SQS queues is rounding error; the operability delta is large: you can alarm, drain, retain, and redrive per component type within a plugin. If even finer granularity is ever wanted (per *named* aggregate, not per *type*) it's a follow-on, but per-type is the right first cut. Plugin-level separation already comes for free from the stack-per-plugin topology — no work needed there.

### Could we instead go the *other* way — 2 (or ~6) DLQs shared across the whole platform?

I.e. *fewer* DLQs by hoisting them out of the per-plugin stacks into the platform-admin stack. **It's feasible** — Reventless already does exactly this for the shared AppSync API ("deploy this stack first; plugin stacks reference its outputs"). Concretely:

1. Make `Util_DeadLetterQueue` a real adapter that *takes* DLQ ARN(s) instead of creating queues at module-eval time (this is the §3.6 cleanup / a C.5 prerequisite anyway).
2. The platform-admin stack (`deployPlatform`) creates the queues + the processor Lambda and exports the ARNs as stack outputs.
3. Plugin stacks read those ARNs via `StackReference` (the same mechanism `Platform.deployPlugin` already uses for the core API) and set their `redrivePolicy` to the cross-stack ARN.
4. No extra IAM needed *as long as every stack deploys to the same AWS account + region* — SQS redrive is intra-account and Pulumi just needs the ARN. (The processor Lambda's queue policy stays pinned to the Lambda's own `SourceArn`; unchanged.)

**Advantages of platform-wide DLQs:**
- ~2 (or ~6 if also split by component-type) queues total instead of ~2(N+1) — less resource clutter, one processor Lambda instead of one per stack.
- A single dashboard / single alarm set covers *everything* natively, with no cross-stack metric aggregation.
- One redrive target, one retention/encryption config to manage.

**Consequences / why I'd be cautious:**
- **You give up the *free* cross-plugin attribution.** Today catalog poison and ordering poison are already in different queues because they're different stacks. Collapse to platform-wide and they're mixed again — you now *require* a `plugin`/`source` message attribute + a dimensioned `ReventlessDeadLetterCount` metric to tell them apart. (You want those anyway, but here they go from "nice" to "load-bearing".)
- **It adds the DLQ to the platform→plugin deploy-ordering dependency.** Platform must deploy before any plugin (already true for the API, so not *new* — but now the DLQ is on that critical path, and tearing down the platform stack while plugin stacks still reference its DLQ ARNs breaks them).
- **One processor Lambda = platform-wide blast radius.** A bug or throttle in it stalls *all* dead-letter handling everywhere. Fine while the handler is 3 lines of `console.error`; less fine once it does S3 archive + metric emission + alerting.
- **It forecloses multi-account-per-plugin topologies.** SQS requires a DLQ to be in the same account + region as its source queue — cross-account redrive is *not supported*. If plugins ever land in separate AWS accounts (a common landing-zone pattern), platform-wide DLQs are simply impossible; you'd be back to per-account DLQ sets. Per-stack DLQs are topology-agnostic.
- **It doesn't actually fix the real problem.** §3.2 is about *within-plugin, cross-component-type* mixing. Going platform-wide doesn't address that at all (arguably makes it worse). You'd still want the per-component-type split — just located in the platform stack and shared. So "2 per platform" is *orthogonal* to C.5, not a replacement; "~6 per platform, shared" is C.5 done in the platform stack.

**Bottom line on this option:** literally *two* per platform (FIFO + standard only, shared by everyone) takes the cross-stack-coupling and blast-radius and multi-account costs *and* loses today's free attribution — worst of both. If you do want consolidation, do **per-component-type-in-the-platform-stack** (~6 shared queues, one processor Lambda, native single dashboard) and accept the cross-stack dependency + single-account constraint as a deliberate trade. Otherwise, keep DLQs per-stack and get the "one pane of glass" by aggregating the per-stack metric (it's dimensioned by stack + source) — which is the lower-risk default and is what C.5 assumes.

### Verdict

- **You can't go below two per stack** — FIFO/standard is AWS-forced.
- **The right *next* move is per-component-type, per stack** (C.5 as written): best attribution, zero new cross-stack coupling, topology-agnostic. ~5–7 queues per stack, one processor Lambda per stack.
- **Platform-wide consolidation is a legitimate alternative** *if* the deployment is committed to single-account and you value one-native-dashboard over topology flexibility — but do it as "per-component-type in the platform stack", not "literally two", and treat it as an explicit architecture decision (it changes the stack dependency graph).
- Either way, the *handler* changes (structured logs, `source` dimension, metric, retention, optional S3 archive) and the *alarms* are the same work and are where most of the value is — see §5 and §6.

---

## 5. How error handling could be improved

1. **Stop failing whole batches.** Thread per-record success through `handleCommands`/`handleEvents`, return `{batchItemFailures: [{itemIdentifier}]}`, and set `functionResponseTypes: [ReportBatchItemFailures]` on the SQS ESMs. Only genuinely-poison messages accrue receive count; innocents in the batch are deleted on first success. (Broad-review §2.1.) This is the single highest-leverage error-handling change because it shrinks DLQ traffic to *actually-bad* messages.
2. **Distinguish "transient" from "poison" at the consumer.** A timeout / throttled-downstream / OCC-conflict is transient and *should* redeliver; a JSON-parse failure / schema-mismatch / unknown-command-type is poison and should go straight to the DLQ (or a `parkMessage`-style fast path) rather than burning 5 cycles. Today everything is the same generic "throw → redeliver" path.
3. **Add `destinationConfig.onFailure` to the DDB-Stream ESMs** (EventLog→EventTopic) pointing at a standard `EventTopicDLQ`, plus `bisectBatchOnFunctionError: true` and a sane `maximumRetryAttempts`. Closes the silent-loss gap (§3.8).
4. **Carry structured failure context into the DLQ message.** When a consumer parks a message, attach `messageAttributes` (`source`, `errorType`, `errorMessage`, `attemptCount`, `originalQueueArn`) so the DLQ handler — and any human draining the queue — doesn't have to reverse-engineer what happened from a raw body.
5. **Make `maxReceiveCount` per-component-configurable.** 5 is fine for CommandTopic-with-OCC; an EventCollector that's purely a projection writer might want 3, a flaky cross-region call might want 10. It's currently a hard-coded literal in every adapter.
6. **Make the DLQ an adapter** (`DeadLetterQueue_Adapter` / `Util` → real adapter) so encryption, retention, naming prefix, and "bring your own DLQ" are parameters, not edits to a globally-evaluated module (§3.6).

## 6. How monitoring of the DLQ could be improved

1. **CloudWatch metric on arrival.** The DLQ-processor Lambda emits `ReventlessDeadLetterCount` (count = batch size) dimensioned by `Source` (component type) and ideally `Stack`. Now you have a graph and an alarm target.
2. **An alarm per DLQ:** `ApproximateNumberOfMessagesVisible > 0` for 5 minutes → notify (SNS topic / PagerDuty / whatever the platform wires). A DLQ should be empty in steady state; *any* sustained content is an incident.
3. **An age alarm too:** `ApproximateAgeOfOldestMessage` on each DLQ — catches the case where messages arrive slowly enough to never trip a count alarm but still rot past retention.
4. **Structured JSON logs** from the handler: `{ "@type": "dead_letter", "source": "...", "stack": "...", "messageId": "...", "approximateReceiveCount": N, "body": {...}, "messageAttributes": {...}, "ts": "..." }` — queryable in CloudWatch Logs Insights, parseable by any log shipper.
5. **A "DLQ status" surface.** Either a tiny read model / admin query ("how many dead messages, by component, oldest age") or just a documented dashboard. Today the only place this information lives is the SQS console.
6. **Set `messageRetentionSeconds: 1209600` (14 days)** on every DLQ so the alarm has time to be noticed and acted on before AWS deletes the evidence.
7. **Optional S3 archive** (off by default, a parameter): the handler also writes each dead message to `s3://<bucket>/dead-letters/<source>/<date>/<messageId>.json`. Survives the 14-day window, gives you a forensic record and a replay source. C.5 lists this as optional; for any platform that handles money it should be on.
8. **Wire the DLQ alarms into the same bundle as the rest** — `Util_Alarms` (proposed in workstream F.1) gets a `dlqDepthAlarm(~dlq, ~periodSeconds=300)` helper, and the per-component-DLQ adapter calls it automatically, so new DLQs ship with alarms from day one rather than as a follow-up.

---

## 7. Recommended order of attack

1. **C.5 — per-component-type DLQs + structured handler + metric + retention + alarms.** Self-contained, mechanical, high signal. ([`aws-adapters-major-fixes.md` §C.5](../plans/Backlog/aws-adapters-major-fixes.md).) Land the alarm helper from F.1 alongside it.
2. **Batch-item-failure reporting on SQS consumers** (broad-review §2.1) — biggest reduction in DLQ *volume*; makes everything downstream quieter.
3. **`onFailure` DLQ on the DDB-Stream ESMs** (§3.8 / aggregate command-handling review) — closes the one *silent* data-loss path.
4. **Promote `Util_DeadLetterQueue` to a real adapter** (the file's own TODO) — unblocks encryption, retention, naming, BYO-DLQ.
5. **Transient-vs-poison classification + structured failure context on park** — quality-of-life and faster recovery; do after the structure above exists.
6. **Redrive tooling / runbook** — once DLQs are per-component this is a small, well-scoped script.

---

## Cross-references

- [`docs/plans/Backlog/aws-adapters-major-fixes.md`](../plans/Backlog/aws-adapters-major-fixes.md) — **workstream C.5** (per-component DLQs + observability, issue #36) and **workstream F.1** (CloudWatch alarms + Lambda concurrency, the `Util_Alarms` bundle; explicitly sequenced to land with C.5 so DLQs ship with alarms).
- [`docs/analysis/aws-adapters-broad-review.md`](./aws-adapters-broad-review.md) — §1.1 (zip-misalignment corrupts the DLQ-redrive path), §1.2 (non-FIFO CommandTopic ordering → spurious DLQ), §2.1 (no batch-item-failure reporting), XC-1 (no alarms / concurrency limits anywhere).
- [`docs/analysis/aggregate-command-handling-review.md`](./aggregate-command-handling-review.md) — `maxConflictRetries × maxReceiveCount` interaction; the DDB-Stream no-DLQ gap on EventLog→EventTopic.
- [`docs/analysis/done/end-to-end-error-handling.md`](./done/end-to-end-error-handling.md) — broader error-propagation context (decide/propagate errors), upstream of where messages become DLQ-bound.
- [`reventless/aws/src/util/Util_DeadLetterQueue.res`](../../reventless/aws/src/util/Util_DeadLetterQueue.res) — the implementation under discussion.
- [`reventless/aws/src/util/Util_EventSourceMapping.res`](../../reventless/aws/src/util/Util_EventSourceMapping.res) — `subscribeSqs` / `subscribe`; the place `destinationConfig.onFailure` and `functionResponseTypes` would be threaded.
- [`rescript/rescript-pulumi-aws/src/Lambda/EventSourceMapping.res`](../../rescript/rescript-pulumi-aws/src/Lambda/EventSourceMapping.res) — bindings already expose `destinationConfig`, `functionResponseTypes`, `bisectBatchOnFunctionError`, `maximumRetryAttempts`.
