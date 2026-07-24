@@reventless.gwt

describe("PlaceOrder StateChangeSlice", () => {
  test("requires referenced products to be synced first", () =>
    givenEvents([])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenError(ProductsNotAvailable({missing: ["p1"]}))
  )

  test("placement succeeds when products are available", () =>
    givenEvents([CatalogProductSynced({productId: "p1"})])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
  )

  test("the chosen shipping method is carried onto the event", () =>
    givenEvents([CatalogProductSynced({productId: "p1"})])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Express}),
    )
    ->thenEvent(
      OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Express}),
    )
  )

  test("partial product availability returns ProductsNotAvailable with missing list", () =>
    givenEvents([CatalogProductSynced({productId: "p1"})])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        shippingMethod: Standard,
      }),
    )
    ->thenError(ProductsNotAvailable({missing: ["p2"]}))
  )

  test("re-placing the same orderId returns OrderAlreadyPlaced", () =>
    givenEvents([CatalogProductSynced({productId: "p1"}), OrderPlaced({orderId: "o1"})])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenError(OrderAlreadyPlaced)
  )

  test("a sibling OrderPlaced for a different orderId does not block placement", () =>
    givenEvents([CatalogProductSynced({productId: "p1"}), OrderPlaced({orderId: "o2"})])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Pickup}),
    )
    ->thenEvent(
      OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Pickup}),
    )
  )
})
