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

  // The requested delivery slot is a single `DateRange`, not a `start*`/`end*`
  // name pair, and it rides the command straight onto the event unchanged. A
  // Standard order can still ask for a window; an order that omits it carries no
  // key at all (the optional field above).
  test("a requested delivery window is carried onto the event", () => {
    let window = Reventless.DateRange.make(
      ~start="2026-03-02T09:00:00Z",
      ~end_="2026-03-02T11:00:00Z",
    )->Result.getOrThrow
    givenEvents([CatalogProductSynced({productId: "p1"})])
    ->whenCmd(
      PlaceOrder({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        deliveryWindow: window,
      }),
    )
    ->thenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        shippingMethod: Standard,
        deliveryWindow: window,
      }),
    )
  })

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
