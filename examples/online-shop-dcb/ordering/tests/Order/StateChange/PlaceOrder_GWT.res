@@reventless.gwt

open OrderingExamples

describe("PlaceOrder StateChangeSlice", () => {
  // scenario-id: 2165f9d4-87c0-4f25-a4f6-c3e0ac59a41b
  test("requires referenced products to be synced first", () =>
    givenEvents([])
    ->whenCmd(PlaceOrder({orderId: o1, customerId: c1, productIds: [p1]}))
    ->thenError(ProductsNotAvailable({missing: [p1]}))
  )

  // scenario-id: d20adf8e-1883-4e2f-8d22-10f2470a1f44
  test("placement succeeds when products are available", () =>
    givenEvents([CatalogProductSynced({productId: p1})])
    ->whenCmd(PlaceOrder({orderId: o1, customerId: c1, productIds: [p1]}))
    ->thenEvent(OrderPlaced({orderId: o1, customerId: c1, productIds: [p1]}))
  )

  // scenario-id: 7594b170-f241-4eb9-83d1-aaa651a80f66
  test("partial product availability returns ProductsNotAvailable with missing list", () =>
    givenEvents([CatalogProductSynced({productId: p1})])
    ->whenCmd(PlaceOrder({orderId: o1, customerId: c1, productIds: [p1, p2]}))
    ->thenError(ProductsNotAvailable({missing: [p2]}))
  )

  // scenario-id: 2d259e4c-b8d5-40ae-b5f5-018cbf31eaa4
  test("re-placing the same orderId returns OrderAlreadyPlaced", () =>
    givenEvents([CatalogProductSynced({productId: p1}), OrderPlaced({orderId: o1})])
    ->whenCmd(PlaceOrder({orderId: o1, customerId: c1, productIds: [p1]}))
    ->thenError(OrderAlreadyPlaced)
  )

  // scenario-id: 2fc00acf-df4c-4c2e-8280-a82dedad5fb0
  test("a sibling OrderPlaced for a different orderId does not block placement", () =>
    givenEvents([CatalogProductSynced({productId: p1}), OrderPlaced({orderId: o2})])
    ->whenCmd(PlaceOrder({orderId: o1, customerId: c1, productIds: [p1]}))
    ->thenEvent(OrderPlaced({orderId: o1, customerId: c1, productIds: [p1]}))
  )
})
