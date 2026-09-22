// Boundary GWT for the Products extension point: internal Product aggregate
// events become the stable public events Ordering subscribes to.
@@reventless.gwt

let gwtId = CatalogSpec.ProductId.make("gwt-id")

describe("Products ExtensionPoint mapping", () => {
  // scenario-id: 44692d81-7898-460c-9315-f4b13bd7876a
  test("Added publishes ProductBecameAvailable", () =>
    whenDelegateEvent(
      Delegate.Added({
        name: "Book",
        description: "A good book",
        price: 9.99,
        imageUrl: "/productImages/book.jpg",
      }),
    )->thenPublishesEvent(
      "gwt-id",
      ExtensionPoint.ProductBecameAvailable({productId: gwtId, name: "Book", price: 9.99}),
    )
  )

  // scenario-id: 5d399774-d4db-4dd5-a36f-59c6efd6d33b
  test("PriceUpdated publishes ProductPriceChanged", () =>
    whenDelegateEvent(Delegate.PriceUpdated({price: 7.5}))->thenPublishesEvent(
      "gwt-id",
      ExtensionPoint.ProductPriceChanged({productId: gwtId, price: 7.5}),
    )
  )

  // scenario-id: 3867eb1c-0b12-43df-8525-267e410b4d96
  test("NameUpdated publishes nothing", () =>
    whenDelegateEvent(Delegate.NameUpdated({name: "Better Book"}))->thenPublishesNothing
  )

  // scenario-id: b42bf31d-fb05-4b2c-9d7b-393e46686a40
  test("DescriptionUpdated publishes nothing", () =>
    whenDelegateEvent(
      Delegate.DescriptionUpdated({description: "A really good book"}),
    )->thenPublishesNothing
  )
})
