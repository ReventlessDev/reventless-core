// Boundary GWT for Ordering's Products extension: public Catalog events become
// SyncCatalogProduct commands on Ordering's local shadow slice.
@@reventless.gwt

// `Mapping` is brought into scope by the PPX `open Products_Extension`; opening
// it surfaces the extension point's events and the delegate's commands.
open Mapping

describe("Products Extension delegate", () => {
  test("ProductBecameAvailable issues SyncNewProduct", () =>
    whenIncomingEvent(
      ExtensionPoint.ProductBecameAvailable({productId: "p1", name: "Book", price: 9.99}),
    )->thenPublishesCommand(
      Delegate.SyncNewProduct({productId: "p1", name: "Book", price: 9.99}),
    )
  )

  test("ProductPriceChanged issues ChangeSyncedPrice", () =>
    whenIncomingEvent(
      ExtensionPoint.ProductPriceChanged({productId: "p1", price: 7.5}),
    )->thenPublishesCommand(Delegate.ChangeSyncedPrice({productId: "p1", price: 7.5}))
  )
})
