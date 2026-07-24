# Plan: Give the hybrid example an honest order lifecycle

## Status: Implemented — all acceptance criteria met

**Date:** 2026-07-24

Both defects are fixed. A seeded run now yields:

```
  status × shippingMethod:
                Standard   Express    Pickup
    Cancelled          3         0        10
    Placed            10         0        15
    Shipped           52        60         0
```

`Express` is never observed in `Placed` or `Cancelled` (the automation ships it
on arrival), `Pickup` is never `Shipped`, and `AutoShipOrderTodos` holds exactly
60 rows — the `Express` count — with no pending backlog. `CancelOrder` succeeds
against 13 orders, which it could not do at all before. Two reset-and-rerun
cycles produce byte-identical data across all seven data views. Example suites:
catalog 54, ordering 59, platform-local 3 — all green, zero build warnings.

**One deviation from step 3.** `todoItem` was *not* widened to carry
`shippingMethod`. Once `collect` admits only `Express`, the method is implied by
the row's existence, so carrying it would be dead payload in the TODO view.

**Still open, unrelated to this plan:** `SendOrderConfirmationTodos` remains
empty — that OutboundTranslationSlice does not run on the local platform at all
(no todo rows, no `EmailService` calls for any `OrderPlaced`). The seeder reports
it as a warning. Tracked in
[online-shop-hybrid-demo-data.md](online-shop-hybrid-demo-data.md).

The Ordering plugin in `examples/online-shop-hybrid` has an order lifecycle that
cannot be observed and a slice that cannot run. Both are invisible when reading
the source — the tests are green and the model looks complete — and both were
found only by driving the example end to end while implementing the demo-data
seeder.

1. `AutoShipOrder` ships **every** order, and the `ShipOrder` command lands
   before the `PlaceOrder` mutation returns. `Placed` and `Cancelled` are
   therefore unreachable states, and `CancelOrder` is dead code whose
   `@allowedStates([Orders.Placed])` guard can never be satisfied.
2. `RefundOrder` cannot be invoked by anything and its event is projected
   nowhere.

This plan fixes the first by giving the automation an actual decision to make,
and resolves the second by deleting it.

**Origin.** Both fall out of
[online-shop-hybrid-demo-data.md](online-shop-hybrid-demo-data.md), which
implemented the seeder and could not meet its "visible spread across all three
statuses" acceptance criterion. The `shippingMethod` field itself is proposed
independently, as a domain-honest field addition, in the Auto UI
demo-readiness analysis tracked outside this repo (its P2 package).

---

## Motivation

### The automation encodes no decision

Measured against a running local platform, seeding 150 orders:

- order status is already `Shipped` at 0ms after `PlaceOrder` returns;
- a `CancelOrder` issued immediately afterwards is rejected
  `OrderAlreadyShipped`;
- 21 cancellation attempts across the seeded dataset: 21 rejected, 0 applied;
- the resulting board is a single column, 150 `Shipped`.

There is no race window to exploit — `AutoShipOrder`'s phase 2 is detached but
drains within the mutation. "On `OrderPlaced`, issue `ShipOrder`" is a rule with
no branch in it, which raises a fair question about why the example models it as
an automation at all. An AutomationSlice is for a policy; this one is a
pass-through that happens to silence a command.

The cost is not only the demo. A reader of the example sees `CancelOrder` with a
state guard, four passing GWT cases, and a `Cancelled` status in the read
model — and none of it can ever execute.

### The refund slice is a demo vehicle that outlived its demo

`RefundOrder` was introduced by the `@noApi` commit
(`0c1974cf3`); the plan behind it
([command-noapi-annotation.md](done/command-noapi-annotation.md)) lists exactly
two additions to this example — `ReopenOrder` for the variant-level annotation
and `IssueRefund` for the type-level one. It has acquired no other role since:

- **unreachable** — `@noApi` keeps it off GraphQL/MCP/AutoUI, no AutomationSlice
  targets `IssueRefund`, and the Orders extension point's `mapIncomingCommand`
  returns `[]`;
- **invisible** — `RefundIssued` is consumed only by `RefundOrder`'s own
  decision model. No view projects it and `Orders.status` has no `Refunded`
  case.

`IssueRefund` and `RefundIssued` appear nowhere in either plugin outside
`RefundOrder`'s own three files and its GWT test.

Its stated rationale is also the weakest available. The file claims an
"automation/admin-only workflow triggered after cancellation", but no automation
exists — whereas Catalog's `RecordProductDemand` carries the same type-level
`@noApi`, fires on every order through the Orders extension point, and is off
the public API for a reason that actually holds: it is event-driven, so a client
has no business calling it. The docs teach the annotation with the one example
whose justification is fiction.

Making refunds meaningful instead of deleting them would require inventing a
payment concept — you cannot refund money that was never taken. That is a larger
domain expansion than this example should carry; the source analysis explicitly
warns that the example's teaching value degrades if it grows into a feature zoo.
If payment is ever added, `PayOrder` and refund return together as a coherent
pair, and re-adding ~40 lines plus a test is cheap.

## Decision

**Add `shippingMethod` to the order, and make the automation responsible for
exactly one of its values.**

