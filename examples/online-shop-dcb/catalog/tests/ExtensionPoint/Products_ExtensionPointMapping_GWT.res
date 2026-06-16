// Boundary GWT for the Products extension point: internal Catalog DCB log
// events become the stable public events Ordering subscribes to.
@@reventless.gwt

describe("Products ExtensionPoint mapping", () => {
  test("ProductAdded publishes ProductBecameAvailable", () =>
    whenDelegateEvent(
      Delegate.ProductAdded({productId: "p1", name: "Book", description: "A good book", price: 9.99}),
    )->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductBecameAvailable({productId: "p1", name: "Book", price: 9.99}),
    )
  )

  test("ProductPriceChanged publishes ProductPriceChanged", () =>
    whenDelegateEvent(Delegate.ProductPriceChanged({productId: "p1", price: 7.5}))->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductPriceChanged({productId: "p1", price: 7.5}),
    )
  )
})
