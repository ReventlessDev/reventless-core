// Boundary GWT for Ordering's Products extension: public Catalog events become
// SyncCatalogProduct commands on Ordering's local shadow slice.
@@reventless.gwt

open Ordering_Examples

// `Mapping` is brought into scope by the PPX `open Products_Extension`; opening
// it surfaces the extension point's events and the delegate's commands.
open Mapping

// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.

describe("Products Extension delegate", () => {
  // scenario-id: 4f24d59b-1c98-4f9e-8266-ec3035e1c455
  test("ProductBecameAvailable issues SyncNewProduct", () =>
    whenIncomingEvent(
      ExtensionPoint.ProductBecameAvailable({
        productId: p1,
        name: "Book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
      }),
    )->thenPublishesCommand(
      Delegate.SyncNewProduct({
        productId: p1,
        name: "Book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
      }),
    )
  )

  // scenario-id: e990315a-ffe3-42a3-a394-94e103cbe4bb
  test("ProductPriceChanged issues ChangeSyncedPrice", () =>
    whenIncomingEvent(
      ExtensionPoint.ProductPriceChanged({
        productId: p1,
        price: Reventless.Money.make(~amount=750.0, ~currency=Reventless.Currency.EUR),
      }),
    )->thenPublishesCommand(
      Delegate.ChangeSyncedPrice({
        productId: p1,
        price: Reventless.Money.make(~amount=750.0, ~currency=Reventless.Currency.EUR),
      }),
    )
  )
})
