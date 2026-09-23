// Boundary GWT for the Products extension point: internal Catalog events
// become the stable public events Ordering subscribes to.
@@reventless.gwt

open Catalog_Examples

// Published events and handled directives are disjoint channels on the same
// mapping run — each `test` projects to one channel and asserts on it.
// Prices are money, so a test writes the amount a person would say and converts
// it once. `ofMajor` scales by the currency's own exponent, which is what keeps
// the literal honest: 9.99 EUR is 999 cents, and the same call on a JPY price
// would scale by 1.

describe("Products ExtensionPoint mapping", () => {
  // scenario-id: 8193d85c-3a01-4703-9adf-1a708b5377b3
  test("ProductAdded publishes ProductBecameAvailable", () =>
    whenDelegateEvent(
      Delegate.ProductAdded({
        productId: p1,
        name: "Book",
        description: "A good book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
      }),
    )->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductBecameAvailable({
        productId: p1,
        name: "Book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
      }),
    )
  )

  // scenario-id: 288856de-de07-4bc4-af9e-51493b51e884
  test("ProductAdded raises no directive", () =>
    whenDelegateEvent(
      Delegate.ProductAdded({
        productId: p1,
        name: "Book",
        description: "A good book",
        price: Reventless.Money.make(~amount=999.0, ~currency=Reventless.Currency.EUR),
      }),
    )->thenHandlesNoDirective
  )

  // scenario-id: 0b5ff51c-6693-419f-83fc-a4b02d4773e6
  test("ProductPriceChanged is forwarded to the extension point", () =>
    whenDelegateEvent(
      Delegate.ProductPriceChanged({
        productId: p1,
        price: Reventless.Money.make(~amount=750.0, ~currency=Reventless.Currency.EUR),
      }),
    )->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductPriceChanged({
        productId: p1,
        price: Reventless.Money.make(~amount=750.0, ~currency=Reventless.Currency.EUR),
      }),
    )
  )

  // scenario-id: 6590fc55-394d-48e1-afc8-ce4f621a51cf
  test("ProductPriceChanged also fires a pricing-update directive", () =>
    whenDelegateEvent(
      Delegate.ProductPriceChanged({
        productId: p1,
        price: Reventless.Money.make(~amount=750.0, ~currency=Reventless.Currency.EUR),
      }),
    )->thenHandlesDirective(
      ExtensionPoint.EmitPricingUpdate({
        productId: p1,
        price: Reventless.Money.make(~amount=750.0, ~currency=Reventless.Currency.EUR),
      }),
    )
  )

  // Both of Catalog's retirements collapse to the one fact Ordering needs. This
  // is the assertion that keeps the boundary a capability rather than a mirror
  // of the catalog's lifecycle: adding a third way off the shelf must not add a
  // third published event.
  // scenario-id: 4530815c-5fba-4bf4-875d-f3f9dea0ae1a
  test("ProductArchived publishes ProductWithdrawn", () =>
    whenDelegateEvent(Delegate.ProductArchived({productId: p1}))->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductWithdrawn({productId: p1}),
    )
  )

  // scenario-id: 7e2d5541-726a-42b4-a206-0c11043b4d7b
  test("ProductDiscontinued publishes the same ProductWithdrawn", () =>
    whenDelegateEvent(Delegate.ProductDiscontinued({productId: p1}))->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductWithdrawn({productId: p1}),
    )
  )

  // scenario-id: 8d28cf9a-f8df-4c66-a8eb-ae7b4108a532
  test("ProductUnarchived publishes ProductRelisted", () =>
    whenDelegateEvent(Delegate.ProductUnarchived({productId: p1}))->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductRelisted({productId: p1}),
    )
  )
})
