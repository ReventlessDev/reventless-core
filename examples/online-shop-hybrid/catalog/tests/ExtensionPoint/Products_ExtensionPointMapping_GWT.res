// Boundary GWT for the Products extension point: internal Catalog events
// become the stable public events Ordering subscribes to.
@@reventless.gwt

// Published events and handled directives are disjoint channels on the same
// mapping run — each `test` projects to one channel and asserts on it.
describe("Products ExtensionPoint mapping", () => {
  test("ProductAdded publishes ProductBecameAvailable", () =>
    whenDelegateEvent(
      Delegate.ProductAdded({productId: "p1", name: "Book", description: "A good book", price: 9.99}),
    )->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductBecameAvailable({productId: "p1", name: "Book", price: 9.99}),
    )
  )

  test("ProductAdded raises no directive", () =>
    whenDelegateEvent(
      Delegate.ProductAdded({productId: "p1", name: "Book", description: "A good book", price: 9.99}),
    )->thenHandlesNoDirective
  )

  test("ProductPriceChanged is forwarded to the extension point", () =>
    whenDelegateEvent(Delegate.ProductPriceChanged({productId: "p1", price: 7.5}))->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductPriceChanged({productId: "p1", price: 7.5}),
    )
  )

  test("ProductPriceChanged also fires a pricing-update directive", () =>
    whenDelegateEvent(
      Delegate.ProductPriceChanged({productId: "p1", price: 7.5}),
    )->thenHandlesDirective(
      ExtensionPoint.EmitPricingUpdate({productId: "p1", price: 7.5}),
    )
  )
})
