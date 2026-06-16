// Boundary GWT for the Orders extension point: batch order events decompose
// into one public per-product event each (one-to-many fan-out).
@@reventless.gwt

describe("Orders ExtensionPoint mapping — per-product fan-out", () => {
  test("Placed fans out to one ItemOrdered per product", () =>
    whenDelegateEvent(
      Delegate.Placed({customerId: "c1", productIds: ["p1", "p2"]}),
    )->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrdered({productId: "p1", orderId: "gwt-id", customerId: "c1"})),
      ("p2", ExtensionPoint.ItemOrdered({productId: "p2", orderId: "gwt-id", customerId: "c1"})),
    ])
  )

  test("Cancelled fans out to one ItemOrderCancelled per product", () =>
    whenDelegateEvent(
      Delegate.Cancelled({productIds: ["p1", "p2"]}),
    )->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "gwt-id"})),
      ("p2", ExtensionPoint.ItemOrderCancelled({productId: "p2", orderId: "gwt-id"})),
    ])
  )

  test("Shipped publishes nothing", () =>
    whenDelegateEvent(Delegate.Shipped)->thenPublishesNothing
  )

  test("Refunded publishes nothing", () =>
    whenDelegateEvent(
      Delegate.Refunded({reason: "customer-changed-mind"}),
    )->thenPublishesNothing
  )
})
