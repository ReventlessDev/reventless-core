# Plan: retirement becomes part of the owner index's sort key

**Date:** 2026-08-23<br/>
**Status:** Backlog — extracted from
[../owner-scoped-reads-on-an-index.md](../owner-scoped-reads-on-an-index.md) as
its Step 3, on the finding below: the work is correct and has **no beneficiary in
this repo today**. It is not blocked, it is unwanted until a view asks for it.<br/>
**Relates to:**
- [../owner-scoped-reads-on-an-index.md](../owner-scoped-reads-on-an-index.md) —
  the parent. Its Steps 1–2 shipped the derived `_owner` index and the list
  door's Query branch; this is the half that was left.
- [aws-fulllist-ordered-index-promotion.md](aws-fulllist-ordered-index-promotion.md)
  — the answer for a retired view with **no** owner, which is every retired view
  here. Different problem, bigger project; do not conflate them.

---

## Why this is in Backlog and not in flight

Retirement is only foldable into a key that already has a partition. This design
rides `@owner`'s, so it does something only for a view declaring **both**
markers.

Across the whole repo, on 2026-08-23, the two sets are **disjoint**:

| Marker | Specs declaring it |
|---|---|
| `@owner` | `Orders` (hybrid ordering) — declares no retirement |
| `@retired` | `Categories`, `Products`, `AvailableProducts`, `Customers` — none owned |

So building it would add a computed composite-key mechanism, an index
replacement and a mandatory projection replay, exercised by tests alone. It would
also silence **none** of the three retirement warnings the alpha deploy actually
emits (`Customers/accountStatus`, `Categories/shelfStatus`,
`Products/shelfStatus`) — all three are unowned, and have no partition to fold
into.

That is not an oversight in the design. A retirement flag is a two- or
three-valued attribute: a poor partition key on its own (one partition takes the
table), and useful only as the leading component of a sort key inside a partition
something else supplies. Where nothing supplies one, the list read is a
whole-table Scan and the answer is a reshaped view or
[aws-fulllist-ordered-index-promotion.md](aws-fulllist-ordered-index-promotion.md).

## When to pull this from Backlog

When a single view declares **`@owner` and `@retired` together** and its archive
is a material share of its rows. One view is enough — the mechanism is per-index,
so the first adopter pays for it and every later one is free.

Until then the deploy-time warning states the cost and prescribes nothing
(`QueryDbResolvers_AppSync.res`); it names this fold only for a view that is
already owner-scoped, and says plainly that an `@index` would not help otherwise.

---

## The design

Make the derived index's sort key a composite `<liveFlag>#<sortField>#<id>`, so
"live rows of owner X, ordered by f" becomes
`#pk = :owner AND begins_with(#sk, '0#')` — still a key condition, still an exact
page. The elevated `includeRetired: true` path drops the `begins_with` and reads
the whole partition.

`QueryDb_Operations.injectCompositeIndexAttrs` already writes synthetic composite
attributes from `skFields`, so the mechanism exists — but it concatenates *raw
string fields*, and the live flag is a derived value (a boolean field inverted, or
a state name tested against the retiring set). That is the new part: a **computed**
component in a composite key, not a copied one. It needs the retirement rule at
write time, which `Reventless.StateAnnotations.getSpec(...).retired` supplies from
the same schema the resolvers read it from.

The sparse-index alternative — write a `_live` attribute only on non-retired rows
and let the GSI omit the rest — is cheaper and cannot serve `includeRetired` at
all, so it would need the Scan back as its archive path. Prefer the composite.

### What the parent plan's Steps 1–2 already settled

- `ALL` projection, and why a narrow one is wrong (a GSI filter may only name
  projected attributes).
- The one-character cursor path tag (`s` Scan / `q` Query). A third read shape
  does not need a third tag — the fold changes the key condition, not the branch.
- The `derived: true` flag that keeps the index off the SDL, and the four
  emitters that honour it.

### Consequences to plan for

- **The index is replaced, not altered.** Changing a GSI's key schema means
  delete + create, so it pays the control-plane latency again — measured at 522s
  on a 151-row table when the parent plan first created it.
- **This one genuinely needs a backfill**, unlike the parent's. The composite sort
  key is a synthetic attribute written at projection time, so no existing row
  carries it and DynamoDB has nothing to copy into the new index. Replay the
  projection *before* the read that depends on it goes live. (The parent plan's
  *Backfill and migration* section states the rule the two cases share.)
- **Do it after the parent's Step 2 is verified**, not with it: it changes the key
  schema of an index that by then holds data, and the two failures would be
  indistinguishable.

---

## Files

- `packages/reventless-ppx/src/ppx/StateAnnotations.ml` — the derived index gains
  `skFields` / `skSep` / a live-flag marker when the record also declares
  `@retired`.
- `reventless/spec/src/components/ReadModel.res` — the marker on `indexConfig`.
- `reventless/core/src/components/QueryDb/QueryDb_Operations.res` —
  `injectCompositeIndexAttrs` learns a computed component.
- `rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res` —
  `begins_with` on the key condition, and the retirement predicate dropped from
  the Query branch's filter (it stays on the Scan branch, which has no key).
- `reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` — thread the
  composite key name; rewrite the owned-view half of the retirement warning once
  this is real.
