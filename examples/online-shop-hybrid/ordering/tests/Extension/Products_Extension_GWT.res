// Boundary GWT for Ordering's Products extension: public Catalog events become
// SyncCatalogProduct commands on Ordering's local shadow slice.
@@reventless.gwt

// `Mapping` is brought into scope by the PPX `open Products_Extension`; opening
// it surfaces the extension point's events and the delegate's commands.
open Mapping

// Prices are money, so a test writes the amount a person would say and pairs it
// with a currency. `make` rounds to the decimals EUR has and scales nothing:
// 9.99 EUR is 9.99, and the same call on a JPY price would round to a whole yen.
let eur = amount => Reventless.Money.make(~amount, ~currency=EUR)

describe("Products Extension delegate", () => {
  test("ProductBecameAvailable issues SyncNewProduct", () =>
    whenIncomingEvent(
      ExtensionPoint.ProductBecameAvailable({productId: "p1", name: "Book", price: eur(9.99)}),
    )->thenPublishesCommand(
      Delegate.SyncNewProduct({productId: "p1", name: "Book", price: eur(9.99)}),
    )
  )

  test("ProductPriceChanged issues ChangeSyncedPrice", () =>
    whenIncomingEvent(
      ExtensionPoint.ProductPriceChanged({productId: "p1", price: eur(7.5)}),
    )->thenPublishesCommand(Delegate.ChangeSyncedPrice({productId: "p1", price: eur(7.5)}))
  )
})
