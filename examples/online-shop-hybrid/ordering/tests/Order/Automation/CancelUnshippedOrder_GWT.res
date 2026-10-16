// The deadline: an order placed on day 0 and not shipped is cancelled by the sweep
// that runs on day 3; one shipped in time is not.

@@reventless.gwt

module Ordering = Mapping(FromOrderingDcb)

open OrderingDcbSource
open Ordering_Examples

let day = 24. *. 60. *. 60. *. 1000.
let day0 = Date.fromString("2026-10-16T09:00:00Z")->Date.getTime

describe("CancelUnshippedOrder AutomationSlice", () => {
  // scenario-id: aefaf4e4-de34-420f-a65b-692017355cab
  test("a Standard order not shipped after three days is cancelled", () =>
    givenEvents([Ordering.event(OrderPlaced({orderId: o1, shippingMethod: Standard}))])
    ->atTime(day0)
    ->whenSweep(~now=day0 +. 3. *. day)
    ->thenCommands([(orderRef, CancelOrder({orderId: o1}))])
  )

  // scenario-id: 35d1d2ab-bbcc-4fe6-a914-3e34ffc277b9
  test("before the three days are up, nothing is sent", () =>
    givenEvents([Ordering.event(OrderPlaced({orderId: o1, shippingMethod: Standard}))])
    ->atTime(day0)
    ->whenSweep(~now=day0 +. 2. *. day)
    ->thenCommands([])
  )

  // scenario-id: c67840ed-9093-4904-9a39-99e529ba97fa
  test("an order shipped in time is not cancelled", () =>
    givenEvents([
      Ordering.event(OrderPlaced({orderId: o1, shippingMethod: Standard})),
      Ordering.event(OrderShipped({orderId: o1}), ~recordedAt=day0 +. 2. *. day),
    ])
    ->atTime(day0)
    ->whenSweep(~now=day0 +. 3. *. day)
    ->thenCommands([])
  )

  // scenario-id: b750c6eb-4020-43b7-b989-9e40ac292b4f
  test("an Express order is not this deadline's", () =>
    givenEvents([Ordering.event(OrderPlaced({orderId: o1, shippingMethod: Express}))])
    ->atTime(day0)
    ->whenSweep(~now=day0 +. 3. *. day)
    ->thenScenarioTodos([])
  )
})
