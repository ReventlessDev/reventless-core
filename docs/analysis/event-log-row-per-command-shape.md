# EventLog Storage Shape — One Row per Command (vs. One Row per Event)

**Scope.** Architectural alternative to the current Aggregate `EventLogStorage_DynamoDb` shape. The current shape stores **one DynamoDB row per event**, keyed by `(id PK, seq SK)` where `seq` is a zero-padded 9-digit string ([`EventLog_Operations.res:43-46`](../../reventless/core/src/components/EventLog/EventLog_Operations.res#L43-L46)). The proposed shape stores **one DynamoDB row per command** — the row carries an array of events produced by that command. Out of scope: the DCB EventLog (different fence-row schema; see "DCB applicability" below).

**Trigger.** Came up while shipping [`aggregate-multi-event-atomic-append`](../plans/done/aggregate-multi-event-atomic-append.md), which routes counts ≥ 2 through `TransactWriteItems` at +100% WCU. Question: is there a way to get atomicity for free, by collapsing the storage shape itself?

**Files in scope (current implementation)**
- [`EventLog_Operations.res`](../../reventless/core/src/components/EventLog/EventLog_Operations.res) — encode/decode, append, replay, retry
- [`EventLogStorage_DynamoDb_Runtime.res`](../../reventless/aws/src/adapter/EventLog/EventLogStorage_DynamoDb_Runtime.res) — DDB calls
- [`EventTopicPublisher_DynamoDbStream.res`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_DynamoDbStream.res) — outbox (currently a no-op; DDB Streams carries the row directly)
- [`Aggregate_Callback.res`](../../reventless/core/src/components/Aggregate/Aggregate_Callback.res) — caller of `append`

---

## The two shapes side-by-side

### Today: row-per-event

```
Table key: (id PK, seq SK)
Item:
  id       = "order-123"
  seq      = "000000042"
  event    = "OrderShipped"          # variant tag
  data     = { tracking: "abc..." }  # payload
  meta_msg_id, meta_user, meta_timestamp, ...
```

- `append` for N events → N puts. OCC: `attribute_not_exists(seq)` per put. Atomicity for N ≥ 2 requires `TransactWriteItems` (2× WCU).
- Replay: `Query` by `id`, returns one row per event in `seq` order.
- DDB Streams: one stream record per event row. EventTopicPublisher is a no-op because each stream record already maps 1:1 to a domain event.
- Per-event metadata is per-row.

### Proposed: row-per-command

```
Table key: (id PK, commandSeq SK)
Item:
  id          = "order-123"
  commandSeq  = "000000017"
  events      = [
    { event: "OrderShipped",  data: {...} },
    { event: "InvoiceSent",   data: {...} },
  ]
  meta_msg_id, meta_user, meta_timestamp, meta_request_id, ...
```

- `append` for N events → 1 put. OCC: `attribute_not_exists(commandSeq)`. Atomicity is structural — there is no multi-row write.
- Replay: `Query` by `id`, returns one row per command; client flattens `events` arrays into the event stream.
- DDB Streams: one stream record per command, carrying an `events` array. EventTopicPublisher must **fan out** — split the array into N SNS/SQS messages.
- Command-level metadata is per-row; per-event metadata (if needed) lives inside each array element.

---

## Advantages

1. **Atomic by construction.** Multi-event commands collapse to a single `PutItem`. No `TransactWriteItems`, no compensation logic. The "partial-write" failure mode literally cannot exist.

2. **WCU reduction on multi-event commands.** DDB charges 1 WCU per KB written. Today, a 5-event command of small events (~200 bytes each ≈ 1 KB total) costs **5 WCU** (transact: 2 × 1 WCU × 2 items, rounded; conservatively 10 WCU under transact). Under one-row-per-command: **1 WCU**. Savings collapse for large events (per-KB cost dominates), but for the typical small-event domain this is 5–10× cheaper on the 2–100 band.

3. **Stream-record reduction.** DDB Streams costs $0.02 per 100 k stream reads, plus downstream Lambda invocation overhead. One record per command (instead of N per command) reduces stream read volume ~N× for multi-event commands. For workloads with even a moderate fan-out per command (avg 3 events), this is a real cost line.

4. **The 100-event ceiling goes away — replaced by a softer 400 KB item-size ceiling.** No `TransactWriteItems` cap; a command can produce as many events as fit in a 400 KB row. With 1 KB events that's ~300; with 10 KB events ~30. A pre-flight check on serialized size replaces the current count check.

5. **Causation correlation comes for free.** Today `meta.msgId` is rewritten on every retry attempt (`Aggregate_Callback.updateMeta`, [L48-52](../../reventless/core/src/components/Aggregate/Aggregate_Callback.res#L48-L52)) — the [`aggregate-msgid-causation-correlation`](../plans/Backlog/aggregate-msgid-causation-correlation.md) backlog plan exists to fix this. Under one-row-per-command, `(id, commandSeq)` IS the durable command identifier; all events in the row share it. The msgId rewrite-on-retry concern goes away because the row's `commandSeq` is what every consumer correlates on.

6. **Snapshotting fits naturally.** A snapshot becomes another row at `commandSeq = N` carrying the serialized state up to that point. Replay reads in `commandSeq` order; if the latest snapshot row is found, deltas apply on top. The [`aggregate-snapshotting`](../plans/Backlog/aggregate-snapshotting.md) plan's biggest design question — "how does a snapshot interleave with per-event rows?" — dissolves: snapshots are just commands of a different type.

7. **Cleaner outbox semantic.** The current "events become visible iff the row commits" is a per-event statement. The new shape promotes this to "all events of a command become visible iff the row commits" — which is the actual guarantee callers want. No exposure to mid-batch partial visibility at any level.

8. **Retry semantics simplify.** Today, retry of a failed multi-event append must reason about which prior puts succeeded and which didn't — `appendWithCondition`'s `attribute_not_exists` violation on retry signals "partial commit, recover via conflict path." Under one-row-per-command, retry is binary: the row either committed (`attribute_not_exists(commandSeq)` violation → conflict → standard replay-decide-append loop) or didn't (clean retry). The `Effect.retry` schedule's branching surface shrinks.

9. **Time-travel and audit by command.** "Show me state at command 47" is a single read of (latest snapshot ≤ 47) + delta replay. Today, "state at event 152" is also possible but events don't naturally cluster by their causing command, so explaining a state to an operator requires more cross-referencing.

10. **Replay can short-circuit.** When a snapshot row exists at `commandSeq = N`, replay starts at `N+1` and reads only subsequent command rows. Both per-row and per-event count drop. The "long-tail aggregate replay cost" from the [aggregate command-handling review](aggregate-command-handling-review.md) becomes an O(commands since snapshot) problem rather than O(events since snapshot).

---

## Consequences (migration burden, behavior changes)

1. **Storage migration is a one-way door.** Existing production data is in the per-event shape. Switching requires either (a) dual-write + rewriter + cutover, or (b) parallel-table strategy with read-from-both during transition. Either is a multi-week, downtime-aware project per platform.

2. **`EventTopicPublisher_DynamoDbStream` is no longer a no-op.** Today the publisher is `Promise.resolve()` because each stream record is already a single event ([`EventTopicPublisher_DynamoDbStream.res:22`](../../reventless/aws/src/adapter/EventTopic/EventTopicPublisher_DynamoDbStream.res#L22)). Under one-row-per-command, the publisher becomes a stream-record processor that decodes the `events` array, derives per-event `seq` from `(commandSeq, indexInCommand)`, and publishes N SNS/SQS messages. New failure mode: partial fan-out (N-1 of N events published, then crash). Mitigation: the publisher must be idempotent on a per-event key.

3. **`seq` becomes a derived value.** Today `seq` is the SK and a single zero-padded 9-digit string. Under the new shape, `seq` (as exposed to subscribers, projections, and the `meta.seq` field on events) becomes a composite — likely formatted as `"<commandSeq>.<index>"` or kept as a single integer derived by counting prior events. Anywhere the framework treats `seq` as a sortable opaque token, the contract evolves. Audit tools, projections that store `lastSeq`, debugging utilities — all touched.

4. **DCB applicability.** The DCB EventLog uses a different schema: per-tag fence rows + per-event rows where each event can carry multiple tag pointers. An event from a single command may be relevant to multiple tags. Packing into a "command row" doesn't trivially work — the storage model is centered on tags, not on aggregate-style `(id, seq)` per-entity logs. **DCB stays on its current shape.** Long-term the framework will host two storage shapes (Aggregate row-per-command, DCB row-per-event-with-fences); the storage-adapter abstraction already accommodates this.

5. **`appendStream` doesn't fit.** `EventLog.appendStream` ([`EventLog_Operations.res:196-207`](../../reventless/core/src/components/EventLog/EventLog_Operations.res#L196-L207)) writes one event per stream item — there's no notion of "command boundary" in a stream. Used by replay-from-source, audit-replay, and import tooling. Under the new shape, either: (a) each stream item becomes a one-event command row (gives up the WCU savings, but preserves the API), or (b) the API takes a `Stream<commandBatch>` instead of `Stream<event>`, which is a breaking signature change. Probably (a) for backwards compatibility.

6. **Per-event metadata: hoist or duplicate?** `meta.msgId`, `meta.user`, `meta.identity`, `meta.timestamp`, `meta.causationId` — are these per-command or per-event? Today they're per-event because each event is a row. Under the new shape, the natural choice is **hoist to row level** for fields that are command-scoped (`msgId`, `user`, `identity`, `requestId`, `causationId`) and keep per-event only for fields that actually vary per-event (probably none, in practice). This is a schema break for any downstream consumer that reads `meta` off a `Spec.event'` record.

7. **Pre-flight validation of item size.** Today's 100-event cap is structural (`TransactWriteItems` limit). Under the new shape, the limit is "row size ≤ 400 KB." That depends on event-schema sizes, which we can estimate from sury's schema metadata but can't always know exactly. Pre-flight validation either over-estimates conservatively (rejecting borderline-OK rows) or trusts the writer (and gets a `ValidationException` from DDB on an over-size row). Trade-off.

8. **Read-model dedup keys change shape.** Consumers that dedup by `(eventId, seq)` need to learn `(commandId, indexInCommand)` instead. Semantically equivalent, mechanically a code change in every projection.

9. **OCC test surface churns.** Every framework test that exercises conflict (`attribute_not_exists(seq)` violation → `"conflict"` → retry → settle) keys off per-event seq collisions. They become per-command commandSeq collisions. The semantics are equivalent but every test assertion that mentions `seq` has to be revisited.

10. **Cross-aggregate cost interaction.** ReadModels that subscribe to multiple aggregates' EventTopics see the same per-event message stream as today (the publisher fans out at the source). So ReadModel cost is unchanged. The savings accrue **only** at the EventLog write side and the Streams read side.

---

## Opportunities (downstream effects worth highlighting)

1. **Replaces three backlog plans.** [`aggregate-multi-event-atomic-append`](../plans/done/aggregate-multi-event-atomic-append.md) ✓ already shipped via TransactWriteItems — under the new shape it would have been a no-op (atomicity is free). [`aggregate-msgid-causation-correlation`](../plans/Backlog/aggregate-msgid-causation-correlation.md) becomes structurally moot (the row IS the causation key). [`aggregate-snapshotting`](../plans/Backlog/aggregate-snapshotting.md) becomes a special-cased command row rather than a parallel table-shape change.

2. **A "command journal" view becomes a natural extra index.** Today there's no first-class concept of "commands" in the EventLog — they're inferred from same-msgId event clusters. With command-rows, a GSI on `(meta.requestId, commandSeq)` gives a cross-aggregate causation log for distributed tracing / debugging. The data was always there; the schema makes it queryable.

3. **Better SNS/SQS PublishBatch utilization.** The publisher fans out one row → N events in one Lambda invocation; it can batch via `PublishBatch` (up to 10 messages) reducing per-event API cost on the publish side.

4. **Operator UX improves.** "Replay all commands from time X to Y" is a well-defined operation under command-rows. Today it's "replay events in `[X, Y]`," which can split a multi-event command across the boundary — usually fine for projections, occasionally surprising for operators.

5. **Sets up cross-aggregate transactional commands.** A command that should atomically affect two aggregates is currently impossible (each aggregate has its own row, OCC is per-aggregate). Under command-rows, two aggregates' rows can be committed in a single `TransactWriteItems` of size 2 — atomic across aggregates, with the same OCC primitive. We'd opt back into TransactWriteItems for this case, but only when the domain genuinely needs cross-aggregate atomicity.

6. **Event-store export and replication get cheaper.** Streaming the EventLog to a downstream archive (S3, Kinesis) carries one record per command instead of one per event. Replay from archive gets faster too, because the unit of work is larger.

---

## Risk register

1. **Migration is the dominant cost.** Code changes alone are estimated 2–3 weeks (schema, publisher fan-out, `appendStream`, replay decoder, projections that store `lastSeq`, the test surface). Production data migration adds another 1–4 weeks per platform depending on log size and acceptable downtime. Total: **6–10 weeks per shipped platform.** This is bigger than every other backlog plan combined.

2. **Two storage shapes coexist forever.** DCB stays on its fence-row schema. The framework has to maintain both adapters indefinitely. Maintenance overhead is real but bounded — both shapes are stable storage primitives, not user-facing APIs.

3. **The publisher introduces a new partial-failure mode.** Mid-fan-out crash leaves N-of-M events published. Recoverable via DDB-Streams replay (the next invocation re-reads the same stream record), but only if the publisher is idempotent at the per-event grain. Idempotency primitive: the SNS/SQS message's deduplication key must be derived from `(commandSeq, indexInCommand)`, not from `meta.msgId` (which would dedupe the entire command).

4. **Item-size validation has a non-deterministic edge.** A command that produces N events near the 400 KB ceiling may succeed today and fail tomorrow if any event grows. Developers must either reason about size or accept occasional `ValidationException`s — neither is great. Probably OK in practice (most commands produce few events of modest size), but worth surfacing.

5. **Operators familiar with the per-event row model have to re-learn.** SOPs, runbooks, monitoring queries (e.g., "how many events for `id = X`") that hit DDB directly all change. Mitigation: keep a "logical events" projection (a GSI or a derived view) that exposes the per-event shape for operator tooling. Cost: more storage.

6. **Ecosystem assumptions.** Any external tool that reads the EventLog table directly (an analytics export, a backup tool, a custom debugger) breaks. The blast radius is small inside the framework but unbounded outside.

---

## Prior art — how other event stores handle this

A survey of established event-store implementations. Most use **per-event records**; the row-per-command/batch pattern has two well-known precedents (NEventStore, Equinox.CosmosStore/DynamoStore).

### Per-event storage (the majority)

| System | Storage | Atomicity primitive |
|---|---|---|
| **EventStoreDB / KurrentDB** | One record per event in the stream's transaction file; events are individually addressable by `eventNumber`. | `AppendToStream(expectedVersion, events[])` — server writes the batch atomically (single fsync), then indexes them as N logical events. |
| **Marten** (Postgres) | One row per event in `mt_events` (`seq_id`, `stream_id`, `version`, `data` jsonb, `type`, ...). | Postgres transaction wraps N INSERTs; stream-version OCC via `mt_streams.version`. |
| **MessageDB / Eventide** (Postgres) | One row per event in a single global `messages` table (`stream_name`, `position`, `global_position`, `data`). | `write_message()` Postgres function with optional `expected_version`; multi-event writes = several function calls in one transaction. |
| **Akka Persistence** (JDBC, Cassandra) | One row per event in the journal table, keyed by `(persistence_id, sequence_nr)`. | `persistAll` runs as a single SQL transaction (JDBC) or logged batch (Cassandra). |
| **AxonServer** | One length-prefixed record per event in segmented append-only files; indexed by aggregate ID and global sequence. | `appendEvents` gRPC call is the atomic unit — single segment-write transaction with aggregate-sequence uniqueness. |
| **AWS Prescriptive Guidance** ("CQRS on DynamoDB") | One item per event, PK = `aggregateId`, SK = `version`. | `TransactWriteItems` (≤100 items) with conditional check on next expected version. **Same shape Reventless uses today.** |
| **Marten "QuickAppend"** (v4+) | Same per-event shape; QuickAppend is a write-path optimization (single batched SQL command, reduced concurrency checks). Physical schema unchanged. | Same as Marten. |

**Pattern summary.** Per-event storage is the default because (a) the unit of subscription is the event, (b) per-event addressability supports back-fills and reprocessing well, (c) RDBMS transactions or DDB `TransactWriteItems` make multi-event atomicity affordable.

### Per-commit / per-batch storage (the minority)

| System | Storage | Notes |
|---|---|---|
| **NEventStore** (.NET, ~2011→) | One row per **commit** in the `Commits` table (`StreamId`, `CommitSequence`, `Payload` blob serializing N events, `Items` count). | The original "row per command" event store. Single INSERT per commit; OCC via uniqueness on `(StreamId, CommitSequence)`. The shape predates the ES/CQRS canon settling on "row per event" and persists in legacy systems. |
| **Equinox.CosmosStore / Equinox.DynamoStore** (F#) | Hybrid **"tip + calved batches."** Each stream has one **Tip document** holding the most recent N events inline (plus snapshot/unfolds). When the tip exceeds a threshold, older events are "calved" into immutable **Batch documents**, each holding multiple events. | Many events per document. Atomicity: ETag-based OCC on the tip document with stored procedure / transactional batch (Cosmos), or conditional write on the tip's version attribute with `TransactWriteItems` for calving (Dynamo). **The closest direct precedent for the shape proposed here.** |

**Why the minority?** Both systems share a key insight: when the unit of write (a command, a transaction) is also the unit of read interest most of the time, packing events into a write-batch document collapses several problems (atomicity, snapshot-fit, write-cost) at the cost of a publisher fan-out and a more complex read path. NEventStore got there first by accident-of-history; Equinox got there deliberately, optimizing for CosmosDB's per-document RU pricing.

### Reventless's situation maps onto Equinox.DynamoStore

The DDB cost model (1 RU/WCU per KB, with `TransactWriteItems` charging 2× per item) is exactly the pricing pressure that drove Equinox to the tip-batch pattern. Equinox.DynamoStore explicitly cites "TransactWriteItems pricing" as a motivator. The Reventless proposal in this doc is essentially a **simpler variant of Equinox's pattern** — one row per command, no tip-vs-calved distinction, no inline snapshots in the tip — just the basic batched-row idea.

That doesn't mean we should adopt the full Equinox model. It does mean:
- The "row per command" shape is a **proven production pattern** on DDB, not a speculative refactor.
- The Equinox tip pattern points to a natural extension if/when snapshots are added: store recent events plus a snapshot in one tip document, calve older batches into immutable rows.
- The publisher fan-out problem (Risk #3) has prior solutions in both NEventStore (commit-dispatcher pattern) and Equinox (subscription pump that flattens batches into per-event handlers).

### What's notably absent

- **No major event store packs events from *different* commands into one record.** All "batched" stores still respect command/write boundaries — packing is per-write, not per-time-window. This rules out a tempting variant ("batch every 100ms of writes into one row") that would break command-level atomicity guarantees for callers.
- **No major store mixes shapes within one log.** Either everything is per-event or everything is per-batch; the framework doesn't try to use per-event for hot streams and per-batch for cold ones. (Equinox's tip-vs-calved is the closest to mixing, but both shapes still pack multiple events.)

### Implications for our decision

1. **The proposal is not novel.** It puts Reventless in the company of NEventStore and Equinox — both production-validated. The risks called out in this doc (publisher fan-out, item-size ceiling, schema migration) are risks others have navigated.
2. **The mainstream is per-event.** EventStoreDB, Marten, MessageDB, Akka Persistence, AxonServer, and AWS's own DDB guidance all pick per-event. The reasons mostly reduce to: per-event addressability is simpler to reason about; transactional atomicity is cheap when the underlying store offers it (Postgres txns, ESDB single fsync); per-event is what subscribers ultimately want anyway.
3. **The trigger conditions matter more given this context.** If WCU on multi-event commands becomes a real cost line — the same pressure that motivated Equinox.DynamoStore — the precedent is clear and the pattern is known. If that cost stays small, sticking with per-event keeps Reventless aligned with the larger ecosystem (most people coming from EventStoreDB / Marten / MessageDB will recognize the schema).

---

## When this becomes the right move

This is **not a now-decision.** The current shape works, atomic multi-event append just shipped, and the cost gap on the 2–100 band is well-bounded.

The trigger conditions to revisit are **either** of:

- **Production data shows WCU on the 2–100 band is a meaningful cost line.** If most commands fan out > 1 event and DDB write costs are a top-3 cost line in the bill, the row-per-command shape pays back the migration in months, not years.
- **The snapshotting plan ([`aggregate-snapshotting`](../plans/Backlog/aggregate-snapshotting.md)) is about to start.** Doing snapshotting on the per-event shape is real work; the row-per-command shape gives snapshotting almost for free (it's just another command row). If the team is committing to a multi-week storage refactor anyway, doing both refactors in one pass is much cheaper than sequencing them.

If neither trigger fires within the next year of production operation, the row-per-event shape is the right long-term home. Atomicity-via-`TransactWriteItems` is paid-for and adequate.

---

## Summary

| Dimension | Row-per-event (today) | Row-per-command (proposed) |
|---|---|---|
| Atomicity (N events) | `TransactWriteItems`, 2× WCU | `PutItem`, 1× WCU per KB — structural |
| Outbox fan-out | Free (1 stream record = 1 event) | Publisher splits row → N messages |
| Causation correlation | `meta.msgId` (rewritten on retry) | `(id, commandSeq)` — durable, structural |
| Snapshotting | Parallel-table refactor | Special-cased command row — natural fit |
| Replay cost (long aggregate) | O(events) | O(commands) — typically smaller |
| Per-aggregate cap | 100 events / command (TransactWriteItems) | ~300 events / command (400 KB row) |
| Migration cost | n/a (current) | 6–10 weeks per platform |
| DCB applicability | Same shape today | Doesn't apply (different schema entirely) |

**Verdict.** Architecturally cleaner, and replaces three backlog plans with one shape change. **Defer until either WCU on multi-event commands or the snapshotting plan forces a storage refactor anyway.** When that day comes, this is the refactor — not snapshotting-on-top-of-per-event-rows.
