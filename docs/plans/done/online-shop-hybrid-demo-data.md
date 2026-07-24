# Plan: Demo data for the online-shop-hybrid example

## Status: Done — all 5 acceptance criteria met; the 5th was unblocked once its framework defect landed (verified 2026-07-24)

**Date:** 2026-07-24

The seeder ships as ReScript under `platform-local/src/` — `DemoData.res` (the
dataset), `DemoCommands.res` (the command→mutation adapter) and `DemoSeed.res`
(the run) — on top of the reusable `@reventlessdev/reventless-seed` package. Wired as
`pnpm run demo-data` and documented in the example README. A full run against a
fresh store takes ~2.3s and seeds 8 categories, 64 products (60 authored + 4
supplier-fed), 20 customers, 150 orders and 5 import-audit rows.

**Met.** `ProductDemand` has a real head and tail (56 / 31 / 16 for the top
three, 44 of 64 products ordered, tail of 1); the `Orders` board shows all three
statuses; byte-identical data across two reset-and-rerun cycles, verified by
diffing a full dump of all seven data views; a deliberately broken mutation name
aborts with the offending mutation and the GraphQL response.

**Met.** Non-empty grids on all 9 queryable views — the script fails the run if a
view it is supposed to fill is empty. The 9th (`SendOrderConfirmationTodos`) was
unfillable at the time of writing; it now fills once its framework defect landed
(see below).

**Status spread — resolved by a follow-up plan.** The `AutoShipOrder` automation
originally issued `ShipOrder` *before the `PlaceOrder` mutation returned*
(measured: `Shipped` at 0ms, an immediate `CancelOrder` rejected
`OrderAlreadyShipped`), making `Placed` and `Cancelled` unreachable and
`CancelOrder` dead code. That is fixed in
[online-shop-hybrid-order-lifecycle.md](online-shop-hybrid-order-lifecycle.md),
which gates the automation on a new `shippingMethod` field. The seeder now
produces `Shipped` 106 / `Placed` 29 / `Cancelled` 15 out of 150, and this
acceptance criterion passes.

**Was blocked, now resolved.** At the time of writing,
`SendOrderConfirmationTodos` stayed empty: the `SendOrderConfirmation`
OutboundTranslationSlice did not run on the local platform at all — zero todo
rows and zero `EmailService` calls across 150 `OrderPlaced` events, while the
`AutoShipOrder` automation consuming the same events produced 150 rows. Root
cause: the slice split the raw `{id, meta, event}` topic envelope instead of the
inner `event`, so `splitMessage` returned `"Unknown"` and every event was
dropped on the silent `None` arm. Fixed in
[outbound-translation-slice-not-running-local.md](outbound-translation-slice-not-running-local.md)
(commit `66008a4df`). Re-run 2026-07-24 on a fresh in-memory store: the view
fills 150 rows, the run is 9-of-9 with no warning block. The seeder had already
been switched from `Unfillable` to `Seeded` for this view in anticipation.

**Also found, now resolved.** Every `Catalog_ImportProduct` call returned a
GraphQL error — `Abstract type "CommandResult" must resolve to an Object type` —
even though the import succeeded and the audit row recorded `Success`. The
resolver returned the target-id array while `deriveMutationFieldFromObject` typed
the SDL field as `CommandResult!`; every InboundTranslationSlice mutation was
affected. Fixed in
[inbound-translation-mutation-result-type.md](inbound-translation-mutation-result-type.md)
(commit `381b5458c`), which widens `receive` to carry a real `CommandResult`
shape. The seeder's carve-out for that exact error is gone; the same 2026-07-24
re-run imports cleanly (4 imported, 1 rejected) through the normal path.

**Not attempted.** "Orders spread across a date range" (step 2) is not
representable: `Orders` has no time field, and the projection cannot see
`recordedAt` or `meta` until
[stateviewslice-projection-envelope.md](../stateviewslice-projection-envelope.md)
(B4) lands. Date spread should be revisited as part of that plan, not this one.

`examples/online-shop-hybrid/platform-local` has serve/dev scripts only — no
seed. Every view is an empty grid until someone clicks through the command
forms one entity at a time. This plan adds a `demo-data` script that drives the
example's own command API to a coherent, reproducible dataset.

