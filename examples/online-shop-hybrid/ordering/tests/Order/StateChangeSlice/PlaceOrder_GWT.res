@@reventless.gwt

describe("PlaceOrder StateChangeSlice", () => {
  test("requires referenced products to be synced first", () =>
    givenEvents([])
    ->whenCmd(PlaceOrder({orderId: "o1", customerId: "c1", productId: ["p1"]}))
    ->thenError(ProductsNotAvailable({missing: ["p1"]}))
  )

  test("placement succeeds when products are available", () =>
    givenEvents([CatalogProductSynced({productId: "p1"})])
    ->whenCmd(PlaceOrder({orderId: "o1", customerId: "c1", productId: ["p1"]}))
    ->thenEvent(OrderPlaced({orderId: "o1", customerId: "c1", productId: ["p1"]}))
  )

  test("partial product availability returns ProductsNotAvailable with missing list", () =>
    givenEvents([CatalogProductSynced({productId: "p1"})])
    ->whenCmd(PlaceOrder({orderId: "o1", customerId: "c1", productId: ["p1", "p2"]}))
    ->thenError(ProductsNotAvailable({missing: ["p2"]}))
  )

  test("re-placing the same orderId returns OrderAlreadyPlaced", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1"}),
      OrderPlaced({orderId: "o1"}),
    ])
    ->whenCmd(PlaceOrder({orderId: "o1", customerId: "c1", productId: ["p1"]}))
    ->thenError(OrderAlreadyPlaced)
  )
})
