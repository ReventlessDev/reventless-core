// Boundary GWT for Catalog's Orders extension: public Ordering events become
// RecordProductDemand commands on Catalog's StateChangeSlices.
@@reventless.gwt

open Catalog_Examples

// `Mapping` is brought into scope by the PPX `open Orders_Extension`; opening
// it surfaces the extension point's events and the delegate's commands.
open Mapping

describe("Orders Extension delegate", () => {
  // scenario-id: ab0858d5-6993-4861-a30b-8b620fa9d619
  test("ItemOrdered records demand for the product", () =>
    whenIncomingEvent(
      ExtensionPoint.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"}),
    )->thenPublishesCommand(Delegate.RecordDemand({productId: p1, orderId: "o1"}))
  )

  // scenario-id: d520fec4-ea2d-41e9-b764-e9cf0e0ef5d3
  test("ItemOrderCancelled revokes demand for the product", () =>
    whenIncomingEvent(
      ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "o1"}),
    )->thenPublishesCommand(Delegate.RevokeDemand({productId: p1, orderId: "o1"}))
  )
})
