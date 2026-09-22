// Boundary GWT for the Orders extension point: batch order events decompose
// into one public per-product event each (one-to-many fan-out).
@@reventless.gwt

open OrderingExamples

describe("Orders ExtensionPoint mapping — per-product fan-out", () => {
  // scenario-id: 1a9119c4-48fe-4f5f-b357-a3326dcd4ae9
  test("OrderPlaced fans out to one ItemOrdered per product", () =>
    whenDelegateEvent(
      Delegate.OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1, p2],
      }),
    )->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"})),
      ("p2", ExtensionPoint.ItemOrdered({productId: "p2", orderId: "o1", customerId: "c1"})),
    ])
  )

  // scenario-id: c8a2bb56-33d0-4f1d-a9f0-220e4e04f755
  test("OrderCancelled fans out to one ItemOrderCancelled per product", () =>
    whenDelegateEvent(
      Delegate.OrderCancelled({orderId: o1, productIds: [p1, p2]}),
    )->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "o1"})),
      ("p2", ExtensionPoint.ItemOrderCancelled({productId: "p2", orderId: "o1"})),
    ])
  )
})
