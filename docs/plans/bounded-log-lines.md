# Plan: a framework log line's size must not grow with the data it describes

**Date:** 2026-09-04
**Status:** **All five steps implemented (1–4 on 2026-09-04, 5 on 2026-09-05), none deploy-verified.**
Found by attributing a deployed alpha estate's CloudWatch bill to log groups and dividing by
invocation count. Steps 1–4: full build warning-free, 387 suites / 4169 tests green. Step 5 was
verified against the `reventless-aws` package alone (69 suites / 814 tests) because an unrelated
in-progress change had the workspace build red at the time.
**Repos:** `reventless-core` only.

**Goal.** No log line the framework emits has a size that grows without bound. A line
describing a state, an event or a message carries the *identity* of that thing — id,
sequence, type, size — not its serialisation.

**Non-goal.** Changing log *levels* or *retention* — those are tiered by
[env-tiered-log-retention-and-levels.md](env-tiered-log-retention-and-levels.md) and the
tiering is correct. Also not the `comp` vocabulary or the fields around a line, which is
[component-logs-detached-from-invocation.md](component-logs-detached-from-invocation.md).
Both of those plans declare log *content* out of scope; this is the plan that owns it.

---

## The finding

Two framework log sites emit lines whose size is a function of accumulated history rather
than of the event being handled. Measured over one month on a deployed alpha estate:

| Handler | Invocations | Log volume | Bytes / invocation |
|---------|-------------|-----------|--------------------|
| Aggregate command handler | ~44,800 | 17.2 GB | **~384,000** |
| Dead-letter handler | 1,260,352 | 3.12 GB | ~2,470 |

A Lambda that logs only `START`/`END`/`REPORT` sits at ~200 bytes per invocation. The
aggregate command handler is **~1,900× that**, and it was the single largest log producer in
the estate — larger than every command handler, projection and slice combined.

Neither number is driven by traffic. The first is driven by *how long the system has been in
use*; the second by *how long a failure is left unattended*.

## Defect A — the aggregate state is serialised into a `DEBUG` line

Two call sites, same shape:

