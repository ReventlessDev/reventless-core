@@reventless.gwt

describe("DiscontinueProduct StateChangeSlice", () => {
  test("discontinue on non-existent product returns ProductNotFound", () =>
    givenEvents([])->whenCmd(DiscontinueProduct({productId: "p1"}))->thenError(ProductNotFound)
  )

  test("discontinue on a listed product produces ProductDiscontinued", () =>
    givenEvents([ProductAdded])
    ->whenCmd(DiscontinueProduct({productId: "p1"}))
    ->thenEvent(ProductDiscontinued({productId: "p1"}))
  )

  // Allowed from either live state: the decision is about the product's future
  // rather than about where it sits today.
  test("discontinue on an archived product produces ProductDiscontinued", () =>
    givenEvents([ProductAdded, ProductArchived])
    ->whenCmd(DiscontinueProduct({productId: "p1"}))
    ->thenEvent(ProductDiscontinued({productId: "p1"}))
  )

  test("discontinue on a discontinued product produces no events (idempotent)", () =>
    givenEvents([ProductAdded, ProductDiscontinued])
    ->whenCmd(DiscontinueProduct({productId: "p1"}))
    ->thenNoEvent
  )
})
