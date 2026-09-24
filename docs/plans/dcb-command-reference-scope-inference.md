# Plan: a command reference no decision reads by stays out of the query

**Status:** 📝 Proposed 2026-09-24. Nothing built.<br/>
**Follows:** [dcb-tag-scope-inference](done/dcb-tag-scope-inference.md), whose rule 3 settles
index-vs-payload for keys on **events**. This adds the same rule for keys on **commands**.

---

## Why

A command's decision query is one clause that ANDs every tag the command carries
(`DcbTag.buildQueryFromCommand`, `reventless/spec/src/components/DcbTag.res:983`). The clause
keeps only the event types that carry every one of those tags
(`narrowEventTypesForTags`, `DcbTag.res:901-911`).

An identity-typed field is tagged automatically
(`packages/reventless-ppx/src/ppx/DcbTagInference.ml:182-188`), and so is a plain
`xxxId: string` by its name alone. So a command that names a second thing only as information
narrows its own query, whether the field is typed or not:

```rescript
type command = ShipOrder({orderId: OrderId.t, carrierId: CarrierId.t})
```

- `orderId` is the partition.
- `carrierId` is not a key any slice partitions by, and not a foreign read: nothing is
  decided per carrier.
- The clause is `orderId=o1 AND carrierId=c1`. Every event about the order that does not
  carry `carrierId` drops out, and by rule 3 the slice's own `OrderShipped` does not index
  `carrierId` either. The decision sees nothing.

The GWT harness already treats this as a bug
(`unreachableForeignReads`, `reventless/gwt/src/Behavior_GWT.res:315-326`: *"a decision-query
clause that selects … on tag 'orderId' alone"*). But the only way out today is `@noDcbTag` on
the field, which is exactly the kind of hand-placed scope annotation the inference plan set
out to remove. Authoring tools that write identity-typed fields from a picker produce this
shape by default, and their authors never see a tag.

## The rule

**Rule 4 — command scope.** A scalar key on a command is a query tag iff it is the slice's
partition (rule 1) or is read cross-partition by the slice (rule 2). Any other scalar key is
**payload**: it stays on the command, is not tagged, and does not enter the query or the
append condition.

- It covers both ways a key is tagged: an identity type and an `…Id` name.
- Array keys (`*Ids`) are unchanged: they already fan per element and are partition-scoped.
- Explicit annotations still win. `@partitionTag`, `@compositePartitionTag`,
  `@crossPartition` and `@dcbTag` keep a key in the query; `@noDcbTag` stays redundant but
  harmless, and the redundancy check reports it.
- The fence is the query, so dropping the tag *widens* the fence to the whole partition. That
  is the consistency the author meant: shipping an order is checked against the order.

## Where it goes

- **`DcbScopeInference.res`**: `commandPayloadKeysForSlice(s)` = `commandScalarKeys(s)` minus
  the partition minus `crossPartitionForSlice(s)`. `infer` exposes it per slice
  (`commandPayloadKeysBySlice`), beside `crossPartitionTagKeys`.
- **`DcbTag.buildQueryFromCommand`**: takes the payload keys and filters them out of the tags
  before building clauses.
  `reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res:183` passes
  them.
- **GWT harness**: derives the same keys per slice, as it already does for cross-partition
  (`crossPartitionForSlice`), so a test sees the production query.
- **Validation**: the redundancy check learns that `@noDcbTag` on such a key is now implied.

## Phases

- **P1**: the pure rule in `DcbScopeInference` with unit tests: `ShipOrder` (payload
  `carrierId`); a foreign-read key stays cross-partition; an array key is unchanged; explicit
  `@crossPartition` on the same key wins.
- **P2**: the runtime query and the GWT harness use it. A GWT test for the `ShipOrder` shape
  that fails today with the harness's unreachable-read error and passes after.
- **P3**: the redundancy check, and a note in `dcb-usage.md` that a command reference nothing
  decides by needs no annotation.

## Open question

**Should a key the slice's own consumed events carry, but no other slice owns, still count?**
Example: a command carrying a reference it also wrote on its own past events, so that a
decision can check "not twice for the same carrier". That is a real fence per carrier, but
rule 3 does not index the key on the event, so the read could not work anyway. The
recommendation is payload, with `@dcbTag` as the explicit way to ask for the fence.
