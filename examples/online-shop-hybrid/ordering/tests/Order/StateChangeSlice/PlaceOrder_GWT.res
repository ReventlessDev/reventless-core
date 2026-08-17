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

  // The shelf lifecycle reaching the decision. The view deletes a withdrawn
  // product's row, so a shopper never sees it; these pin the write side to the
  // same answer, which is the half that was missing.
  test("a withdrawn product can no longer be ordered", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1"}),
      CatalogProductWithdrawn({productId: "p1"}),
    ])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenError(ProductsNotAvailable({missing: ["p1"]}))
  )

  // Withdrawal removes one id, not the shelf.
  test("withdrawing one product leaves its siblings orderable", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1"}),
      CatalogProductSynced({productId: "p2"}),
      CatalogProductWithdrawn({productId: "p2"}),
    ])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
  )

  // A basket that mixes live and withdrawn stock names only what it refused.
  test("a basket naming a withdrawn product reports just that product as missing", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1"}),
      CatalogProductSynced({productId: "p2"}),
      CatalogProductWithdrawn({productId: "p2"}),
    ])
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

  // And the way back. A relist that did not restore orderability would break the
  // lifecycle in the other direction — off the shelf permanently.
  test("a relisted product can be ordered again", () =>
    givenEvents([
      CatalogProductSynced({productId: "p1"}),
      CatalogProductWithdrawn({productId: "p1"}),
      CatalogProductRelisted({productId: "p1"}),
    ])
    ->whenCmd(
      PlaceOrder({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
    ->thenEvent(
      OrderPlaced({orderId: "o1", customerId: "c1", productIds: ["p1"], shippingMethod: Standard}),
    )
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
