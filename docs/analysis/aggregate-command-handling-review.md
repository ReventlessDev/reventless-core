# Aggregate Command Handling — Correctness, Consistency, Performance, Cost

**Scope.** End-to-end review of the Aggregate command path: from SQS dispatch into the Lambda handler, through `Aggregate_Callback.handleCommands`, replay, decide, append, and outbox propagation. AWS adapters (DynamoDB + SQS FIFO + DynamoDB Streams) are the reference deployment; in-memory adapter behavior is noted where it diverges.

**Files reviewed**
- [`Aggregate_Callback.res`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res)
- [`Aggregate_Builder.res`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Builder.res)
- [`EventLog_Operations.res`](../../reventless/reventless-core/src/components/EventLog/EventLog_Operations.res)
- [`EventLogStorage_DynamoDb_Runtime.res`](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res)
- [`CommandTopicChannel_SQS_FIFO.res`](../../reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_FIFO.res)
- [`CommandTopicChannel_SQS_Runtime.res`](../../reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res)
- [`Util_SQS_Runtime.res`](../../reventless/reventless-aws/src/util/Util_SQS_Runtime.res)
- [`EventTopicPublisher_DynamoDbStream.res`](../../reventless/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_DynamoDbStream.res)

---

## How it works today

### 1. Dispatch (SQS FIFO → Lambda)

