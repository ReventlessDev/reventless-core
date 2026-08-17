# Plan: a lifecycle has no way to say a state is an intentional ending

**Status.** BACKLOG 2026-08-16. Filed out of a lint that was written, run against
the shipped examples, and removed the same day. The lint was wrong; the gap it
ran into is real, and nothing else records it.

**The gap in one sentence.** `@retired` is the only thing a state can be marked
with, it means *withdrawn from ordinary reads*, and there is no way to say *rows
that reach this state stop here*.

---

## How it surfaced

The topology lint was specified with a rule reading "a state nothing can leave,
and not marked `@retired`, is suspicious". It failed twice over.

**It fires on correct models.** `Shipped` and `Refunded` are terminal in the
aggregates shop, as terminal states are in most lifecycles. Both were reported
the first time the rule ran, and there is nothing to fix about either.

**Its suggested remedy is harmful.** The only annotation a state can carry is
`@retired`, so the obvious way to silence the warning is to apply it — and that
would hide every shipped order from every caller who cannot widen their read.
The lint would be advising a data-visibility regression to quiet itself.

So the rule was removed rather than narrowed. A check cannot distinguish an
intentional ending from an accidental dead end when the vocabulary does not.

## What is actually conflated

Two independent facts, one annotation:

| Fact | Expressible today? |
|---|---|
| Rows in this state are withdrawn from ordinary reads | ✅ `@retired` |
| Rows that reach this state stop here, by design | ❌ |

They are orthogonal, and the shipped examples demonstrate it on one enum.
`Products` declares `Listed | @retired Archived | @retired Discontinued`, where
both retired states withdraw the row identically and only `Discontinued` is an
ending — `UnarchiveProduct` is the way back out of `Archived`. Meanwhile
`Shipped` in the aggregates shop is an ending that is *not* withdrawn: a shipped
order must stay readable.

All four combinations are reachable, and only two are sayable.

## Why this is not urgent

Nothing is broken today. The lifecycle diagram already *draws* terminals
correctly, because it derives them from the declared edges — a state no command
names as a from-state has no outgoing arrow, and that is the whole of it. The
missing vocabulary costs nothing until something needs to distinguish a terminal
the author meant from one they did not, and the dead-end lint is the only
consumer identified so far.

**Measured 2026-08-17, and the base rate argues for leaving this alone.** Every
lifecycle-bearing entity in the three shop examples:

| Entity | Lifecycle | Terminal |
|---|---|---|
| `hybrid` Orders | Placed → Shipped → Cancelled | `Shipped` |
| `hybrid` Products | Listed → Archived → Discontinued | `Discontinued` |
| `hybrid` Categories | Listed → Archived | none |
| `hybrid` Customers | Active → Deactivated | none |
| `aggregates` Orders | Placed → Shipped → Cancelled → Refunded | `Shipped`, `Refunded` |
| `dcb` Orders | Placed → Shipped → Cancelled | `Shipped`, `Cancelled` |

**Six terminal states across six entities, and every one is correct.** The
withdrawn rule would have reported five of them (all but `Discontinued`, which is
`@retired` for a reason of its own) — a hundred per cent false positives on the
shipped examples.

That inverts the case for the rule that *did* ship. An unreachable state is nearly
always a mistake, so reporting it is nearly always useful; a terminal state is
nearly always intentional, so reporting it is nearly always noise. Same shape of
check, opposite base rate — which is a better argument for the removal than "it
fired on two states", and a reason to be sceptical of any replacement that is not
driven by an actual accidental terminal turning up.

One more thing the table shows: `Cancelled` is terminal in the DCB shop and not in
the hybrid one, which declares a `ReopenOrder`. **Terminality is a property of the
model, not of the state's name** — so it can never be inferred, which is exactly
why a declaration would be needed if the check were ever wanted.

## What to decide, when it is picked up

1. **Whether a second marker is the answer at all.** An `@terminal` constructor
   attribute is the obvious shape and mirrors `@retired`'s placement, but it
   would be a mandatory-where-redundant annotation on most enums — the same
   objection that killed a proposed event annotation elsewhere. A per-state
   marker is only worth it if the checks it unlocks are worth it.
2. **Whether the check is the point.** If the only consumer is the dead-end lint,
   the cheaper answer is an *allow-list* on the lint rather than a vocabulary
   extension — the author silences a specific state once, in the plugin, without
   changing what the platform can say.
3. **What it means for the reachability rule that shipped.** Unreachable states
   are reported today using the first enum member as the initial state. That
   convention is unreviewed (nothing checks that a reordered enum still says what
   the author meant), and any work here should settle it in the same pass.

## Relates to

- `../lifecycle-transition-annotation.md` §5 — where the rule was built and
  withdrawn, with the run that reported `Shipped` and `Refunded`
- `../retired-marks-the-state-not-the-field.md` — the plan that put `@retired` on
  the constructor, and the reason its meaning is precise enough to be sure this
  is a different fact
- `lifecycle-consumed-events-payload-less.md` — the other vocabulary gap
  the same lint work turned up, independent of this one
