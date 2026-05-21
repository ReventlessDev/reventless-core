// Boundary GWT for the Orders extension point: batch order events decompose
// into one public per-product event each (one-to-many fan-out).
@@reventless.gwt

describe("Orders ExtensionPoint mapping — per-product fan-out", () => {
  test("OrderPlaced fans out to one ItemOrdered per product", () =>
    whenInboundEvent(
      Delegate.OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1", "p2"]}),
    )->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"})),
      ("p2", ExtensionPoint.ItemOrdered({productId: "p2", orderId: "o1", customerId: "c1"})),
    ])
  )

  test("OrderCancelled fans out to one ItemOrderCancelled per product", () =>
    whenInboundEvent(
      Delegate.OrderCancelled({orderId: "o1", productIds: ["p1", "p2"]}),
    )->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "o1"})),
      ("p2", ExtensionPoint.ItemOrderCancelled({productId: "p2", orderId: "o1"})),
    ])
  )
})
