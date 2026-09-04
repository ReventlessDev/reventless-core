# Plan: a framework log line's size must not grow with the data it describes

**Date:** 2026-09-04
**Status:** Proposed — not started. Found by attributing a deployed alpha estate's
CloudWatch bill to log groups and dividing by invocation count.
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
No new work here; it is evidence for that plan, not a change to this one.

## Steps

| # | Change | Effort |
|---|--------|--------|
| 1 | Fix B option 2 — guard the full-record dump on `ApproximateReceiveCount === 1` | ~2 lines |
| 2 | Fix B option 1 — log identity fields instead of the record | small |
| 3 | Fix A — replace both `deciding on state` lines with id/seq/command | small |
| 4 | Audit `JSON.stringifyAny` in log positions across `reventless/*/src` | ~1h |
| 5 | Fix B option 3 — bound redelivery via ESM retries or visibility timeout | infra, needs a deploy |

Steps 1–3 are independent and each ships on its own.

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