- The CommandTopic queue is FIFO with `MessageGroupId = safeGroupId(commandJson.id)` ([Util_SQS_Runtime.res:23-28](../../reventless/reventless-aws/src/util/Util_SQS_Runtime.res#L23-L28)). Aggregate ID is the group key — IDs longer than 128 chars are SHA-256 hashed (avoiding false grouping from prefix-truncation).
- `deduplicationScope=MessageGroup` + `fifoThroughputLimit=PerMessageGroupId` ([CommandTopicChannel_SQS_FIFO.res:28-29](../../reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_FIFO.res#L28-L29)) → distinct aggregates can be dispatched to different Lambdas concurrently; the same aggregate's messages are serialized.
- Visibility: 180 s (`6 * 30`); DLQ after `maxReceiveCount=5`.
- A Lambda invocation receives an SQS batch (1–N records, mixed groups).

### 2. Handler — [`Aggregate_Callback.handleCommands`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L167-L223)

For each batch:
1. **Group by aggregate ID** ([L33-46](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L33-L46)) — folds the stream into a `Dict<id, topicItem[]>`.
2. **For each aggregate ID, concurrently** ([L173, `concurrency: "unbounded"`](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L221)):
   1. **Replay** the event log to current `(state, sequenceNr)` via streaming fold ([L91-95](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L91-L95)).
   2. **Process commands sequentially** through `Behavior.decide`, threading the evolving in-memory state ([L57-73, L97-100](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L57-L73)).
   3. **Append** the collected events with optimistic concurrency at `sequenceNr` ([L129](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L129)).
   4. On `"conflict"`: retry the full replay → process → append cycle, up to `maxConflictRetries = 3` ([L75, L201-217](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L75)).

### 3. Storage — [`EventLogStorage_DynamoDb_Runtime.appendWithCondition`](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L42-L54)

Single DDB table keyed by `(id PK, seq SK)` where `seq` is a zero-padded 9-digit string ([EventLog_Operations.res:43-46](../../reventless/reventless-core/src/components/EventLog/EventLog_Operations.res#L43-L46)). The OCC primitive is `attribute_not_exists(seq)` per put.

| Event count | Strategy | Atomic? | WCU |
|---|---|---|---|
| 1 | Single conditional `PutItem` | ✓ | 1× |
| 2–5 | Sequential conditional `PutItem` ([L13-25](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L13-L25)) | ✗ | 1× per event |
| 6–100 | `TransactWriteItems` with `attribute_not_exists(seq)` per put ([L27-40](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L27-L40)) | ✓ | 2× per event |
| > 100 | Not handled — `TransactWriteItems` silently truncated by AWS unless callers cap | ⚠ | — |

Replay uses `consistentRead: true` ([L77](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L77)) — strongly consistent, so any committed write from another Lambda is visible.

### 4. Outbox — DynamoDB Streams

Every AWS Aggregate builder pairs `EventLogStorage.DynamoDbStream` with `EventTopicPublisher.DynamoDbStream` (verified across `Aggregate_Builder_Single|Single_Async|Micro|PerAggregate|NoResolver`). The publisher's `publishJson` is a **no-op** ([EventTopicPublisher_DynamoDbStream.res:22](../../reventless/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_DynamoDbStream.res#L22)) — propagation rides DynamoDB Streams. This is a transactional outbox: events become visible to subscribers iff the storage write committed.

### 5. Result reporting — `runInlineAndCollect` and SQS deletes

- For SQS-FIFO (async path): handler returns `Ok(reference) | Error(reference)` per command. SQS messages corresponding to `Ok` are deleted; `Error` messages return to the queue for redelivery ([CommandTopicChannel_SQS_Runtime.res:28-46](../../reventless/reventless-aws/src/adapter/CommandTopic/CommandTopicChannel_SQS_Runtime.res#L28-L46)).
- For sync paths (in-memory, `SQS_Sync`): `runInlineAndCollect` ([CommandTopic_Helpers.res:44-72](../../reventless/reventless-core/src/components/CommandTopic/CommandTopic_Helpers.res#L44-L72)) collects `commandOutcome` values via the `acceptedResultChannel` side-channel; the producer awaits per-command `Accepted | Rejected | Pending`.

---

## Correctness

### What works

- ✓ **OCC for single-event appends.** `attribute_not_exists(seq)` strictly serializes writers at sequence `N`. With strongly-consistent replay, the conflict loser observes the winner on retry.
- ✓ **Atomic outbox.** DDB-Streams-backed publishing means events are propagated iff the row committed. No "wrote-but-didn't-publish" window.
- ✓ **Per-aggregate ordering preserved.** SQS FIFO + MessageGroupId = ID + sequential `processCommand` per aggregate inside the handler (the `Array.reduce` thread is sequential ≠ the per-aggregate-group `Effect.all` which is concurrent across IDs).
- ✓ **Idempotent no-op commands.** Command convention (and the code path on [L110-116](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L110-L116)) returns `Ok` with `eventCount: 0` when `decide` produces no events. Safe under SQS's at-least-once delivery for any deterministic decide function.
- ✓ **Conflict retries are bounded.** 3 retries → terminal `Error(reference)` → message returns to SQS up to `maxReceiveCount=5` → DLQ. The retry budget is layered, not unbounded.
- ✓ **Transient-error backoff at the storage layer.** `EventLog_Operations.append` retries up to 5× on `ThrottlingException`, `ProvisionedThroughputExceededException`, `ServiceUnavailable`, `RequestLimitExceeded`, `InternalServerError` ([EventLog_Operations.res:19-30](../../reventless/reventless-core/src/components/EventLog/EventLog_Operations.res#L19-L30)) with exponential jittered backoff before surfacing the error.

### Caveats and footguns

- ⚠ **Multi-event sequential put (count 2–5) is not atomic.** `putItemsSequentialConditional` does N independent conditional puts ([L13-25](../../reventless/reventless-aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res#L13-L25)). If put #1 succeeds and put #2 fails with a **non-transient** error (e.g., `ValidationException`, `AccessDeniedException`, item-size limit), event #1 is durably committed but the handler reports `Error` to the producer. Recovery path:
  - **Transient mid-batch error**: storage-level retry re-runs the whole `appendWithCondition`. The first put now hits `attribute_not_exists` violation → `StaleState` → `"conflict"` → Aggregate's conflict-retry replays and observes the partial event → produces correct deltas → ends consistent. ✓ (recovery works.)
  - **Non-transient mid-batch error**: no retry; the fail-fast Effect propagates and the Aggregate handler returns `Error` to SQS for the whole batch. The first event is now committed but the producer thinks the command was rejected, and SQS will redeliver. The redelivery's replay sees event #1 already applied; `decide` runs against the post-event-1 state. If `decide` is deterministic, it still produces an event #2 and writes it; the user-visible outcome is that "command produced 2 events" took two SQS attempts to settle. Not strictly a correctness bug for deterministic domains but the producer outcome (`Rejected` then `Accepted`) is misleading for the same `msgId`.
  - **Mitigation**: route count 2–5 through `TransactWriteItems` too. The threshold exists to save 50% WCU on small multi-event commands; whether that saving justifies the partial-write ambiguity is a domain call.
- ⚠ **`appendWithCondition` does not enforce the `count ≤ 100` cap up front.** `TransactWriteItems` rejects > 100 items with `ValidationException`. The error surfaces, but later than it could; the call should pre-check and fail with `"max 100 events per command"` (matches the explicit cap surfaced in `DcbEventLogStorage`). One-line fix.
- ⚠ **Decide errors silently log and continue.** `processCommand`'s `Error(error)` branch ([L65-69](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L65-L69)) calls `logError` and returns `Ok((state, events))` unchanged. Net effect: a domain rejection (e.g., `OrderAlreadyShipped`) does not propagate to the producer as `Rejected` — SQS deletes the message and the producer believes it succeeded with no event count change. The `acceptedResultChannel` side-channel is keyed only on `entityId/eventCount`, not error codes; sync producers see `Accepted({eventCount: 0})` for both genuine no-ops and silently-rejected commands. **This is the most important correctness gap on the path** for users relying on synchronous error feedback. The commit `c0942696b` closed the equivalent gap on DCB; the Aggregate path needs the analogous fix (propagate the decode-error path used for invalid commands, into a `Rejected` outcome on domain errors).
- ⚠ **Dead code in the reduce accumulator.** `processCommand` always returns `Ok(...)` (even on decide errors, per the previous bullet), so the `Error(_) as error` branch ([L72](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L72)) and the `Error(error) => JsError.throwWithMessage(error)` branch in `replayProcessAppend` ([L107](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L107)) are unreachable. The `throwWithMessage` would crash the entire group's Effect if it ever fired. Remove or wire to the genuine-rejection path.
- ⚠ **Meta `msgId` is rewritten on every retry.** `updateMeta` ([L48-52](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L48-L52)) regenerates `msgId` per attempt. The producer's correlation token is preserved as the SQS receipt handle / `topicItem.reference`, so this only affects the `meta.msgId` written into the durable event row. Two consequences: (a) you can't trace a published event back to the originating command via `msgId` (you'd need to plumb the original `meta.msgId` separately, e.g., as a `causationId`); (b) on retry-after-partial-write the surviving event from the first attempt has a different `msgId` from any subsequent events from the second attempt, even though they belong to the same logical command.
- ⚠ **Heartbeat has no effect on commands.** Lambda timeout > SQS visibility timeout (180 s) is the only safety net against in-flight handler death. If `decide` hangs (e.g., deadlock in an upstream resolver call) the message returns to the queue after 180 s; meanwhile the in-flight Lambda still holds the handle. SQS FIFO will block the rest of the group until visibility expires or the message is deleted. No application-level command timeout.

---

## Consistency

### Across concurrent Lambdas

- ✓ **Per-aggregate FIFO is preserved across instances.** SQS FIFO won't deliver group-N messages to a second consumer while group-N's prior messages are in-flight on the first consumer. Combined with `attribute_not_exists(seq)` strong serialization, two writers can never both commit the same `seq`.
- ✓ **Strong-consistent replay closes the read-write gap.** A Lambda that just appended sequence `N` is observable by the next Lambda's replay (via `consistentRead: true`).
- ⚠ **Visibility-timeout reordering.** If a Lambda exceeds 180 s (e.g., huge replay, throttled DDB), SQS redelivers *while the first Lambda still completes its append.* The second Lambda's replay observes the first's committed events; its `decide` runs on the post-first-attempt state and conflicts on the OCC if the first's append happened to land at the same `seq`. The conflict retry then replays the new state and proceeds. End state is consistent; the first Lambda's `Ok` reply may try to delete a receipt handle that has already expired (logged but not catastrophic).
- ⚠ **Across-aggregate ordering is not preserved.** The `Effect.all` over groups uses unbounded concurrency; events from aggregate `A` and aggregate `B` interleave arbitrarily on the EventTopic / DDB Stream. This is by design (aggregates are independent consistency boundaries), but downstream projections must not assume cross-aggregate ordering.

### Within a batch

- ✓ **Commands for the same aggregate fold sequentially.** `Array.reduce` over `commands'` ([L97-100](../../reventless/reventless-core/src/components/Aggregate/Aggregate_Callback.res#L97-L100)) threads state through each command. A 5-command batch for one aggregate produces one append (or a partial append, see Caveats above) — the producer sees one transactional commit point for the whole batch.
- ⚠ **A mid-batch decide error pollutes downstream commands.** Because the error branch keeps the prior state and accumulates no events, subsequent commands in the same batch see "as if the bad command never happened" state. Whether that is desirable depends on the domain; for "delete then update" patterns it can mask bugs.

---

## Performance

| Path | Cost | Notes |
|---|---|---|
| Replay on every batch | O(N) DDB reads × 2× RCU (strong) | No snapshot, no in-memory cache between invocations. Acceptable for short-lived aggregates; problematic for log-heavy ones (e.g., long-running orders, persistent counters). |
| Per-command decide | O(events_in_batch) | Pure ReScript, in-memory; negligible. |
| Append (1 event) | 1× WCU + 1× stream record | Optimal. |
| Append (2–5 events) | N× WCU + N× stream records | Sequential — N round-trips of latency. Saves 50% WCU vs the transact path. |
| Append (6–100 events) | 2× N WCU + N× stream records | One round-trip but doubled WCU per item (TransactWriteItems pricing). |
| Conflict retry | 1 extra replay + 1 extra append per attempt | Capped at 3 retries; in steady-state contention this dominates. |
| Cross-aggregate concurrency | Unbounded `Effect.all` | Limited only by DDB partition throughput and Lambda memory. Hot partitions can throttle; transient retries help but exhaustion still possible under sustained burst. |

**Hot spots**

- **Long-tail aggregates** (1k+ events) → every command triggers a full streaming replay. The `replayStream` is lazy on DDB pages but the fold consumes everything before `decide` can run. Snapshotting is the standard remediation; not implemented.
- **Burst writes to one aggregate** → SQS FIFO serializes them; throughput ceiling per aggregate is `1 / (replay + decide + append)` ≈ 10–30 commands/s on a small aggregate, much less on a large one. This is fundamental to the consistency model, not a defect — but worth documenting for capacity planners.
- **Lambda cold starts compound replay cost.** The first invocation pays cold-start + full replay; warm invocations only pay replay (state is rebuilt every time, not cached). A simple in-memory cache keyed by `(id, seq)` would cut steady-state RCU dramatically; not implemented (correctness implication: cache invalidation on conflict retry must reset to the just-replayed state).

---

## Cost (AWS reference deployment, per-command)

Approximate cost for a 1-event command on a 100-event aggregate (us-east-1, on-demand pricing):

- **DDB replay**: 100 strong-consistent reads × 1 KB ≈ 100 RRU → ~$0.0000125
- **DDB append**: 1 WRU × 1 KB → ~$0.00000125 + 1 stream record → ~$0.00000002
- **SQS FIFO**: 1 message in + 1 delete ≈ 2 requests → ~$0.0000010
- **Lambda**: ~50–200 ms × 256 MB → ~$0.0000005 – 0.000002
- **Stream → subscribers**: 1 record per consumer (read costs charged to subscribers).

Per-command total ≈ **$0.000015 – 0.00002** dominated by replay reads. Doubling aggregate length doubles per-command cost.

**Cost reduction levers**

| Lever | Saving | Trade-off |
|---|---|---|
| Snapshotting | replay → ~constant RCU | Implementation complexity; snapshot freshness must not break OCC (use snapshot + delta replay since snapshot's `seq`). |
| Eventually-consistent replay where safe | 50% RCU on replay | Loses OCC strict guarantee; on conflict, retry corrects but with one extra round-trip. Net loss likely. **Don't.** |
| Use `BatchWriteItem` (non-conditional) and a separate "head pointer" | 1× WCU even for multi-event | Loses per-event OCC; needs a single conditional update on the head pointer to gate the batch. Significant rework. |
| Cap multi-event commands at 1 event | Keeps single-put path always | Pushes "atomic multi-event" responsibility to the domain; almost never desirable. |
| Compress events | RCU × compression ratio | More CPU per replay; inspectability suffers. |

The biggest realistic win is **snapshotting**: turns replay cost from O(N) to O(events_since_snapshot), which can be bounded by snapshot frequency.

---

## Recommended actions

### Backlog plans, by recommended execution order

| # | Plan | Class | Effort | Runtime $ impact | Why this position |
|---|------|-------|--------|------------------|-------------------|
| 1 | [`aggregate-propagate-decide-errors`](../plans/Backlog/aggregate-propagate-decide-errors.md) | **Correctness — P0** | Medium (~3–5 d incl. tests) | Zero | Most user-visible gap. Today domain rejections are indistinguishable from idempotent no-ops at the producer. Mirrors the DCB fix in `c0942696b`. |
| 2 | [`aggregate-event-count-cap-validation`](../plans/Backlog/aggregate-event-count-cap-validation.md) | **Correctness sharp edge — P1** | Tiny (~½ d) | Zero | One-line guard. Matches the DCB path's pre-flight rejection of > 100-item transactions. Cheapest possible win. |
| 3 | [`aggregate-multi-event-atomic-append`](../plans/Backlog/aggregate-multi-event-atomic-append.md) | **Correctness — P1** | Small (~2–3 d) | +100% WCU on 2–5-event commands (single-event commands unchanged) | Closes the partial-write window for non-transient mid-batch errors. Cost increase is real but bounded; ship after #2 so the cap is enforced uniformly. |
| 4 | [`aggregate-remove-dead-error-branches`](../plans/Backlog/aggregate-remove-dead-error-branches.md) | **Cleanup — P2** | Tiny (~½ d) | Zero | Dead branches obscure control flow; one of them is a `JsError.throwWithMessage` landmine. Fold into #1's PR if shipping concurrently. |
| 5 | [`aggregate-msgid-causation-correlation`](../plans/Backlog/aggregate-msgid-causation-correlation.md) | **Observability — P2** | Small (~2–3 d) | Zero | Closes the command→event correlation gap. Schema-additive (`@s.optional causationId`); backwards compatible. |
| 6 | [`aggregate-replay-cost-documentation`](../plans/Backlog/aggregate-replay-cost-documentation.md) | **Documentation — P2** | Small (~1–2 d incl. benchmark) | Zero | Operators sizing long-aggregate workloads need the cost / throughput-ceiling profile written down. Prerequisite for justifying or deferring #7. |
| 7 | [`aggregate-snapshotting`](../plans/Backlog/aggregate-snapshotting.md) | **Performance — P3, profile-gated** | Large (~2–3 w) | **Negative** — replay cost from O(events) to O(events_since_snapshot). Pays back only on long-lived aggregates. | Significant rework. **Do not start until production data shows the linear replay cost is a real bill.** Until then, #6 is the right level of investment. |

### Sequencing rationale

- **#1 first** because it's the only one of these items that affects what producers see today. Everything else is either a correctness gap that's hard to trigger (#2, #3) or a cleanup / optimization. Without #1, every other fix lands on top of a system that lies to its callers about whether commands succeeded.
- **#2 before #3** because once multi-event appends always use `TransactWriteItems`, the 100-item cap should be a clear pre-flight error, not a generic AWS `ValidationException`. #2 is half a day; do it as a precursor.
- **#3 enabled by #2.** Routing all multi-event commands through `TransactWriteItems` doubles WCU on the 2–5 band — acceptable, but only if the > 100 case fails fast with a clear error.
- **#4 is a freebie.** Land it whenever someone touches `Aggregate_Callback.res` — naturally, that's during #1.
- **#5 is independent of #1–#4.** Schema-additive, no runtime semantics change. Can be developed in parallel with the correctness work.
- **#6 must precede #7.** Without measured cost data, snapshotting is speculative work. The doc's purpose is partly to gather the operational signal that would justify (or defer) #7.
- **#7 is profile-gated.** The plan's Step 1 demands production cost / latency data first. If p95 aggregate length is small or DDB RCU is a minor line item, defer indefinitely.

### What can run in parallel

- #1 + #4 ship in one PR (touch the same file; the dead branches collapse cleanly when the rejection path is wired).
- #2 + #3 are sequential within the same adapter file; same PR is fine.
- #5 is fully independent — develop concurrently with anything else.
- #6 can land any time; it depends on no code change.
- #7 depends on #6 (data justification) and is otherwise independent.

### Cost-driven order: rank by net 6-month value

If you optimise for *value over a 6-month horizon* (correctness first, then runtime savings net of dev cost):

1. **#1** — non-negotiable correctness gap. Producers cannot reason about command outcomes today.
2. **#4** — freebie; collapse into #1's PR.
3. **#2** — half-day pre-flight check; eliminates a confusing AWS error class.
4. **#3** — closes the partial-write window. Cost increase is real but bounded.
5. **#5** — operability; pays back over the lifetime of the system as projections, dashboards, and audit logs benefit from causation traces.
6. **#6** — operator enablement; prerequisite for justifying #7.
7. **#7** — only if production data shows the replay cost is dominant. Otherwise indefinite defer.

---

---

## Summary

| Dimension | Verdict |
|---|---|
| **Correctness (single-event commands)** | ✓ Sound. OCC + strong-consistent replay + DDB-Streams outbox is the textbook recipe. |
| **Correctness (multi-event commands, count 2–5)** | ⚠ Partial-write window on non-transient mid-batch errors; recovers on transient errors via OCC retry. |
| **Correctness (decide errors)** | ✗ Silently swallowed. Producer sees `Accepted({eventCount: 0})`. Most impactful fix. |
| **Consistency** | ✓ Per-aggregate FIFO and strong-read replay close all the obvious windows; cross-aggregate ordering is intentionally not preserved. |
| **Performance** | △ Acceptable for short aggregates; degrades linearly with event-log length. No snapshotting. |
| **Cost** | △ Replay-dominated. Snapshots would cut steady-state cost ~10× on long aggregates. |

The architecture is sound; the implementation has one user-visible correctness gap (silent decide errors) and one infrequent partial-write window. Performance and cost are dominated by the no-snapshot replay model, which is a deliberate simplicity choice rather than a defect.
