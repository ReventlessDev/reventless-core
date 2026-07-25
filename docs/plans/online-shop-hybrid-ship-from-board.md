# Plan: Let `ShipOrder` participate in the Orders view (ship from the board)

## Status: DONE — manual branch chosen

Shipping is a manual operator action on the Orders board. `ShipOrder`'s consumed
`OrderPlaced` now carries a payload (`OrderPlaced({productIds})`) so it survives
the DCB payload-less filter, lands in `consumedEventTypes`, overlaps the Orders
projection, and `consistencyReadFor` links the slice to Orders — no UI change
needed. The command declares `@targetState(Orders.Shipped)`, so the board
resolves the Placed→Shipped drop via its `DeclaredTarget` tier (from #5) rather
than the name-stem guess. The behavior already read order state (rejects
cancelled / idempotent when shipped), so the `@allowedStates([Orders.Placed])`
guard is decision-model-backed. GWT tests updated to the payload form.

Remaining live check (deferred, like #1's CloudFront check): reseed demo data and
confirm the status spread is unchanged — manual shipping is purely additive
(the AutoShipOrder automation still ships Express/Standard as before).

**Date:** 2026-07-25

## Problem

The hybrid example's Orders board can cancel an order by dragging a card to
`Cancelled` (this runs `CancelOrder`), but it cannot ship one: dragging to
`Shipped` resolves to no command, and the column refuses the drop. The reason is
not a missing UI feature — it is that **`ShipOrder` consumes no events**, so the
platform never links it to the Orders view.

Live from `Platform_ComponentDefinitions` on the local platform:

```
CancelOrder | consistencyRead=Orders | consumes=["Ordering.OrderPlaced"]
PlaceOrder  | consistencyRead=Orders | consumes=["Ordering.OrderPlaced", ...]
ShipOrder   | consistencyRead=null   | consumes=[]        ← reads nothing
```

`consistencyReadFor`
([Plugin_Structure.res:345](../../reventless/core/src/plugin/component/Plugin_Structure.res#L345))
links a StateChangeSlice to a view by scoring the overlap between the events the
slice *consumes* and the events each view consumes. `ShipOrder` consumes nothing,
so it scores zero against every view and links to none. Any consumer that groups
commands by view — the AutoUI board included — therefore never sees `ShipOrder`
as an Orders command.

Note the deeper asymmetry: `ShipOrder` declares
`@allowedStates([Orders.Placed])`
([ShipOrder.res:14](../../examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/ShipOrder.res#L14))
and its `consumedEvent` type lists `OrderPlaced | OrderShipped | OrderCancelled`
([ShipOrder.res:6](../../examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/ShipOrder.res#L6)),
but its *behavior* reads none of them — so the declared "only in Placed" guard
is not backed by a decision-model read the way `CancelOrder`'s is (CancelOrder's
GWT rejects `OrderAlreadyShipped`). `ShipOrder` ships on `orderId` alone.

## Step 0 — the domain decision (do this first)

**Should a human be able to ship an order from the console?**

The `AutoShipOrder` automation already owns shipping: the order-lifecycle work
([done/online-shop-hybrid-order-lifecycle.md](done/online-shop-hybrid-order-lifecycle.md))
gates it on `shippingMethod` so `Express` ships on arrival and `Pickup` never
ships. If shipping is intended to be automation-only, the board being unable to
ship is **correct**, and the honest fix is the opposite of wiring it up:
`ShipOrder` should be `@noApi` (admin/automation only), like `ReopenOrder` — and
then the board's silence is intentional, not a gap.

If shipping *should* be a manual operator action too, proceed with the wiring
below.

Recommend confirming this against the example's intent before implementing
either direction; the plan supports both outcomes.

## Decision (if Step 0 says "manual shipping is allowed")

Make `ShipOrder` read order state, mirroring `CancelOrder`. This both:

- links it to the Orders view (its consumed `OrderPlaced` overlaps the Orders
  projection's consumed events, so `consistencyReadFor` resolves to `Orders`),
  which makes AutoUI's existing board resolver offer it — **no UI change**; B3's
  name-stem tier already maps `ShipOrder` → `Shipped` within `allowedStates`; and
- backs the `@allowedStates([Orders.Placed])` guard with a real decision-model
  read, so shipping an already-shipped/cancelled order is rejected at the
  handler, not just hidden by the UI.

## Steps

1. **Step 0 decision.** If automation-only: mark `ShipOrder` `@noApi`, add a note
   in the example README, and stop — the [autoui-noapi-command-exposure] UI plan
   then keeps it off the board honestly. If manual: continue.
2. Make `ShipOrder` consume `OrderPlaced` (at minimum) in its behavior/decision
   model, matching `CancelOrder`'s pattern
   ([CancelOrder.res](../../examples/online-shop-hybrid/ordering/src/Order/StateChangeSlice/CancelOrder.res)),
   so `consumedEventTypes` is non-empty and includes an event the Orders
   projection also consumes.
3. Add/adjust GWT tests so `ShipOrder` rejects a non-Placed order (mirroring
   `CancelOrder`'s `OrderAlreadyShipped` coverage) rather than shipping blindly.
4. Reseed demo data and re-check the status spread is unchanged (the automation
   still ships Express/Standard as before; manual shipping is additive).

## Acceptance

- **Automation-only branch:** `ShipOrder` is `@noApi`; it appears in neither the
  API nor the AutoUI board; the example README states shipping is automation-only.
- **Manual branch:** `Platform_ComponentDefinitions` reports
  `ShipOrder` with `consistencyRead=Orders`; dragging a Placed card to `Shipped`
  on the Orders board runs `ShipOrder` and the row becomes `Shipped`; shipping a
  non-Placed order is rejected by the handler; example command/GWT suites green.

## Notes

- Surfaced during AutoUI board verification; the AutoUI side needs no change in
  either branch — the board already resolves `ShipOrder`→`Shipped` the moment the
  command is linked to the view (manual branch), and already hides `@noApi`
  commands once [the apiExposed UI plan] lands (automation-only branch).
- This is example-domain modelling, not a framework change; `consistencyReadFor`
  is behaving correctly given `ShipOrder`'s current empty consumption.
