// Boundary GWT for the Orders extension point: batch order events decompose
// into one public per-product event each (one-to-many fan-out).
@@reventless.gwt

open Ordering_Examples

describe("Orders ExtensionPoint mapping — per-product fan-out", () => {
  // scenario-id: b3fe53fe-84bd-4bb7-aca3-a0f9db5a186f
  test("Placed fans out to one ItemOrdered per product", () =>
    whenDelegateEvent(
      Delegate.Placed({customerId: c1, productIds: [p1, p2]}),
    )->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrdered({productId: "p1", orderId: "gwt-id", customerId: "c1"})),
      ("p2", ExtensionPoint.ItemOrdered({productId: "p2", orderId: "gwt-id", customerId: "c1"})),
    ])
  )

  // scenario-id: c916b814-2006-4d62-9fff-60bb99ddcfd3
  test("Cancelled fans out to one ItemOrderCancelled per product", () =>
    whenDelegateEvent(Delegate.Cancelled({productIds: [p1, p2]}))->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "gwt-id"})),
      ("p2", ExtensionPoint.ItemOrderCancelled({productId: "p2", orderId: "gwt-id"})),
    ])
  )

  // scenario-id: 3647a0be-51ed-4d6d-83b3-9fa53a596e49
  test("Shipped publishes nothing", () => whenDelegateEvent(Delegate.Shipped)->thenPublishesNothing)

  // scenario-id: 0ac71311-60e6-4373-b078-96cfaf91724d
  test("Refunded publishes nothing", () =>
    whenDelegateEvent(Delegate.Refunded({reason: "customer-changed-mind"}))->thenPublishesNothing
  )
})
