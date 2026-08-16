// Boundary GWT for the Products extension point: internal Catalog events
// become the stable public events Ordering subscribes to.
@@reventless.gwt

// Published events and handled directives are disjoint channels on the same
// mapping run — each `test` projects to one channel and asserts on it.
// Prices are money now, so a test writes the amount a person would say and
// converts it once. `ofMajor` scales by the currency's own exponent, which is
// what keeps the literal honest: 9.99 EUR is 999 cents, and the same call on a
// JPY price would scale by 1.
let eur = amount => Reventless.Money.ofMajor(~amount, ~currency=EUR)

describe("Products ExtensionPoint mapping", () => {
  test("ProductAdded publishes ProductBecameAvailable", () =>
    whenDelegateEvent(
      Delegate.ProductAdded({productId: "p1", name: "Book", description: "A good book", price: eur(9.99)}),
    )->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductBecameAvailable({productId: "p1", name: "Book", price: eur(9.99)}),
    )
  )

  test("ProductAdded raises no directive", () =>
    whenDelegateEvent(
      Delegate.ProductAdded({productId: "p1", name: "Book", description: "A good book", price: eur(9.99)}),
    )->thenHandlesNoDirective
  )

  test("ProductPriceChanged is forwarded to the extension point", () =>
    whenDelegateEvent(Delegate.ProductPriceChanged({productId: "p1", price: eur(7.5)}))->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductPriceChanged({productId: "p1", price: eur(7.5)}),
    )
  )

  test("ProductPriceChanged also fires a pricing-update directive", () =>
    whenDelegateEvent(
      Delegate.ProductPriceChanged({productId: "p1", price: eur(7.5)}),
    )->thenHandlesDirective(
      ExtensionPoint.EmitPricingUpdate({productId: "p1", price: eur(7.5)}),
    )
  )

  // Both of Catalog's retirements collapse to the one fact Ordering needs. This
  // is the assertion that keeps the boundary a capability rather than a mirror
  // of the catalog's lifecycle: adding a third way off the shelf must not add a
  // third published event.
  test("ProductArchived publishes ProductWithdrawn", () =>
    whenDelegateEvent(Delegate.ProductArchived({productId: "p1"}))->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductWithdrawn({productId: "p1"}),
    )
  )

  test("ProductDiscontinued publishes the same ProductWithdrawn", () =>
    whenDelegateEvent(Delegate.ProductDiscontinued({productId: "p1"}))->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductWithdrawn({productId: "p1"}),
    )
  )

  test("ProductUnarchived publishes ProductRelisted", () =>
    whenDelegateEvent(Delegate.ProductUnarchived({productId: "p1"}))->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductRelisted({productId: "p1"}),
    )
  )
})
