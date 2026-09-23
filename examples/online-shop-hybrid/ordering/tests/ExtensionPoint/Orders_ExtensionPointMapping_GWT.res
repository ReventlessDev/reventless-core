// Boundary GWT for the Orders extension point: batch order events decompose
// into one public per-product event each (one-to-many fan-out).
@@reventless.gwt

open Ordering_Examples

describe("Orders ExtensionPoint mapping — per-product fan-out", () => {
  // scenario-id: 2169642e-8457-4f24-b8b6-9956ddf74b73
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

  // scenario-id: 1b19274e-2c76-40d8-85a9-9f722a959532
  test("OrderCancelled fans out to one ItemOrderCancelled per product", () =>
    whenDelegateEvent(
      Delegate.OrderCancelled({orderId: o1, productIds: [p1, p2]}),
    )->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "o1"})),
      ("p2", ExtensionPoint.ItemOrderCancelled({productId: "p2", orderId: "o1"})),
    ])
  )
})