**Origin.** Blocker **B5** of an Auto UI demo-readiness analysis tracked outside
this repo. It is the cheapest of the five blockers and it gates visual
verification of all the others: B1–B3 are UI-side and tracked there, B4 is
[stateviewslice-projection-envelope.md](../stateviewslice-projection-envelope.md).

**Execution order: step 1 of 6** (B5 → B4 → B1 → B6 → B3 → B2; the full table
with rationale is kept alongside the UI-side blocker list).
This one goes first because it has no dependencies and every later
verification needs rows — with an empty store, "the component is broken" and
"there is no data" look identical. B4 follows immediately, in this same repo.

---

## Motivation

The hybrid example ships no UI package: Auto UI served by the generic host
shell is the whole front end. That makes it the natural place to demonstrate
the AutoUI component catalog — and a board with two cards, a leaderboard with
three rows, or a dashboard reading zero everywhere demonstrates nothing. It is
also a reviewer's first contact with the framework via
`packages/doc/docs-tutorials/get-started.md`, which the example README points
at.

Data volume is not the only requirement. The *shape* has to be deliberate: a
status distribution that reads well on a Kanban board, demand counts with a
plausible head and tail, orders spread over a date range rather than clustered
in one second.

## Decision

A seeder under `examples/online-shop-hybrid/platform-local/src/` issuing the
example's **own GraphQL mutations** against the running local platform.

(Originally specified as a plain Node script and first implemented that way;
subsequently rewritten in ReScript on the generic
`@reventlessdev/reventless-seed` harness. That split the domain-agnostic
plumbing out of the example and moved command construction onto real plugin
command values, so a changed signature is now a compile error rather than a
runtime rejection.)

Not a direct write into the store. Driving the public command API means:

- the data stays honest as the domain evolves — a renamed command breaks the
  script loudly instead of producing states the domain can no longer reach;
- projections, the DCB append path and the automation flow (`AutoShipOrder`)
  are all exercised, so seeding doubles as a smoke test;
- no new privileged surface has to exist for seeding.

Endpoint from an env var with the dev-port default; no server-side changes.

## Steps

1. **Deterministic generation.** A fixed seed for the pseudo-random choices and
   a fixed base date with relative offsets — no `Date.now()`, no unseeded
   randomness. Two runs against a fresh store produce byte-identical data, so
   screenshots and any future visual regression are reproducible.
2. **Volume and shape**, per the source analysis:
   - ~8 categories
   - ~60 products across those categories, prices spread across a realistic
     range (the `price` field drives the `currency` semantic and dashboard sums)
   - ~20 customers
   - ~150 orders spread across a date range, with a **status mix that reads on
     a board** — a real spread of Placed / Shipped / Cancelled, not 95% Placed
   - demand counts that make `ProductDemand` a plausible top-N leaderboard
     (a clear head, a long tail), not a flat line
3. **Wire it up.** `"demo-data": "node src/DemoSeed.res.mjs"` in
   `platform-local/package.json`; document the `serve:reset` → `demo-data`
   pairing in the example README. No idempotence logic in the script — reset is
   already a first-class script (`serve:reset` passes `?reset` to the sqlite
   backend).
4. **Fail loudly and early.** A GraphQL error aborts the run and prints the
   offending mutation and response. Half-seeded data is worse than none,
   because it looks like a working dataset.
5. **Progress output.** One line per phase with counts, so a slow run against a
   cold platform doesn't look hung.

## Acceptance

- `pnpm run serve:reset`, then `pnpm run demo-data`, yields non-empty grids on
  every queryable view.
- The `Orders` board shows a visible spread across all three statuses.
- `ProductDemand` sorted by `orderCount` has a meaningful head and tail.
- A second reset + run produces identical data.
- A deliberately broken mutation name aborts with a readable error rather than
  a partial seed.

## Risks

- **The script is domain-coupled by design.** Command signature changes break
  it. That is the intended trade (see Decision) but it means the script needs
  to be in the same review scope as command changes — worth a line in the
  example README.
- **Volume vs. runtime.** ~240 commands through the full append + projection
  path on the local platform; if that turns out slow enough to annoy, batch
  concurrency is the lever, not a store-level shortcut.
- **Scope creep into a data zoo.** The counts above exist to make the shipped
  components legible, not to demo every future component. Field *additions* to
  the example (image urls, shipping methods, coordinates) are a separate
  question — §5 P2 of the source analysis — and are deliberately not in this
  plan.
