# Plan: a command reference no decision reads by stays out of the query

**Status:** ✅ Done 2026-09-24. All three phases built; see [What was built](#what-was-built).<br/>
**Follows:** [dcb-tag-scope-inference](dcb-tag-scope-inference.md), whose rule 3 settles
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

## Open question (settled)

**Should a key the slice's own consumed events carry, but no other slice owns, still count?**
Example: a command carrying a reference it also wrote on its own past events, so that a
decision can check "not twice for the same carrier". That is a real fence per carrier, but
rule 3 does not index the key on the event, so the read could not work anyway. The
recommendation is payload, with `@dcbTag` as the explicit way to ask for the fence.

**Settled as recommended:** payload. `@dcbTag` on the command keeps the key in the query.

## What was built

In plain words: a command no longer narrows its own decision read by an id it only carries
as information. The slice reads its partition's history, and the id stays on the command.

- **The rule** is `DcbScopeInference.commandPayloadKeys(s, ~partition, ~crossPartition)`:
  scalar command keys, minus the partition, minus keys read off a foreign event, minus the
  boundary's cross-partition keys, minus declared or list keys. The plan's formula
  (`commandScalarKeys − partition − crossPartitionForSlice`) reduces to the same set.
- **No `commandPayloadKeysBySlice` on `infer`.** Every caller already hands the slice callback
  its partition (`~partitionTag`) and the boundary's cross-partition keys, so the slice
  derives its own payload keys (`DcbTag.commandPayloadTagKeys`). Deploy (`Dcb_Builder`), the
  deployed entry point and the local platform are covered with no new threading. A composite
  boundary keeps every tag.
- **Explicit annotations.** `@partitionTag`, `@crossPartition` and `@compositePartitionTag`
  were already visible on the schema. `@dcbTag` was not: it emitted the same
  `DcbTag.string` as auto-tagging. The PPX now emits `DcbTag.declared` /
  `declaredForKey` / `markDeclared` / `markDeclaredForKey`, and the shape carries
  `idField.declared`. A `@crossPartition` on the slice's **own** events is honoured too,
  since that is where the M:N capacity read declares it (`SubscribeStudent`).
- **`buildQueryFromCommand ~payloadTagKeys`** drops the keys from every clause, in both query
  modes. The append condition is the same query, so the fence widens to the partition.
- **GWT harness** (`Behavior_GWT`, `Flow_GWT`) derives the same keys against the partition
  the slice resolves to alone. `StateChangeSliceGwtTest`'s `ShipOrder` case fails with the
  unreachable-read error when the keys are withheld, and passes with them.
- **Validation.** `validateCompositeReads` ignores payload keys, so it no longer warns about
  a composite clause the slice does not issue. `DcbValidation.validateCommandTagSuppressions`
  reports a `@noDcbTag` on a command key that is payload anyway. The PPX consumes the
  attribute, so `check:dcb-scope` reads the suppressed fields off the spec's `type command`
  block. It flagged the hybrid example's `PlaceOrder.customerId`, whose annotation is removed.
- **Docs.** `dcb-usage.md` § "Command references nothing decides by", with the
  `statechangeslice.md`, `reventless-ppx.md` and `dcb-consistency-checks.md` passages that
  recommended `@noDcbTag` on a command.

### Findings

- **The `ShipOrder` shape above, seen alone, is partitioned by `carrierId`.** A consumed
  `OrderPlaced({orderId})` is a foreign arm, so rule 1 subtracts `orderId`. In a plugin the
  chapter (`Order/`) settles it; the harness sees no chapter, so the test's event names
  its partition with `DcbTag.partition`.
- **External consumers need the republished PPX.** An older binary emits a plain tag for
  `@dcbTag`, so a `@dcbTag` on a `*Id` command field would read as payload there. No
  example in this repository writes one.
- **`@ref` + `@dcbTag("k")`** passes the key through `Reference.to_`, which carries no
  declared marker. A command reference written that way is still judged by rule 4.
