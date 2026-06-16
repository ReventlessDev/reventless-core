// Boundary GWT for Catalog's Orders extension: public Ordering events become
// ProductDemand commands on Catalog's aggregate.
@@reventless.gwt

// `Mapping` is brought into scope by the PPX `open Orders_Extension`; opening
// it surfaces the extension point's events and the delegate's commands.
open Mapping

describe("Orders Extension delegate", () => {
  test("ItemOrdered records demand for the product", () =>
    whenIncomingEvent(
      ExtensionPoint.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"}),
    )->thenPublishesAggregateCommand("p1", Delegate.Record({orderId: "o1"}))
  )

  test("ItemOrderCancelled revokes demand for the product", () =>
    whenIncomingEvent(
      ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "o1"}),
    )->thenPublishesAggregateCommand("p1", Delegate.Revoke({orderId: "o1"}))
  )
})
