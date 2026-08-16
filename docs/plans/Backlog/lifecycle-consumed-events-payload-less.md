# Plan: the consumed-event set drops payload-less variants

**Status.** BACKLOG 2026-08-16. Filed out of a lint that could not be written.
The metadata gap is verified, asserted by our own tests as intended behaviour,
and has at least one consequence beyond the lint that motivated this file.

**The gap in one sentence.** `consumedEventTypes` lists only the consumed events
that carry a payload, and a lifecycle-moving event is usually payload-less in the
slice that folds it — so the published set is empty or near-empty for exactly the
slices whose folds matter most.

---

## Verified

`PluginStructureTest.res` asserts the exclusion directly, in two places:

- `"PlaceOrder: consumedEventTypes contains CatalogProductSynced qualified
  (payload-less variants excluded)"`
- `"ShipOrder: consumedEventTypes is empty (all consumed events are payload-less
  literals)"`

Measured on the shipped hybrid shop: both order slices publish
`["Ordering.OrderPlaced"]` and nothing else, while each folds four events.

So this is not a bug that slipped in. It is a documented behaviour whose cost was
not weighed against the consumers that have since appeared.

## What it blocks

**The check it was found by.** A warning when a slice folds a lifecycle-moving
event that its sibling slices and the linked view ignore — the generalisation of
a real bug in the hybrid shop, where a reopened order could never be shipped and
rendered `Cancelled` forever. The rule needs one narrowing to avoid firing on
ordinary DCB (where a slice folds events about *other* entities because its own
decision needs them), and that narrowing is available. What is not available is
the input: knowing which events a slice folds at all. Verified end to end — with
the narrowing in place and the original drift deliberately reintroduced into the
live example, the check stayed silent.

**And something larger, which should be confirmed before this is scheduled.** The
test suite also asserts:

> `"ShipOrder: consistencyRead is None (empty consumedEventTypes cannot overlap
> any SVS)"`

If a slice's consistency read is derived by intersecting its consumed events with
state-view slices, then a slice consuming only payload-less events gets no
consistency read *as a consequence of the metadata being lossy*, not as a
decision anyone made about that slice. Whether that is harmless or not is the
first thing to establish here — it is a correctness question, and it outranks the
lint that prompted this file.

## Why the walk drops them

Not investigated in depth, and that is the first task. The shape of the
exclusion — payload-carrying variants survive, bare constructors do not —
suggests the walk derives the type name from the payload record rather than from
the constructor, which would make the omission a mechanical consequence rather
than an intended filter. The test titles say "excluded", which reads as
deliberate; the two need reconciling before anything is changed.

## What to decide

1. **Is the `consistencyRead` consequence real and is it harmful?** Establish
   this before anything else. If a slice is silently losing its consistency read,
   this stops being a lint enabler and becomes a correctness fix.
2. **Publish payload-less variants, or publish a second set?** Adding them to
   `consumedEventTypes` changes the meaning of a field several consumers already
   read — including whatever computes consistency reads and the DCB tag walks. A
   sibling field (`foldedEventTypes`, all of them, no payload requirement) is
   duller and does not move anything already load-bearing.
3. **What it costs on the wire.** These sets ship in plugin metadata that has a
   size ceiling elsewhere in the system; a set that roughly quadruples for
   lifecycle slices is worth sizing before it is shipped.

## Relates to

- `../lifecycle-transition-annotation.md` §5 — where the lint was specified, and
  the record of it being unwritable
- `lifecycle-terminal-state-vocabulary.md` — the other gap the same lint
  work turned up; independent of this one

Worth keeping in view when weighing the priority: this class of bug is also
catchable by *running* a slice's folds rather than inspecting its published
metadata, and that route needs nothing from this file. The lint is a second line
of defence, not the only one.
