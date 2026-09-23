// Boundary GWT for Ordering's Products extension: public Catalog events become
// SyncCatalogProduct commands on Ordering's local shadow slice.
@@reventless.gwt

open Ordering_Examples

// `Mapping` is brought into scope by the PPX `open Products_Extension`; opening
// it surfaces the extension point's events and the delegate's commands.
open Mapping

describe("Products Extension delegate", () => {
  // scenario-id: a4680fe3-1546-4669-9334-d8971e2b7162
  test("ProductBecameAvailable issues SyncNewProduct", () =>
    whenIncomingEvent(
      ExtensionPoint.ProductBecameAvailable({productId: p1, name: "Book", price: 9.99}),
    )->thenPublishesCommand(Delegate.SyncNewProduct({productId: p1, name: "Book", price: 9.99}))
  )

  // scenario-id: b8178540-b81e-4d82-9b93-9f2f68b968c6
  test("ProductPriceChanged issues ChangeSyncedPrice", () =>
    whenIncomingEvent(
      ExtensionPoint.ProductPriceChanged({productId: p1, price: 7.5}),
    )->thenPublishesCommand(Delegate.ChangeSyncedPrice({productId: p1, price: 7.5}))
  )
})
