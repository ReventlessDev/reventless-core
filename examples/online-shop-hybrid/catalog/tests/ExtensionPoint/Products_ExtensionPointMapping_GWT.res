// Boundary GWT for the Products extension point: internal Catalog events
// become the stable public events Ordering subscribes to.
@@reventless.gwt

describe("Products ExtensionPoint mapping", () => {
  test("ProductAdded becomes the public ProductBecameAvailable", () =>
    whenInboundEvent(
      Delegate.ProductAdded({productId: "p1", name: "Book", description: "A good book", price: 9.99}),
    )->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductBecameAvailable({productId: "p1", name: "Book", price: 9.99}),
    )
  )

  test("ProductPriceChanged is forwarded to the extension point", () =>
    whenInboundEvent(Delegate.ProductPriceChanged({productId: "p1", price: 7.5}))->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductPriceChanged({productId: "p1", price: 7.5}),
    )
  )
})
