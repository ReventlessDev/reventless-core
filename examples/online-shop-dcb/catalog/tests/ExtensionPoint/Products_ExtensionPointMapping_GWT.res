// Boundary GWT for the Products extension point: internal Catalog DCB log
// events become the stable public events Ordering subscribes to.
@@reventless.gwt

open CatalogExamples

describe("Products ExtensionPoint mapping", () => {
  // scenario-id: affe4040-933d-4b31-b50e-011abe200945
  test("ProductAdded publishes ProductBecameAvailable", () =>
    whenDelegateEvent(
      Delegate.ProductAdded({
        productId: p1,
        name: "Book",
        description: "A good book",
        price: 9.99,
      }),
    )->thenPublishesEvent(
      "p1",
      ExtensionPoint.ProductBecameAvailable({productId: p1, name: "Book", price: 9.99}),
    )
  )

  // scenario-id: 6be14fa6-3938-4a6d-ae4c-15d4c7c70a29
  test("ProductPriceChanged publishes ProductPriceChanged", () =>
    whenDelegateEvent(
      Delegate.ProductPriceChanged({productId: p1, price: 7.5}),
    )->thenPublishesEvent("p1", ExtensionPoint.ProductPriceChanged({productId: p1, price: 7.5}))
  )
})
