// Boundary GWT for the Products extension point: internal Catalog DCB log
// events become the stable public events Ordering subscribes to.
@@reventless.gwt

let pid = CatalogSpec.ProductId.make

describe("Products ExtensionPoint mapping", () => {
  test("ProductAdded publishes ProductBecameAvailable", () =>
    whenDelegateEvent(
      Delegate.ProductAdded({
        productId: pid("p1"),
        name: "Book",
        description: "A good book",
        price: 9.99,
      }),
    )->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductBecameAvailable({productId: pid("p1"), name: "Book", price: 9.99}),
    )
  )

  test("ProductPriceChanged publishes ProductPriceChanged", () =>
    whenDelegateEvent(
      Delegate.ProductPriceChanged({productId: pid("p1"), price: 7.5}),
    )->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductPriceChanged({productId: pid("p1"), price: 7.5}),
    )
  )
})