| Method | Auto-ships? | Rationale |
|---|---|---|
| `Express` | yes, immediately | expedited dispatch is what the customer paid for — it bypasses the batch |
| `Standard` | no — waits for the batch run, an explicit `ShipOrder` | |
| `Pickup` | never ships | the customer collects it; shipping does not apply |

**Filter in `collect`, not in `process`.** If `process` returns `None` for
non-`Express` orders, their todo rows sit `Pending` forever and
`AutoShipOrderTodos` shows a permanent phantom backlog. Having `collect` decide
what the automation is responsible for keeps `process` total and the todo view
truthful.

**Delete `RefundOrder`** rather than reviving it, for the reasons above. Keep
`ReopenOrder`: it is dead the same way, but it is one variant of a live slice
and it carries the variant-level `@noApi` example at negligible cost.

Scope is the hybrid example only. `examples/online-shop-dcb` has its own
`AutoShipOrder` with the same tautology and its own tutorial page; the two
examples already differ deliberately, and widening this change would double the
doc churn for no additional teaching value.

## Steps

1. **Field.** Add `shippingMethod` to `PlaceOrder`'s command and `OrderPlaced`
   event, and thread it through `PlaceOrder_Behavior`. Follow the existing
   redeclaration convention — each slice declares the variant it needs, as
   `consumedEvent` declarations already redeclare event shapes — rather than
   sharing a cross-module type.
2. **View.** Add `shippingMethod` to `Orders`' `consumedEvent` and `state`, and
   set it in `Orders_Projection`. `Orders.status` already proves a variant in
   view state renders as a GraphQL enum, so no new mechanism is involved.
3. **Automation.** Widen `AutoShipOrder.todoItem` to carry `shippingMethod`, add
   it to the source event in `AutoShipOrder_Automation`, and have `collect`
   return an item only for `Express`. `process` stays total.
4. **Remove `RefundOrder`.** Delete the spec, behavior, `.model.json`, compiled
   `.res.mjs` outputs and the GWT test; regenerate the committed `Plugin.res`.
5. **Tests.** Update every GWT that constructs `PlaceOrder`/`OrderPlaced`, and
   add cases for the new branch: `Express` collects a todo, `Standard` and
   `Pickup` do not; a `Standard` order is still cancellable after placement.
6. **Docs.** `hybrid-based.md` (the automation section's "automatically ships
   every placed order", the slice table's `RefundOrder` row and its following
   paragraph, and the component list), `get-started.md` (the command table and
   the "strictly linear" lifecycle sentence), and `ai-generated.md`'s summary
   line. Repoint the type-level `@noApi` snippets in `reventless-ppx.md` and
   `dcb-usage.md` at `RecordDemand`.
7. **Seed.** Assign `shippingMethod` deterministically in `demo-data.mjs`, add a
   batch-dispatch phase issuing `ShipOrder` for a subset of `Standard` orders,
   and turn the currently-rejected cancellations into real ones drawn from the
   `Placed` pool. Delete the auto-ship warning and its `UNREACHABLE_VIEWS`-style
   carve-out once the spread is real.

## Acceptance

- A seeded run yields all three statuses on `Orders`, in deliberate proportions
  — target roughly `Shipped` 90+, `Placed` 40+, `Cancelled` 15 out of 150.
- `Express` orders are `Shipped` without an explicit `ShipOrder`; `Pickup`
  orders are never shipped by the automation.
- `AutoShipOrderTodos` contains rows only for `Express` orders, all `Completed`
  — no permanent `Pending` backlog.
- `CancelOrder` succeeds against a `Placed` order, which it cannot do today.
- The demo-data run no longer prints the auto-ship warning, and its
  status-spread acceptance criterion passes.
- No reference to `RefundOrder` survives outside `docs/plans/done/` and
  `docs/analysis/done/`.
- Zero compiler warnings; full example test suite green.

## Risks

- **The example is the tutorial spine.** Command and read-model changes are doc
  changes. Step 6 is not optional cleanup — an out-of-date tutorial is worse
  than the defect being fixed. Budget it as real work.
- **Deleting a slice touches generated output.** `Plugin.res` is generated but
  committed, and `.res.mjs` outputs under `src/` and `tests/` are tracked and
  load-bearing for CI. Regenerate and rebuild rather than hand-editing, and
  check `git ls-files --deleted` afterwards.
- **Enum ordering is user-visible.** Declared variant order drives board column
  order and pivot dimension order downstream. Declare `Standard | Express |
  Pickup` in the order the UI should show them.
- **A second unconditional automation would repeat the mistake.** If a refund or
  any other follow-up automation is added later, give it a real condition. An
  automation that fires on every instance of its trigger makes the state it
  consumes unobservable — which is exactly the defect this plan exists to fix.

## Out of scope

- Any payment concept, and with it a meaningful refund.
- `examples/online-shop-dcb`, whose `AutoShipOrder` has the same shape.
- Order date fields, which need
  [stateviewslice-projection-envelope.md](stateviewslice-projection-envelope.md)
  before a projection can see event time.
- The stale SDL block in `packages/doc/docs-app/graphql-api-guide.md`, which
  lists `Ordering_RefundOrder` even though `@noApi` means it can never appear,
  and whose return types (`String!` rather than `CommandResult!`) and
  slice-prefixed mutation names do not match the live schema either. Removing
  the one line is in scope via step 6; correcting the rest of the block is a
  separate docs-accuracy fix.
