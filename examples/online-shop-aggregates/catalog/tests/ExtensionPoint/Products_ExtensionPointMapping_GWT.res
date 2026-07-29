// Boundary GWT for the Products extension point: internal Product aggregate
// events become the stable public events Ordering subscribes to.
@@reventless.gwt

describe("Products ExtensionPoint mapping", () => {
  test("Added publishes ProductBecameAvailable", () =>
    whenDelegateEvent(
      Delegate.Added({name: "Book", description: "A good book", price: 9.99, imageUrl: "/productImages/book.jpg"}),
    )->thenPublishesEvent(
      "gwt-id",
      ExtensionPoint.ProductBecameAvailable({productId: "gwt-id", name: "Book", price: 9.99}),
    )
  )

  test("PriceUpdated publishes ProductPriceChanged", () =>
    whenDelegateEvent(Delegate.PriceUpdated({price: 7.5}))->thenPublishesEvent(
      "gwt-id",
      ExtensionPoint.ProductPriceChanged({productId: "gwt-id", price: 7.5}),
    )
  )

  test("NameUpdated publishes nothing", () =>
    whenDelegateEvent(Delegate.NameUpdated({name: "Better Book"}))->thenPublishesNothing
  )

  test("DescriptionUpdated publishes nothing", () =>
    whenDelegateEvent(
      Delegate.DescriptionUpdated({description: "A really good book"}),
    )->thenPublishesNothing
  )
})
