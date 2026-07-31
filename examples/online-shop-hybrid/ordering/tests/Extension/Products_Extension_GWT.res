// Boundary GWT for Ordering's Products extension: public Catalog events become
// SyncCatalogProduct commands on Ordering's local shadow slice.
@@reventless.gwt

// `Mapping` is brought into scope by the PPX `open Products_Extension`; opening
// it surfaces the extension point's events and the delegate's commands.
open Mapping

// Prices are money now, so a test writes the amount a person would say and
// converts it once. `ofMajor` scales by the currency's own exponent, which is
// what keeps the literal honest: 9.99 EUR is 999 cents, and the same call on a
// JPY price would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

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
