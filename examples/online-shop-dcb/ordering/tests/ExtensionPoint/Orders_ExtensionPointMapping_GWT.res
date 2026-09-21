// Boundary GWT for the Orders extension point: batch order events decompose
// into one public per-product event each (one-to-many fan-out).
@@reventless.gwt

let cid = CustomerId.make
let oid = OrderId.make
let pid = CatalogSpec.ProductId.make

describe("Orders ExtensionPoint mapping — per-product fan-out", () => {
  test("OrderPlaced fans out to one ItemOrdered per product", () =>
    whenDelegateEvent(
      Delegate.OrderPlaced({
        orderId: oid("o1"),
        customerId: cid("c1"),
        productIds: [pid("p1"), pid("p2")],
      }),
    )->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"})),
      ("p2", ExtensionPoint.ItemOrdered({productId: "p2", orderId: "o1", customerId: "c1"})),
    ])
  )

  test("OrderCancelled fans out to one ItemOrderCancelled per product", () =>
    whenDelegateEvent(
      Delegate.OrderCancelled({orderId: oid("o1"), productIds: [pid("p1"), pid("p2")]}),
    )->thenPublishesEvents([
      ("p1", ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "o1"})),
      ("p2", ExtensionPoint.ItemOrderCancelled({productId: "p2", orderId: "o1"})),
    ])
  )
})
