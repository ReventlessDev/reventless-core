# Plan: the consumed-event set drops payload-less variants

**Status.** BACKLOG 2026-08-16, **investigated and measured 2026-08-17** — the
cause is located, the blast radius is computed, and what is left is one judgement
rather than any further work. Filed out of a lint that could not be written. The
metadata gap is verified, asserted by our own tests as intended behaviour, and
has three consequences beyond the lint that motivated this file.

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

~~Not investigated in depth, and that is the first task.~~ **Investigated
2026-08-17, and it is an intended filter in the wrong place rather than a
mechanical omission.** `Plugin_Structure.make` keeps two walks:

```rescript
// Event schemas: filter out payload-less variants — DCB event-type lookups
// can't WHERE-clause on bare-string events, so the plugin graph mustn't
// claim cross-component edges that the runtime can't honour.
let eventVariantNames = schema => Reventless.DcbTag.extractVariantNames(schema)
// Command schemas: keep every constructor (including payload-less) so the
// GraphQL mutation surface stays addressable.
let commandVariantNames = schema => Reventless.DcbTag.extractAllVariantNames(schema)
```

`eventVariantNames` is applied at four sites: `scsProduced`, `aggProduced`,
`scsConsumed` and `svsConsumed`. **Only the first two are what its comment is
about.** A *produced* payload-less event cannot be found by a DCB tag lookup, so
publishing it would claim an edge the runtime cannot honour — correct, and worth
keeping. A *consumed* payload-less variant claims nothing of the kind: it states
what a fold understands, and nothing is asked to look it up. The two share a walk
because they share a shape, not because they share a reason.

So the test titles and the mechanism reconcile: the exclusion is deliberate, and
its justification simply does not extend to two of the four places it is applied.

## What the answers turned out to be

Measured across both hybrid plugins, 2026-08-17, by comparing each spec's
authored `consumedEvent` variants against what the structure publishes.

**1. Is the `consistencyRead` consequence real?** Yes, and it is the *whole*
blast radius. Every link between components is an intersection with a **produced**
set, and produced keeps filtering — so nothing that links components can move.
More precisely, `linkedSvsFor` and `linkedWriteSideFor` both key off a *view's*
consumed set, and **no view hides anything**, structurally rather than by luck: a
projection needs the row key to know what to update, so `CategoryArchived({categoryId})`
is the only shape a view can use. `svsConsumed` is therefore already complete.

What is left is `consistencyRead` on **6 of the 18 example slices** — `AddCategory`,
`ArchiveCategory`, `UnarchiveCategory`, `ArchiveProduct`, `UnarchiveProduct`,
`DiscontinueProduct`. Every change is `None → Some`, never one view for another,
and every one names the entity's own view. These are exactly the slices whose
consumed set is *entirely* payload-less today.

Harmful? Not in these examples. `consistencyRead` is descriptive metadata here —
it reaches the published component definitions and the MCP tool description
("Reads: X for consistency"). Its one behavioural consumer is the UI layer, which
uses it to place a slice's per-row commands and falls back to `linkedViews` when
it is absent. For all six slices both routes reach the same view, so the
destination is unchanged and only the mechanism differs. Worth knowing that the
fallback exists *because* of this gap.

**2. Publish payload-less variants, or a second set?** The measurement weakens the
case for a sibling field. The worry was that adding them changes the meaning of a
field several consumers read — but the consumers that matter read the *produced*
side or a *view's* consumed side, and neither moves. Splitting the walk at the two
consumed sites is a smaller change than introducing a parallel field that
everything then has to learn about, and it leaves one concept with one name.

**3. What it costs on the wire.** **44 entries across the two hybrid plugins** — 8
in `ordering`, 36 in `catalog` — and every one of them is produced by some
writable in its own plugin, so none is a dangling name. Sizeable relative to
today's near-empty sets, small in absolute terms.

## What is left to decide

Only the judgement, now that the investigation is done: **is `None → Some` on
published `consistencyRead` wanted?** It is more accurate — a slice that folds
`ProductArchived` really does depend on the `Products` view's vocabulary — but it
is a change to published metadata for the population that has never carried one.

A second, smaller one: **should `svsConsumed` unfilter too?** It changes nothing
measurable today. The case for doing it anyway is that leaving one consumed site
filtered preserves the conflation this file is about, and the next view that folds
a bare fact reintroduces the bug silently.

## The evidence that the folds are not what is wrong

From `ShipOrder_Behavior.res` in the hybrid ordering example:

> `productIds` is carried only to keep `OrderPlaced` out of the payload-less
> filter (so the slice links to `Orders`); `ShipOrder`'s decision doesn't use it.

A domain model bent to satisfy a metadata walk. Whatever else is decided here,
that field should stop being necessary.

## A fourth cost, found since

Beyond the lint and the `consistencyRead` consequence: anything that *runs* a
compiled fold has to decide which spelling of an event the fold understood, and
the payload-carrying fallthrough arm is covered exactly — a published consumed
event is one that carries a payload — while the payload-less one has no cover.

Whether it can be inferred instead comes down to arity, which is not a property
anyone chose. A fold's `switch` is exhaustive over its own event type, so the
compiler discriminates only as far as it must: with three payload-less arms it
emits three `case` labels and every one is attributable, with two it emits
`if (event === "X") … else …` and the second answers for anything. Measured on the
shipped catalog, `RenameCategory`'s `CategoryUnarchived` arm cannot be attributed
and a declared route through it cannot be verified; `ShipOrder` escapes only
because it happens to have three.

## Relates to

- `../lifecycle-transition-annotation.md` §5 — where the lint was specified, and
  the record of it being unwritable
- `lifecycle-terminal-state-vocabulary.md` — the other gap the same lint
  work turned up; independent of this one

Worth keeping in view when weighing the priority: this class of bug is also
catchable by *running* a slice's folds rather than inspecting its published
metadata, and that route needs nothing from this file. The lint is a second line
of defence, not the only one.