- [Aggregate_Callback.res:77](../../reventless/core/src/components/Aggregate/Aggregate_Callback.res#L77)
- [StateChangeSlice_Callback.res:318](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res#L318)

```rescript
EffectLogger.logDebug(
  ~comp,
  `deciding on state: ${state->JSON.stringifyAny->Option.getOr("<unserializable>")}`,
)
```

`state` is the aggregate's **entire folded state**. For a plugin aggregate that state carries a
map of every version it has ever seen, each holding a full definition:

```
"deciding on state: {"current":"1.0.0-alpha.227",
  "known":{"1.0.0-alpha.173":{"definition":{"id":"...","extensionPoints":[...
```

Three properties compound:

1. It fires on **every command**, including unattended `Heartbeat` traffic.
2. The state **only ever grows** — a new released version adds a `known` entry and nothing
   removes one.
3. The line is therefore **unbounded in the project's own release count**, and its cost rises
   as a direct function of doing normal work.

This is a defect at any level. `debug` is the correct tier for a dev stack, and the tiering
plan is right to set it — but a `DEBUG` line is still expected to be *a line*, not a database
dump. The framework should not offer a log statement whose size no operator can predict.

### Fix A

Log the identity and shape of the state, never its serialisation:

```rescript
EffectLogger.logDebug(
  ~comp,
  `deciding: id=${id} seq=${seq} cmd=${commandName}`,
)
```

The state's *content* at decision time is a debugger's concern, not a log's. If it must remain
reachable, gate it behind an explicit opt-in that is off in every tier — a `LOG_STATE`
env flag read once at module load, not a level check — so that turning it on is a deliberate,
temporary act rather than a side effect of running a dev stack.

Apply to both call sites. Audit for the same pattern elsewhere:

```
grep -rn 'JSON.stringifyAny' reventless/*/src | grep -i 'log'
```

Any log line interpolating a whole `state`, `event`, `command` or `payload` is in scope.

## Defect B — the dead-letter handler dumps the full record, and re-dumps it forever

[Util_DeadLetterQueue.res:70-76](../../reventless/aws/src/util/Util_DeadLetterQueue.res#L70-L76):

```js
export const handler = async (event) => {
  console.error("DEAD LETTER ITEM:", JSON.stringify(event));
  throw new Error("Dead-lettered " + ... + " message(s); ... Failing so the messages are retained and Errors is non-zero.");
};
```

**The design intent is correct and should be preserved.** The comment above it records why:
returning success let SQS delete the message, so queue depth returned to 0 and `Errors` stayed
0, and a plugin failing every 5 minutes for two days produced 217 dead letters and no signal at
all. Failing keeps both alarm subjects alive. That reasoning stands.

What it did not account for is the **cost of the retry**. An SQS event-source mapping returns a
failed batch to the queue; with `visibilityTimeoutSeconds: 180` the same message is redelivered
indefinitely until `messageRetentionSeconds` expires. Measured consequence for a handful of
poison messages — the sampled window shows **two distinct `messageId`s**:

- **1,260,352 invocations** at a **100% error rate**, sustained for 14 days.
- **3.12 GB** of logs, because the whole SQS record — body, attributes and `receiptHandle` —
  is re-serialised on every redelivery at ~2.5 KB.
- The queue never drains, so the event-source mapping **scales up its pollers**, adding ~1.9M
  empty receives on top.
- It ended only when the messages hit the retention wall. Nothing detected or stopped it.

The comment's own claim — *"Re-delivery re-logs the payload; on a queue that is empty in normal
operation, that repetition is the alert"* — is where the gap is. Repetition at ~95,000
invocations/day is not an alert; it is a bill.

### Fix B

Keep both signals (`Errors` non-zero, message retained), bound the volume:

1. **Log identity, not the record.** `messageId`, `DeadLetterQueueSourceArn`,
   `ApproximateReceiveCount` and body *length* — not the body. Cuts the line ~10× and stops
   writing message payloads to CloudWatch, which also matters for anything personal in them.
2. **Log the full record at most once per message.** `ApproximateReceiveCount === 1` is
   available on the record and is the natural guard: the first delivery carries the diagnostic,
   later ones carry a one-line repeat.
3. **Bound the redelivery itself.** Either cap the event-source mapping's retry attempts, or
   raise the DLQ's `visibilityTimeoutSeconds` substantially (a dead letter has no latency
   requirement — 15 minutes instead of 180 s cuts invocations 5×).

Option 2 alone removes ~90% of the volume and is a two-line change; do it first.

## Related, already tracked

The `DeadLetterQueue-*` log groups carry **`retentionInDays: None`** while sibling handlers'
groups are set to 7 days — so this volume is retained forever once written. That is the tail of
[env-tiered-log-retention-and-levels.md](env-tiered-log-retention-and-levels.md) **Step 8**,
which this finding independently confirms is still outstanding and now has a measured cost.

**Fixed here after all**, because the cause turned out to be local rather than a gap in the tiering:
this is the one Lambda in the framework built by hand instead of through `RuntimeEnvironment_Lambda`,
so it was the one Lambda that never called `makeManagedLogGroup` and fell back to the group Lambda
auto-creates, which carries no retention. It now takes the same managed group and the same tiering as
every other handler, and its `logLocator` points at the real group rather than the hardcoded
`~logGroup=None` that assumed the unmanaged shape.

The three existing groups (1.3 GB) are left as they are: storage is ~$0.03/GB-month, so deleting them
saves cents and destroys the only record of both incidents. The ingestion was the expensive part and
is already paid.

## Steps

| # | Change | Effort | State |
|---|--------|--------|-------|
| 1 | Fix B option 2 — guard the full-record dump on `ApproximateReceiveCount === 1` | ~2 lines | **done** |
| 2 | Fix B option 1 — log identity fields instead of the record | small | **done** |
| 3 | Fix A — replace both `deciding on state` lines with id/seq/command | small | **done** |
| 4 | Audit `JSON.stringifyAny` in log positions across `reventless/*/src` | ~1h | **done** |
| 5 | Fix B option 3 — bound redelivery via ESM retries or visibility timeout | infra, needs a deploy | **built, not deployed** |

Steps 1–3 are independent and each ships on its own.

### What was built (steps 1–4)

**Steps 1 + 2 shipped as one handler, not two passes.** Options 1 and 2 pull in opposite
directions on the body — option 1 removes it entirely, option 2 keeps it on the first delivery —
and option 2's own text resolves it: the first delivery carries the diagnostic, every redelivery
after it carries one identity line. So
[Util_DeadLetterQueue.res](../../reventless/aws/src/util/Util_DeadLetterQueue.res) now loops the
records, and per record emits either `DEAD LETTER ITEM: <identity> <full record>` (when
`ApproximateReceiveCount <= 1`) or `DEAD LETTER REDELIVERY: <identity>`, where identity is
`messageId`, `DeadLetterQueueSourceArn` (falling back to `eventSourceARN`), `receiveCount` and the
body's *length*. It still throws, so both alarm subjects are unchanged. Measured on the generated
handler with two synthetic records: a redelivery line is ~110 bytes against ~2,500 before.

The consequence worth stating: the payload still reaches CloudWatch once per message. That is the
diagnostic the queue exists to preserve, but it is not nothing for anything personal in a body —
step 5's retention half is what bounds how long it stays.

**Step 3** replaces both lines with `deciding: id=… seq=… cmd=…`
([Aggregate_Callback.res](../../reventless/core/src/components/Aggregate/Aggregate_Callback.res),
[StateChangeSlice_Callback.res](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res)).
The aggregate's fold needed the sequence number carried in — `processCommand` takes `~seq` and is
applied at the reduce — because the replayed seq is what makes the line say *which* state was
decided against. The slice's equivalent of a sequence is the DCB head position, so it logs
`id=… head=… cmd=…`. No opt-in flag was added for the full state: nothing asked for one, and a flag
no one has needed is a second way to turn the defect back on.

**Step 4 — the audit.** `JSON.stringifyAny` in a log position across `reventless/*/src` has seven
hits; after step 3 the two unbounded ones are gone. Of the rest:

- `QueryEngine_DynamoDb.res` (`queryByTableName` / `scanByTableName` params) — per-query, and the
  params carry caller-supplied filter values. Now piped through `LogFormat.truncate`.
- `Validation.res` `defaultErrorHandler` — serialised a whole `exn`. Now
  `Util_Sury.exnMessage`, whose default fallback is the same `"unknown"` the site already used.
- `Projection.res:134` — already truncated; the precedent the other two now follow.
- `Message.log` — a generic `('a, string) => 'a` tap. Its three callers are FTP error paths, so
  nothing unbounded reaches it today; left alone. Note it cannot use `LogFormat` (which depends on
  `Message`), so bounding it would mean moving `truncate` down into `reventless-spec`.
- `EffectLogger._messageToString` — the sink's own rendering of whatever it is handed. Deliberately
  untouched: truncating there would silently cut lines a caller had already chosen to emit in full.

The `~data=` sites (`Message.res:123`, `Util_QueryDb.res:10`, `Adapter.res:108`,
`StateChangeSlice_Builder.res:25`) are out of scope — they are deploy-time or error-path, logged
once rather than per invocation, so neither of this plan's two shapes applies.

### Step 5, and what the estate actually showed

**Option 3's first half is not available.** `maximumRetryAttempts` is a stream-only event-source
mapping parameter — this repo's two uses of it
([StateTopic_AppSync.res:402](../../reventless/aws/src/adapter/StateTopic/StateTopic_AppSync.res#L402),
[Upload_Claim_S3.res:330](../../reventless/aws/src/adapter/Upload/Upload_Claim_S3.res#L330)) are both
DynamoDB stream mappings. For an SQS source the redelivery count is governed by the *queue's*
`RedrivePolicy.maxReceiveCount`, and this queue deliberately has no redrive target. So step 5 is
`visibilityTimeoutSeconds`, raised 180 s → **900 s** on both dead-letter queues: ~480 redeliveries per
message per day become ~96, and nothing waits on a dead letter. It stays far above the handler's 30 s
timeout.

**The incident behind the numbers, read off the estate on 2026-09-05.** The dead letters were platform
`Heartbeat` commands. The `Plugin` aggregate could not replay its own event log after a wire-format
change — `SuryError: Failed at ["_0"]["structure"]` — so replay raised before `decide` and *every*
command to that aggregate failed, heartbeats included. Five failures moved each one to the
dead-letter queue.

Three things follow, and the third is why step 5 is not symptom-treatment:

1. **The cause was already fixed** the previous evening, by the platform wipe in
   [done/optional-fields-without-annotations.md](done/optional-fields-without-annotations.md). No
   decode failure in the aggregate's log since; the plugins heartbeat normally.
2. **Seven messages stranded during the broken window were still cycling twelve hours later** — 0
   visible, 7 in flight, receive counts 234–236, one redelivery each per 3 minutes — and would have
   continued to the retention wall around Sept 18: ~44,000 further invocations and ~110 MB of further
   logs, in groups whose retention is `None`. They were purged by hand on 2026-09-05; the diagnostics
   survive in CloudWatch, which is where they were read from.
3. So **the loop outlived its cause by two weeks minus the manual intervention.** That is a property
   of the handler's design — fail forever on a transport that retries forever — not of this incident.
   Bounding it is the fix; the wipe was the fix for something else.

**A terminator was built and then removed, which is the more useful result.** The obvious complement
to the timeout is a `RedrivePolicy` on the dead-letter queues themselves — `maxReceiveCount: 20` onto
a parking queue nothing consumes — and it was implemented before the arithmetic was done. Per
stranded message over a full retention period:

| | deliveries | logs written |
|---|---|---|
| before | 6,720 | ~16.6 MB |
| + the identity-line guard (step 1–2) | 6,720 | ~740 KB |
| + the 900 s timeout (step 5) | 1,344 | ~150 KB |
| + a parking queue | 20 | ~4.6 KB |

The parking queue's marginal saving is **~145 KB and ~1,300 invocations per message — around
$0.0004.** The 3.12 GB that opened this plan came from writing the whole record 630,000 times, and
that is what steps 1–2 fixed; two extra queues per platform, permanently, is a poor trade for the
remainder.

It is also worse for the signal, which was the real argument. With the handler failing, `Errors`
stays non-zero for as long as the incident is unresolved, so an alarm on it stays *in* alarm. Parking
makes it fall quiet after ~5 hours while the problem persists.

And the tempting alternative — drop the consumer, alarm on queue depth — does not work on this
topology. A consumer that keeps failing keeps its messages **in flight**, so the queue reads
`0 visible, 7 not visible`: `ApproximateNumberOfMessagesVisible` was zero throughout the incident. An
`Invocations` alarm on the handler is the metric that matches the shape, which is what a backend
consuming the seam already maps `DeadLetterSink` to.

So the loop is bounded in cost rather than in count, and ending it early is an operator's job — for
which they must first be told. That they currently are not is
[no-monitoring-backend-on-deployed-stacks.md](no-monitoring-backend-on-deployed-stacks.md).

Nothing alarmed at any point in those twelve hours, which is a separate and larger finding:
[no-monitoring-backend-on-deployed-stacks.md](no-monitoring-backend-on-deployed-stacks.md).

## Verification

The acceptance test is a **ratio**, not a volume — raw volume also moves with traffic:

```
IncomingBytes (AWS/Logs, per group) ÷ Invocations (AWS/Lambda, same window)
```

| Handler | Now | Target |
|---------|-----|--------|
| Aggregate command handler | ~384,000 B | **< 5,000 B** |
| Dead-letter handler | ~2,470 B | **< 400 B** steady-state |

Re-measure over a window containing at least one full day of heartbeat traffic. For the
aggregate handler, the stronger check is that the ratio is **stable across two releases** —
the defect is that it climbs, so a single low reading proves nothing.

## Why this matters beyond cost

A log line whose size tracks accumulated history is a latent operational hazard in any
deployment, not only an expensive one: it degrades gradually, is invisible in testing (where
the state is small), and surfaces first as a bill or a throttle rather than as a fault. The
same is true of a handler that fails by design on a transport that retries by design — each
half is reasonable and the composition is a loop. Both are framework-shaped problems, which is
why they belong here rather than in any one deployment.
