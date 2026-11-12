# Plan: a decision reads its own history written elsewhere

**Status**: Built 2026-11-12. [§3](#3-the-change) is in `DcbScopeInference`, with the tests of
[§5](#5-tests).<br/>
**Nature**: a change to two of the scope rules. No schema change, no annotation, no backfill.<br/>
**Touches**: `reventless/spec` (`DcbScopeInference`: `readByKeys`, rules 2 and 4). Every caller
of those rules follows: `Dcb_Builder`, `StateChangeSlice_Callback`, the GWT harness and the
deployed command handler.

Related: [a decision reads its own key across partitions](a-decision-reads-its-own-key-across-partitions.md)
(the opposite case: a parent reading its children by its own key),
[dcb-command-reference-scope-inference](done/dcb-command-reference-scope-inference.md) (where
rule 4 came from), [dcb-phase7-cross-partition-reads](done/dcb-phase7-cross-partition-reads.md)
(what a cross-partition key costs).

## In plain words

A thing is kept by its own id and names another thing it belongs to: a contact names its
customer. A decision that moves the contact to another customer reads the contact's own history.
Part of that history was written by another decision, the one that added the contact.

Today the scope rules count any event written by another decision as a reference to another
entity, and every id on it as a key the decision reads by. So the move looks the contact up by
the contact **and the customer it moves to**, and reads by the customer across partitions. Its
history was written under the old customer, so the move cannot see it: the contact seems not to
exist.

An event that carries the decision's own partition key is that entity's history, whoever wrote
it. The other ids on it are what the entity says, not keys to read by. That is already rule 1's
view; this plan makes rules 2 and 4 take it too.

## 1. The case

- `AddCustomer` produces `CustomerAdded{customerId}`.
- `AddContact` produces `ContactAdded{@partitionTag contactId, customerId}`.
- `MoveContact` takes `MoveContact{contactId, customerId}` (the customer it moves to), produces
  `ContactMoved{@partitionTag contactId, customerId}`, and consumes `ContactAdded` and
  `ContactMoved`, each with both ids.

Partitions resolve to `contactId` for both contact slices. Then:

- **Rule 4** keeps a command key in the decision query when the slice reads it off a foreign
  event. `ContactAdded` is foreign to `MoveContact` (another slice produces it), so `customerId`
  stays, and the query is the composite `[contactId, customerId]` with the **new** customer.
- **Rule 2** makes `customerId` cross-partition for the whole boundary: it is read on a consumed
  arm, it is `AddCustomer`'s partition, and the command carries it as a scalar. Every writer of
  an event with `customerId` now bumps a fence for it.
- **The composite read misses events.** `ContactAdded` and earlier `ContactMoved` events carry
  the old customer, and the composite key is exact-match, so neither is found. `Dcb_Builder`
  reports half of it at boot ("composite read on tags [contactId, customerId] will silently miss
  'ContactMoved'"). The other half, the history under the old customer, it cannot see.

## 2. Why rule 1 already knew

Rule 1 gives back a key "whose every foreign arm comes from a slice partitioned by that same key,
since reading your own entity's events is identity, not a reference". Rules 2 and 4 were written
for the reference case (`AddProduct` reading `CategoryAdded`) and look only at who produced an
arm. They do not ask whether the arm is the slice's own entity.

They cannot ask the way rule 1 does. Rule 4 also runs at runtime per slice
(`StateChangeSlice_Callback`) and in the GWT harness, where no other slice is in sight. What every
caller has is the slice's own partition. An arm that carries it is read by it, so it is the
slice's own entity's history.

## 3. The change

`readByKeys(arms, ~partition)`: the keys a slice reads by on the arms it consumes. An arm that
carries the partition contributes only the keys the author declared on it (`@crossPartition`,
`@dcbTag`, …). Any other arm contributes all its keys. Without a partition, every key counts, as
before.

- **Rule 4** (`commandPayloadKeys`) takes its foreign keys from `readByKeys` over the foreign arms.
- **`crossPartitionForSlice`** (the per-slice harness) does the same.
- **Rule 2** (`infer`) takes its keys from `readByKeys` over all consumed arms, with the slice's
  own partition.

For the case: `MoveContact` reads by `contactId` alone, `customerId` is payload on its command, and
nothing in the boundary is cross-partition.

**Not changed:**

- **Rule 1** keeps `foreignConsumedKeys`. It runs before the partition is known, and has the
  give-back for the same reason.
- **Rule 3** (which keys an event is indexed by) is unchanged. `ContactMoved` still carries
  `customerId` as a tag. That costs an index write but changes no read, because the decision now
  reads by one key.
- **A reference read stays one.** A slice that checks the customer exists consumes
  `CustomerAdded{customerId}`, an arm without `contactId`, so `customerId` is still read by and
  still cross-partition.

## 4. Effect

- **Can a read get narrower?** No. Dropping a key from a decision query only widens what it
  reads within its own partition. Dropping a key from the cross-partition set removes a fence
  bump on that key's writers. That fence only protects reads by that key, and by this rule no
  slice reads by it.
- **This repository's examples are unchanged.** `pnpm run check:dcb-scope` passes against the
  goldens of `online-shop-dcb` and `online-shop-hybrid`, so no partition and no cross-partition
  key moved. A scan of every state-change slice there finds no consumed arm that carries the
  slice's partition beside another id the command carries. The examples follow the convention
  that an own-entity arm leaves its ids out (`OrderShipped`, `OrderPlaced({productIds,
  customerId})` without `orderId`).
- **Apps already deployed** with this shape get the right query on their next deploy. Their
  stored events keep the tags they were written with. A single-key read finds them.

## 5. Tests

In `reventless/spec/tests/DcbScopeInferenceTest.res`, "an arm of the slice's own entity, written
elsewhere":

1. The move's command keeps `customerId` as payload.
2. Nothing is cross-partition, per slice or in the boundary, and the partition is `contactId`.
3. A slice that also reads `CustomerAdded` still reads by `customerId`, across partitions.
4. A key declared on an own-entity arm is still read by.

The spec suite (1024 tests), core's DCB tests (188) and `check:dcb-scope` pass.
