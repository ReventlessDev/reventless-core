# Plan: a decision reads its own key across partitions

**Status**: Proposed (2026-11-09, reworked 2026-11-11). [Phase 1](#phase-1-an-app-can-build-its-plugin-without-booting) built 2026-11-11 as `check-start` in `reventless-local` ([the local-dev guide](../guides/local-dev.md#checking-that-the-app-starts-check-start)). [Phase 2](#phase-2-a-count-on-cross-partition-fences) built 2026-11-17; on a deployed stack it takes effect once `count-fences` has run. Phases [3](#phase-3-pairs-in-inference-and-validation), [4](#phase-4-read-split-and-routing) and [5](#phase-5-writer-bumps-on-the-pairs-own-fence-item) built 2026-11-17: a pair works on DynamoDB; [Phase 6](#phase-6-an-end-to-end-case-on-dynamodb-local) is left, and [Q6](#8-questions-with-recommendations) is open. Found in an app whose decision about a
question reads the replies posted under it: the build refused it with "DCB partition
contradiction".<br/>
**Nature**: three pieces that land in order. A check apps can run before boot. A count on
cross-partition fences, which closes a stale-read gap that cross-partition reads already have. Then
the new read scope, opted into per event. No schema change for apps that do not opt in. The count
needs a one-off backfill on apps that already use cross-partition reads.<br/>
**Touches**: `reventless/spec` (`DcbScopeInference`, `DcbValidation`, `DcbTag`), the PPX (the marker
on a consumed event), `reventless/core` (`Dcb_Builder`, `StateChangeSlice_Callback`),
`reventless/aws` (the DynamoDB event-log runtime), the local backends (the condition only),
`scripts/check-dcb-scope.mjs` and its goldens.

Related: [dcb-phase7-cross-partition-reads](done/dcb-phase7-cross-partition-reads.md) (the
capability this extends), [dcb-partition-key-inference](done/dcb-partition-key-inference.md) (the
check that refuses the case today),
[dcb-fence-event-type-granularity](done/dcb-fence-event-type-granularity.md) (the per-type fences
this builds on), [the DCB consistency-check issues](../analysis/dcb-consistency-check-issues.md),
[the partition-key derivation analysis](../analysis/done/dcb-partition-key-derivation.md).

## In plain words

A decision is partitioned by one key: the entity it decides about. Today it can read another
entity's events across partitions only by a key that is **not** its own. This plan lets it read
**its own key** off another entity's events, for the event types it marks. The case is a parent
reading its children: a question reading the replies posted under it.

It is cheap to build, because fences are already per event type. It is not free to use. Every
writer of those child events also writes to a fence of the parent, and the child events are read
from an eventually consistent index. While working that out, this plan found that a stale index
read can slip past today's fences ([§4.3](#43-stale-reads)). The fix is a count kept on the fence
([D8](#3-decisions)). It lands before the new scope and also protects the cross-partition reads
that exist now.

## 1. The case

Take an app where members post messages, reply under them, and mark one reply as the answer to a
question. Its Questions chapter has one decision, `ChangeQuestionState`, holding two commands, `MarkAnswer` and `ReopenQuestion`:

- it produces `AnswerMarked{@partitionTag messageId, replyId}` and `QuestionReopened{@partitionTag messageId}`;
- it consumes `MessagePosted{messageId, …}`, written by `PostMessage`, which is partitioned by `messageId`;
- it consumes `ReplyPosted{replyId, messageId, …}`, written by `PostReply`, which is partitioned by `replyId`.

The rules it decides are "a question has one answer", which needs every `AnswerMarked` for the
message in one partition, and "the answer is a reply under this question", which needs the
`ReplyPosted` events that carry this `messageId`.

The partition is right: the decision is about the question. The read of `ReplyPosted` is right
too. But `ReplyPosted` is stored in the reply's partition, so on DynamoDB a read by `messageId`
never finds it. Locally the read works, because the local backends ignore partitions. That is why
the slice's GWT cases pass and the app is refused only when it boots.

The same shape is already pinned in the test suite as a contradiction:
[`DcbScopeInferenceTest.res:584`](../../reventless/core/tests/dcb/DcbScopeInferenceTest.res#L584),
"a chapter-backed hint read off another entity's events is still a contradiction". There,
`ShipOrder` (partitioned by `orderId`) reads `WarehouseAssigned{warehouseId, orderId}`, which
`AssignWarehouse` writes into the `warehouseId` partition.

## 2. Why it is not supported yet

It was not overlooked. Three earlier decisions each exclude it, for reasons that held when they were
made.

### 2.1 Cross-partition scope belongs to a tag key

[Phase 7](done/dcb-phase7-cross-partition-reads.md) made scope "a static, per-tag-key config"
([its core decision](done/dcb-phase7-cross-partition-reads.md#core-design-decision--scope-is-a-static-per-tag-key-config)).
[Issue 13](../analysis/dcb-consistency-check-issues.md#issue-13--no-single-tag-cross-partition-secondary-tag-read-capability-gap)
gives the reason: the fence is bumped by **writers**, not readers. If one slice reads a key across
partitions, every writer of that key must bump its fence. So scope cannot be per reader, and the
analysis concluded it has to be a property of the whole key.

For a reference key such as `studentId` that is fine. For a slice's **own** key it is ruinous.
Making `messageId` cross-partition for the whole boundary would send every `messageId` decision
(edit, delete, moderation, reactions, reports, questions) through the eventually consistent index
and the extra `GetItem` per event. Every event carrying `messageId` would bump its fence. Inference
therefore never makes a slice's own key cross-partition: the rule requires `Some(k) != own`
([`DcbScopeInference.res:478`](../../reventless/spec/src/components/DcbScopeInference.res#L478)),
and `validateScopeVsInference` calls an explicit `@crossPartition` on the own key a contradiction.

What changed since: two days after [Phase 7](done/dcb-phase7-cross-partition-reads.md), fences
became per **(tag, event type)**
([dcb-fence-event-type-granularity](done/dcb-fence-event-type-granularity.md)). "Writers of
`ReplyPosted` keep a fence for the `messageId` they carry" can now be expressed without touching
any other type's fence, and that is what makes a scope per (event type, key) possible.

### 2.2 The partition check refuses this shape on purpose

[The partition-key inference](done/dcb-partition-key-inference.md) gives each slice the key that
remains after removing keys it only reads from other entities. For `ChangeQuestionState` both produced
keys are also read from other slices' events, so nothing remains. The give-back step then returns
`replyId`, because `ReplyPosted`'s producer is partitioned by it, and blocks `messageId` for the
same reason.

The hint check
([its 2026-09-25 follow-up](done/dcb-partition-key-inference.md#follow-up-2026-09-25-a-hint-its-chapter-agrees-with-is-not-a-contradiction))
accepts a hint that goes against inference only when the chapter backs it **and** every event the
slice reads by that key is written by a slice partitioned by it
([`backedByChapter`, `DcbValidation.res:526`](../../reventless/spec/src/components/DcbValidation.res#L526)).
The chapter does back `messageId`: both Questions events carry it. `ReplyPosted` fails the second
condition, and with no read route for it the build would send storage, fence and read to a key the
read cannot reach. So refusing is the correct answer for today's platform, and this plan changes
the platform, not the check's purpose.

### 2.3 Nothing before boot can see it

A slice's hint is right or wrong only in view of every other slice: here, of how `PostReply` is
partitioned. GWT runs one slice at a time, in memory, where partitions are invisible
([Issue 3](../analysis/dcb-consistency-check-issues.md#issue-3--local-backend--aws-backend-consistency-semantics-test-gap)).
The whole-boundary check runs at boot, at deploy and in `check:dcb-scope`
([F7](../analysis/done/dcb-partition-key-derivation.md#f7--no-compile-time-gate)). `check:dcb-scope`
is a script of this repo and covers only its examples. An app can assert the same thing with
[`Flow_GWT.thenBoundaryScopeResolves`](../../reventless/gwt/src/Flow_GWT.res#L238), but only if it
writes that test. So an app with this shape passes every test it has and fails when it boots.
[Phase 1](#phase-1-an-app-can-build-its-plugin-without-booting) closes that first, because it
matters whether or not the rest of this plan lands.

## 3. Decisions

**D1. An app can build its plugin as boot does, without serving.** A command builds every plugin
of an app through the same builder the platform uses, with no store, no server and no deploy, and
reports what boot would report. It covers every refusal the builder can give, not only partitions,
so the result cannot drift from what boot does. It exits non-zero on a refusal, and prints the
pairs ([D7](#3-decisions)) once they exist.

**D2. A pair is opted into on the consumed event, with `@crossPartition`.** Scope gains a second
form: per (event type, key) pair, for the slice's own key only. The slice marks the key on the arm
it reads across partitions: `ReplyPosted({replyId, @crossPartition messageId, …})` in
`ChangeQuestionState`'s `consumedEvent`. The marker says what the `@partitionTag` cannot: that the reader
accepts an index read, and that another slice's writes will now touch a fence of its partition.
[Phase 7](done/dcb-phase7-cross-partition-reads.md) kept `@crossPartition` off `consumedEvent`
because its scope is per key. A pair is per event type, and the consumed arm is exactly where that
event type is named. A marker on a key that is not the slice's own is refused, pointing to the
per-key form. The boundary-wide `crossPartitionTagKeys` is unchanged and keeps its meaning. A pair
whose key is already in it is redundant.

**D3. Without the marker, the build refuses as it does today, and names the marker as a way out.**
`backedByChapter` keeps its chapter condition unchanged. Its second condition becomes "each event
read by the hinted key from another slice is either written by a slice partitioned by it, or
marked under [D2](#3-decisions)". A hint the chapter does not back (`@partitionTag categoryId` on
`AddProduct`) and a chapter that carries both keys everywhere still fail, marker or not. The
contradiction message for an unmarked arm adds "or mark it `@crossPartition` on `ReplyPosted` to
read it across partitions". The `ShipOrder` test keeps its contradiction, and a new test, with the
marker, turns it into an override with a pair `(WarehouseAssigned, orderId)`.

**D4. The read splits the own-key clause by where each type is stored.** `buildQueryFromCommand`
emits the own-key clause twice: once with the types stored in the `k` partition (base table,
strongly consistent when asked), and once with the pair types. The pair clause carries an optional
marker field (`crossPartition?: bool`) that the DynamoDB adapter routes to the `tag_<k>` index. The
local backends ignore it, as they ignore `crossPartitionTagKeys` today. Routing by clause, not by
key, is what keeps the strong half strong. Index reads fetch their items with `BatchGetItem`, up
to 100 per call, instead of one `GetItem` each.

**D5. A pair has a fence item of its own.** An append of `E` that carries `k`, with `(E, k)` a
pair, updates a fence item for that key value and that event type only. It does not touch the
fence item that the `k` partition's own writers use. So replies contend with each other and with
the readers of the pair, but not with edits, reactions or moderation of the parent. The item holds
the count of [D8](#3-decisions). How it is keyed beside the existing fence items is settled in
[Phase 5](#phase-5-writer-bumps-on-the-pairs-own-fence-item).

**D6. The fence that guards a cross-partition read checks a count, not a position.** That applies
to pairs and to [Phase 7](done/dcb-phase7-cross-partition-reads.md)'s per-key reads. A position
says only that nothing newer was written, while a count also shows whether anything older was
missed ([§4.3](#43-stale-reads)). The append condition on such a fence is `n#<type> = :seen`. The
partition-scoped fences keep their `pos#<type>` check unchanged.

**D7. A pair is visible where it costs.** The builder logs one info line per pair naming the reader
and the writer that now updates a fence of the reader's ("PostReply now updates fence messageId
for ChangeQuestionState"). The `dcb-scope.json` golden records the pairs, so adding one shows up in review
as a change to the writer's write path. When the writer's transaction already carries other
cross-partition or composite fences, the line becomes a warning, because each one adds an item to a
transaction capped at 100 items
([Issue 11](../analysis/dcb-consistency-check-issues.md#issue-11--100-item-transactwriteitems-cap-is-a-hard-cliff)).

**D8. A cross-partition fence keeps a count of what was written, and the reader proves it saw it
all.**

- **Writer:** every append of a type `C` that carries a cross-partition key value also adds 1 to
  `n#C` on that value's fence, in the same transaction. For a per-key read that is the fence it
  already bumps; for a pair it is the item of [D5](#3-decisions).
- **Reader, before deciding:**
  - It reads each such fence item with a strongly consistent `GetItem`, then queries the index.
  - For each type `C`, it compares the events it read with `n#C`. Fewer read than counted means the
    index is behind, so it waits briefly and queries again, a few times at most.
  - If the index is still behind, the command fails as a retryable conflict, never as a refusal of
    the decision.
- **Append:** the condition is `n#C = :read` ([D6](#3-decisions)), which catches writes made after
  the read.
- **Cache:** the projection cache keeps the counts with the state. When the fence counts equal the
  cached ones, nothing is read from the index. When they differ, the delta since the cached head is
  read, and if the cached count plus the delta does not reach the fence count, the clause is read
  in full.

**D9. The count is enforced only once it is complete.** Events written before the count existed
are not in it. A fence item carries `counted: true` once its count includes them. Until then the
reader checks as today and the cache does not trust the count. A backfill sets it per key value
([Phase 2](#phase-2-a-count-on-cross-partition-fences)).

## 4. Consequences

Worked on the question case: one question with `n` replies, `PostReply` partitioned by `replyId`.

### 4.1 Reads

| | Today (refused) | With this plan |
|---|---|---|
| `MarkAnswer`, nothing changed since the last command | one strong partition query by `messageId` (delta from the cache) | the same, plus one strongly consistent `GetItem` of the pair's fence item |
| `MarkAnswer`, new replies since | as above | as above, plus one index query and `BatchGetItem` for the new replies |
| `MarkAnswer`, cold | one strong partition query | as above, with all `n` replies fetched in batches of 100 |
| Consistency of the reply half | none (it cannot boot) | complete as of the fence read ([D8](#3-decisions)), at the cost of a short wait when the index lags |

The cold read still grows with the number of children: about `n / 2` read units at eventual
consistency for small items. The read side of
[Issue 13's cost section](../analysis/dcb-consistency-check-issues.md#performance--cost) applies to
it. A warm decision pays one item read per command while nothing changes.

### 4.2 Writes

- `PostReply` gains one item in its transaction per reply: the pair's fence item, with `n` and
  `pos` updated. That costs 2 write units.
- **Contention moves to the parent, but only among the pair.** Concurrent transactions that touch
  the same item conflict on DynamoDB. Before, each reply touched only its own `fence#replyId:*`.
  After, every reply under one message touches that message's pair item. So does every
  `MarkAnswer` whose append checks it. Edits, reactions and moderation of the parent do not, since
  they keep their own fence item ([D5](#3-decisions)). A very busy thread can still reach the
  per-item ceiling
  ([Issue 10](../analysis/dcb-consistency-check-issues.md#issue-10--hot-tag-fence-ceiling-retry-exhaustion-surfaces-as-conflict)).
- The cost lands on a slice whose own spec did not change. That is why [D7](#3-decisions) exists.
- Per-key cross-partition writers ([Phase 7](done/dcb-phase7-cross-partition-reads.md)) gain no
  item: `n#C` is added to the update they already make.

### 4.3 Stale reads

What an eventually consistent index read can get wrong, and what the count does about it:

1. **A refusal made on a stale read.** `MarkAnswer` for a reply posted a moment ago reads no such
   reply. Nothing is appended, so today no fence checks anything, and the user sees a refusal that
   succeeds on the next try. With the count, the reader sees it read fewer replies than counted,
   waits and reads again before deciding.
2. **A newer event in another clause hides a missed one.** Today the fence compares every type
   against one head position for the whole query
   ([fence update, `DcbEventLogStorage_DynamoDb_Runtime.res:775`](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res#L775)).
   If the index misses reply 12 while the strong clause reads an `AnswerMarked` at 15, `after` is
   15, `pos#ReplyPosted` is 12, and the check passes. With the count the missed reply is visible:
   one read, two counted.
3. **A newer index entry hides an older missed one.** If the index shows reply 14 but not reply 12,
   the highest position read is 14 and the fence holds 14, so no position check can notice.
   DynamoDB does not promise that index entries for different items appear in write order. The
   count notices: two counted, one read.

Cases 1 to 3 apply to [Phase 7](done/dcb-phase7-cross-partition-reads.md)'s reads today. They have
not been observed. This is analysis, and [Phase 2](#phase-2-a-count-on-cross-partition-fences)
records them as a new entry in
[the consistency-check issues](../analysis/dcb-consistency-check-issues.md#issue-inventory).

What remains is availability, not consistency. While the index lags, commands that need it wait,
and past the limit they fail as retryable conflicts.

### 4.4 What does not change

- **Apps without cross-partition reads**: nothing. No new item, no new read, no new condition.
- **Data**: no migration of events. `ReplyPosted` already stores a `tag_messageId` attribute,
  because inference indexes a key that any slice consumes. Counts start on deploy and are completed
  by the backfill ([D9](#3-decisions)).
- **Local and GWT**: no behavior change, since they already read literally. The local condition
  accepts the count for parity.
- **Existing goldens** of the example apps stay byte-identical except for a new, empty pair list.

## 5. Disadvantages and when not to use it

Use it when the decision needs a few of another entity's events that carry its own key, and the
writer can afford one more item per write. "This reply is under this question" fits.

Do not use it when:

- **A parent has many children, or children arrive fast.** Every child write contends on the
  parent's pair item, and a cold decision reads every child ([§4.1](#41-reads), [§4.2](#42-writes)).
- **The children are written by a hot path that must not slow down.** The reader imposes the
  extra item on the writer.
- **The rule counts or limits children** ("at most 10 replies") and the children are written often.
  The count makes this correct, but every decision then waits for the index to catch up with every
  new child. Partitioning the children by the parent ([option 1](#6-alternatives)) is strongly
  consistent, needs no index, and costs the same contention.
- **The fact can be carried instead of read.** If the command or the event already knows the
  reference, check it there or in a view. A view is not consistent either, but it is free for the
  decision.
- **The command must answer within a strict latency.** A lagging index makes it wait, and past the
  limit it fails, to be retried.

A plain design-level warning sign: if a decision needs much of another entity's history, the
consistency boundary probably belongs to that other entity, or to a shared parent.

## 6. Alternatives

1. **Partition the children by the parent.** `PostReply`, `EditReply` and `DeleteReply` all move to
   `messageId`. This is strongly consistent and has no index read. It costs a re-keyed chain of
   slices, edit and delete commands that must carry the parent id, and contention among a parent's
   children. It is the better answer when a rule counts children that are written often.
2. **Do not read the children.** `ChangeQuestionState` drops `ReplyPosted` and the reply check moves to the
   view the screen already uses. This is the cheapest option. It loses the check under concurrency,
   which matters little for an immutable parent link.
3. **Make the own key cross-partition for the whole boundary.** This is ruled out in
   [§2.1](#21-cross-partition-scope-belongs-to-a-tag-key).
4. **Partition the decision by the child key.** This is what the error message suggests. It loses
   "one answer per question", because each reply gets its own partition.

This plan does not replace [option 1](#6-alternatives) or [option 2](#6-alternatives). It adds a
third choice for the case where neither the rule nor the shape fits them.

## 7. Phases

In this order. Phases 1 and 2 are worth having even if the pair never ships.

### Phase 1. An app can build its plugin without booting

[D1](#3-decisions). The command runs the plugin builder the way `Platform` does, with in-memory
stand-ins and no server. It exits with the builder's message. It lives in the package that apps
already depend on to boot locally, so it needs no new dependency.

**Verify:** an app with the question-and-reply shape fails the command with the same message boot
gives. The examples pass it. A refusal that is not about partitions (for example a boundary that
does not resolve) is reported too.

### Phase 2. A count on cross-partition fences

[D6](#3-decisions), [D8](#3-decisions) and [D9](#3-decisions) for
[Phase 7](done/dcb-phase7-cross-partition-reads.md)'s per-key reads, before any pair exists:

- writers add to `n#C`;
- the reader does the strongly consistent fence read, compares and retries;
- the append checks the count, and the cache keeps it;
- local backends check the count literally;
- a backfill completes the count per key value for apps already deployed;
- cases 1 to 3 of [§4.3](#43-stale-reads) are recorded in the issue inventory.

In five steps, each shippable alone:

1. **The writers count.** Built 2026-11-17. Every fence update of a cross-partition tag, on the
   conditional and the unconditional append, adds the events it writes to `n#<type>` and sets
   `countedFrom` to its position if no write has set it yet. Nothing reads the count yet.
2. **The reader proves it saw them all.** Built 2026-11-17. The event log gains an optional
   `readFences`, a strongly consistent `GetItem` per fence (DynamoDB only; the local backends leave
   it out). The slice callback reads the fences of its cross-partition clauses before the index,
   counts what it reads into the cached counts (`DcbFenceCount`), and on a shortfall of a counted
   fence reads again in full after 100, 200 and 300 ms. That uses the same three retries as an
   append conflict. Past them it answers `Conflict`. A fence not yet `counted` is not checked.
3. **The append checks the count, and the cache keeps it.** Built 2026-11-17. `appendCondition`
   gains `fenceCounts`, what the reader read of each type of each counted fence. On DynamoDB the
   fence's condition for those types becomes `n#C = :read` in place of the position check, so an
   older event missing behind a newer one is refused, which the position check lets through (the
   DynamoDB-local test shows both). The local backends ignore the field: they check literally.
4. **The backfill.** Built 2026-11-17 as `count-fences` in `reventless-aws`
   (`--table`, `--keys`, `--dry-run`, `--recount`). It reads the fences strongly, waits for the
   index to settle, counts every event of each type through the index, and sets the counts to that
   and `counted`, on condition that each count is still what it read. A fence a writer moved
   meanwhile is counted again. This replaces the `countedFrom` cut-off first planned for
   [Q5](#8-questions-with-recommendations): a writer still on the old code during the rollout
   writes after `countedFrom` without counting, and a count left one short would conflict every
   append on that fence. `countedFrom` stays, as a record of when counting began.
5. **The issue inventory** records cases 1 to 3. Done 2026-11-17, as Issue 15 of
   [the consistency-check issues](../analysis/dcb-consistency-check-issues.md#issue-15--a-cross-partition-read-can-miss-an-event-behind-a-position-check-that-passes).

**Verify:**

- Red-then-green adapter tests for cases 1 to 3 with a fake index that returns stale pages,
  including an older entry missing behind a newer one. DynamoDB-local updates its indexes at once,
  so it cannot show them.
- The course-subscription fixture passes as before.
- A fence item without `counted` is checked as today.

### Phase 3. Pairs in inference and validation

[D2](#3-decisions) and [D3](#3-decisions): the PPX accepts `@crossPartition` on a consumed arm,
`DcbScopeInference` derives `crossPartitionPairs`, and `deriveEffectiveScope` returns them.
`validatePartitionHintsVsInference` accepts the chapter-backed case when the arm is marked, and its
refusal names the marker. `check-dcb-scope.mjs` records the pairs.

**Verify:** the `ShipOrder` / `WarehouseAssigned` test stays a contradiction without the marker, and
becomes an override with one pair with it. A new test reproduces the `ChangeQuestionState` shape both
ways. A marker on a key that is not the slice's own is refused. The `AddProduct` and "both keys
everywhere" contradictions are unchanged. All example goldens are unchanged apart from an empty
pair list.

**Built 2026-11-17.** The PPX needed no change: it already turns `@crossPartition` on a
`consumedEvent` field into `DcbTag.crossPartition`, and nothing read it there. Now:

- **The shape.** `sliceShapeFromSchemas` marks such a field `crossPartition` on the slice's shape.
- **The pairs.** `infer` derives `crossPartitionPairs` as (reader, event type, key, writers).
  `deriveEffectiveScope` returns them, and `check-dcb-scope` records them in the goldens.
- **The new check.** `validateCrossPartitionArms` refuses a marker on a key that is not the
  slice's partition. It reports one as redundant when the event's writers already store it under
  that key, or when the boundary already reads the key across partitions. The boundary already
  reads it that way when, for example, `PostReply` itself reads `MessagePosted` by `messageId`.
- **The builder.** The builder and `Flow_GWT.thenBoundaryScopeResolves` refuse a marker on
  another key. Until [Phase 4](#phase-4-read-split-and-routing) and
  [Phase 5](#phase-5-writer-bumps-on-the-pairs-own-fence-item) land, the builder also refuses a
  boundary that has a pair, naming it: nothing yet reads a pair's events across partitions.

Building it found a gap in today's check. The question shape of [§1](#1-the-case) was no longer
refused, as [§2.2](#22-the-partition-check-refuses-this-shape-on-purpose) says. Since
`QuestionReopened` lacks `replyId`, inference finds no partition, and a hint that decides an
unresolved slice was accepted without asking what the slice reads by it. So on DynamoDB its read
of `ReplyPosted` silently found nothing. That path now applies the same condition as the
chapter-backed one: an event read by the hinted key that its writers store under another key, and
that is not marked, is a contradiction, and the message names the marker. An event whose writer is
outside the boundary is not counted, since where it is stored is not known there.

### Phase 4. Read split and routing

[D4](#3-decisions): split the clause, add the optional clause marker, route it in
`executeQueryItemStream` and `executeQueryItem`, and fetch index hits with `BatchGetItem`.

**Verify:** a query test shows the strong clause and the pair clause. An adapter test shows the
routing, which has no unit test today.

**Built 2026-11-17.**

- **The pairs reach the slice.** The boundary's pairs travel to each slice beside
  `crossPartitionTagKeys`: from `Dcb_Builder`, and in the deployed command handler from
  `deriveEffectiveScope`. A slice keeps the pairs it is the reader of
  (`DcbScopeInference.pairEventTypes`).
- **The query splits.** `buildQueryFromCommand` takes those types per key and splits a single-tag
  clause on such a key. The other types stay in a clause read from the partition, and the pair's
  types go to a clause marked `crossPartition: true`. A composite clause is left whole, since the
  index reads by one tag only.
- **DynamoDB routes it.** The adapter sends a marked clause to `tag_<key>` (`readsAcrossPartitions`,
  which now has its unit test). The local and Postgres backends ignore the marker.
- **Hits are fetched in batches.** Every index read resolves its hits with `BatchGetItem`, up to
  100 keys a call, sending again the keys DynamoDB left unprocessed. That covers the per-key reads
  of [Phase 7](done/dcb-phase7-cross-partition-reads.md) too.
- **What DynamoDB-local shows.** A partition read misses events stored under another key, and the
  split read finds them. 130 hits come back whole and in position order.

The pair's clause is not yet counted against a fence ([D8](#3-decisions)): that needs the pair's
fence item from [Phase 5](#phase-5-writer-bumps-on-the-pairs-own-fence-item).

### Phase 5. Writer bumps on the pair's own fence item

[D5](#3-decisions) and [D7](#3-decisions): pass the pairs to the storage maker, give a pair its own
fence item (keyed beside the existing items the way
[fence sharding](done/dcb-hot-tag-fence-contention.md#1-fence-sharding-via-composite-sort-key)
keys its shards), and add the update in `buildConditionalTransactItems`. The builder logs the info
line or warning.

**Verify:** a transaction-shape test shows that a `ReplyPosted` append updates the pair's item and
nothing else new. A `MessagePosted` append is unchanged.

**Built 2026-11-17.**

- **The item.** A pair's fence item is `fence#<key>:<value>` / `FENCE#<eventType>`. The event log
  takes `pairFenceTypes`, key to the types with a pair fence (`DcbScopeInference.pairFenceTypes`).
- **Writers.** Every append, conditional or not, of such a type carrying the key updates the item
  without a condition: `SET pos#<type>`, `ADD n#<type>`, and `countedFrom` if not yet set.
- **The reader.** Its `crossPartition` clause becomes a check on that item, and leaves the key
  value's own fence item, which the pair's writers never move. The check uses the count it read
  when the item is `counted`, and the position otherwise. `readFences` reads a pair key's counts
  off its pair items, and `DcbFenceCount.clauses` now takes the pair's clause, so the reader's
  count check of [Phase 2](#phase-2-a-count-on-cross-partition-fences) covers it.
- **The backfill.** `count-fences` takes `--pairs key:EventType,...` and counts a pair's item by
  its one type.
- **The builder.** It logs [D7](#3-decisions)'s line per writer and pair, as a warning when the
  writer's appends already carry other cross-partition, composite or pair fences. It no longer
  refuses a boundary with a pair.
- **What DynamoDB-local shows.** An order moves the pair's item, so a reader that read before it
  conflicts. Once the item is counted, an append that read one order fewer than were counted
  conflicts, though its position check would pass.

### Phase 6. An end-to-end case on DynamoDB-local

The question-and-reply shape as a fixture: post a reply, mark it as the answer, then mark a second
reply and see `QuestionAlreadyAnswered`. Also check that two concurrent replies under one parent
conflict on the pair's item and both succeed on retry, while an edit of the parent at the same
time does not conflict with them. Local backends cannot show this
([Issue 3](../analysis/dcb-consistency-check-issues.md#issue-3--local-backend--aws-backend-consistency-semantics-test-gap)).

## 8. Questions, with recommendations

**Q1.** Is a chapter-backed `@partitionTag` enough to opt into a pair? **Decided: no.** The hint
says what the decision is about, not that it accepts an index read and a cost on another slice. The
marker on the consumed arm ([D2](#3-decisions)) says that, in the reader's own source.

**Q2.** Should a pair be refused when the writer is already hot? **Recommended: no.** The build
cannot know how busy an event is. [D7](#3-decisions) names the cost, warns when the writer's
transaction already carries other cross-partition or composite fences, and fence sharding exists
for a busy parent.

**Q3.** Should index reads be re-read after a delay before an acceptance that depends on them?
**Recommended: no; the count replaces it.** [D8](#3-decisions) knows when the index is behind
instead of guessing.

**Q4.** Should the boundary-wide `crossPartitionTagKeys` become pairs too? **Recommended: not now.**
It would narrow the fences of apps that already run per-key reads, and so needs a migration. Revisit
when such a fence shows contention in a deployment.

**Q5.** How does the backfill of [D9](#3-decisions) count events written before the count existed,
while writes go on? **Decided 2026-11-17:** it counts every event of each type and sets `n#C` to
that, conditioned on `n#C` being what it read, after the index has had time to settle. A cut-off
would miss writes by a Lambda still on the old code during the rollout, and a count left short
conflicts every append on its fence. A key value without the flag is checked as today until its
backfill has run ([Phase 2](#phase-2-a-count-on-cross-partition-fences), step 4).

**Q6.** A fence item is trusted only once `counted` is set, and only `count-fences` sets it. A key
value first written after the backfill gets an item whose count is complete from its first write,
but which no reader trusts, so it is checked by position for good. That holds for
[Phase 2](#phase-2-a-count-on-cross-partition-fences)'s fences as much as for a pair's. How should
an item count from birth? **Recommended:** `count-fences` records, per key, the position it ran at.
A reader trusts an item that is `counted`, or whose `countedFrom` is later than that position. Any
item that existed when the backfill scanned was counted then, so one first counted after it began
counting with its first event. The cost is one more strongly consistent read per key, which a
Lambda can keep for its lifetime.

## 9. Non-goals

- Changing the meaning of `crossPartitionTagKeys` or of any existing golden ([Q4](#8-questions-with-recommendations)).
- A strongly consistent index read. DynamoDB has none; the count works around it.
- [Issue 6](../analysis/dcb-consistency-check-issues.md#issue-6--single-global-after-across-a-multi-clause-or-query)
  for partition-scoped clauses. The count settles the stale-read case for cross-partition clauses.
  False conflicts from one head across several partition clauses stay that issue.
- Fence sharding for hot parents. That is
  [the hot-tag plan's fence sharding](done/dcb-hot-tag-fence-contention.md#1-fence-sharding-via-composite-sort-key),
  usable as it is.
