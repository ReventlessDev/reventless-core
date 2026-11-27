# Plan: a decision reads a small kind of event whole

**Status**: Proposed 2026-11-27. Nothing built yet; [KQ1](#6-questions-with-recommendations) and
[KQ2](#6-questions-with-recommendations) are open.<br/>
**Nature**: a new read scope, opted into on the consumed arm. It reuses the cross-partition read and
its fences, so the stores gain no new kind of index or fence. No change for apps that do not opt in.
An app that opts in on a deployed stack backfills the tag on its stored events once.<br/>
**Touches**: `reventless/spec` (`DcbScopeInference`, `DcbValidation`, `DcbTag`), the PPX (a marker on
a consumed case), `reventless/core` (`StateChangeSlice_Callback`, the append path), the local and
Postgres backends (tests only), `reventless/aws` (the DynamoDB tag index and the backfill),
`check-start`, and the DCB shop example.

Related: [a decision reads its own key across partitions](done/a-decision-reads-its-own-key-across-partitions.md)
(the pair, whose route and fence this reuses), [dcb-phase7-cross-partition-reads](done/dcb-phase7-cross-partition-reads.md)
(the per-tag index read), [dcb-fence-event-type-granularity](done/dcb-fence-event-type-granularity.md)
(fences per tag and event type).

## In plain words

A decision finds the events filed under the tags its command carries. Some decisions need a short
list that no command names: the delivery options a shop offers and their fees, a price list, a set of
settings. Each entry is kept under its own name, so a decision about an order finds none of them.

Today the only ways round it are to copy the list onto every record that might need it, or to make
the decision read nothing but the list. This plan lets a decision read **every event of a kind**
beside what it reads by its tags, for the kinds it marks. It is meant for kinds with few events: the
decision reads all of them on every command, and any write of that kind conflicts with it.

## 1. The case

The DCB shop's ordering gets delivery fees: `SetDeliveryFee({deliveryOption, fee})` keeps one fee per
delivery option (*standard*, *express*), partitioned by `deliveryOption`, and produces `DeliveryFeeSet`. `PlaceOrder`,
partitioned by `orderId`, quotes the order with the fee of every delivery option, so the customer can choose.
Its command carries the order, never a delivery option before the customer chose one.

`PlaceOrder` lists `DeliveryFeeSet` among its consumed events. Its query is one clause by
`orderId`, which no `DeliveryFeeSet` carries, so narrowing drops the type and the decision sees no
fee. Making `deliveryOption` cross-partition does not help: the command carries none to read by.

## 2. What exists

- A clause with no tags matches every event of its types. A command with no tags builds one, and
  every store reads it: the local stores by filtering, DynamoDB by a scan
  ([`DcbEventLogStorage_DynamoDb_Runtime.res`](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res)).
  But a command with tags cannot add such a clause beside them.
- On DynamoDB that scan is guarded by no fence: the append condition skips a clause with no tags.
  A write of the kind between the read and the append is not seen.
- A cross-partition clause (`crossPartition: true`, one tag) reads by the per-tag index, and every
  writer of an event carrying the tag bumps its fence per event type, which the reader checks
  with a count. This is what a pair uses.

## 3. Decisions

**KD1. A kind is read whole by a tag every event of it carries.** An event of a kind some slice of
the boundary reads whole is tagged by the kind tag, `{key: "reventless.kind", value: <event type>}`
([KQ2](#6-questions-with-recommendations)), when it is appended. The
reader's clause is `{eventTypes: [type], tags: [kind tag], crossPartition: true}`. The read, the
fence, its count and the writer's bump are the cross-partition read's, unchanged. This gives the
whole read the guard the scan lacks, without a new index or fence.

**KD2. A whole read is opted into on the consumed case, with `@readWhole`.** `PlaceOrder`'s
`consumedEvent` marks `@readWhole DeliveryFeeSet({deliveryOption, fee})`. The marker says what the slice
accepts: an index read of every event of the kind, and a conflict with every write of it. A case
without the marker is read as today.

**KD3. A case read whole takes no part in the slice's partition.** Inference leaves it out of the
foreign reads (rule 1) and the cross-partition candidates (rule 2), and the validation never calls
it stored elsewhere. Its type leaves every tagged clause of the query; the narrowing would drop it
there anyway.

**KD4. The boundary knows its whole kinds.** `DcbScopeInference.infer` derives `wholeEventTypes`
(every type some slice reads whole), as it derives the pairs. The append path tags those types,
and `check-start` prints them beside the pairs.

## 4. Phases

### KR1. The spec: marker, shape, inference, query

The PPX reads `@readWhole` on a consumed case into the schema's metadata. `eventShape` gains
`whole?: bool`; inference and validation follow [KD3](#3-decisions) and give `wholeEventTypes`.
`buildQueryFromCommand` takes `~wholeEventTypes`: those types leave every tagged clause, and each
gets its clause by the kind tag. A command with no tags keeps its one clause by type, which already
reads them all.

*Done when:* `DcbScopeInferenceTest` and `DcbTagTest` cover the case of [§1](#1-the-case): the query
has the order clause without `DeliveryFeeSet` and the kind clause; `PlaceOrder`'s partition is
`orderId`; no contradiction.

### KR2. The append path tags, the local stores read

The core append path adds the kind tag to each event of a whole kind. The in-memory and Postgres
backends read the kind clause as any one-tag clause. The GWT runner builds the query the same way,
so a slice's cases see the list.

*Done when:* `PlaceOrder`'s GWT case quotes both delivery options, and a write of `DeliveryFeeSet` between a
read and an append conflicts on the local backends.

### KR3. DynamoDB: the index, the fence, the backfill

The kind tag is one more tag key: it gets its `tag_reventless.kind` index at deploy, as each tag key does, and
its fences are bumped and counted as a cross-partition tag's. A one-off backfill tags the stored
events of a kind that becomes read whole, as `count-fences` fills the counts.

*Done when:* an end-to-end case on DynamoDB local reads the fees and refuses a stale append.

### KR4. The example and the guide

The DCB shop gets `SetDeliveryFee` and `PlaceOrder`'s quote. The DCB guide says when a whole read
fits, and when it does not (a kind that grows with the business).

*Done when:* the shop's tests and `check:dcb-scope` pass with the whole read printed.

## 5. What it costs

Every command of a reader reads every event of the kind, and every write of the kind bumps the
kind's fence, so it conflicts with every reader in flight. For a list of a few entries changed
rarely, both are negligible. For a kind that grows (orders, sessions) it is wrong, and the guide
says so.

## 6. Questions with recommendations

**KQ1. Should the platform refuse a whole read of a kind that is large?**
**Recommendation:** no refusal, a warning: the platform cannot know a kind's size before it runs.
The read logs a warning when it returns more than a set number of events (100 by default), so a
misuse shows in the logs without breaking a running app.

**KQ2. Is the kind tag `kind`, or a name no app can use?**
**Recommendation:** a reserved key, `reventless.kind`: no field name can hold a dot, so the tag never
clashes with an app's own `kind` field, and a DynamoDB index name may hold one
(`tag_reventless.kind`).
