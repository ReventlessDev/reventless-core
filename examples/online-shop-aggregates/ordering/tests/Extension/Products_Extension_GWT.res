// Boundary GWT for Ordering's Products extension: public Catalog events become
// CatalogProduct commands on Ordering's local shadow aggregate.
@@reventless.gwt

// `Mapping` is brought into scope by the PPX `open Products_Extension`; opening
// it surfaces the extension point's events and the delegate's commands.
open Mapping
open Ordering_Examples

describe("Products Extension delegate", () => {
  // scenario-id: 4c14eb06-02b8-41ae-b0b8-cf33ef430e93
  test("ProductBecameAvailable issues Sync", () =>
    whenIncomingEvent(
      ExtensionPoint.ProductBecameAvailable({productId: p1, name: "Book", price: 9.99}),
    )->thenPublishesAggregateCommand("p1", Delegate.Sync({name: "Book", price: 9.99}))
  )

  // scenario-id: d3760e9e-c4f6-4a2f-bb5a-8e57a965ba68
  test("ProductPriceChanged issues UpdatePrice", () =>
    whenIncomingEvent(
      ExtensionPoint.ProductPriceChanged({productId: p1, price: 7.5}),
    )->thenPublishesAggregateCommand("p1", Delegate.UpdatePrice({price: 7.5}))
  )
})
