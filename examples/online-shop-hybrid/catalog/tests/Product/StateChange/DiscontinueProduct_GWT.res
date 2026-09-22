@@reventless.gwt

open CatalogExamples

describe("DiscontinueProduct StateChangeSlice", () => {
  // scenario-id: 16ad56a6-d9da-4144-9912-2893d70b15cc
  test("discontinue on non-existent product returns ProductNotFound", () =>
    givenEvents([])->whenCmd(DiscontinueProduct({productId: p1}))->thenError(ProductNotFound)
  )

  // scenario-id: 421bee26-f66e-416c-a0a6-94650153beaa
  test("discontinue on a listed product produces ProductDiscontinued", () =>
    givenEvents([ProductAdded])
    ->whenCmd(DiscontinueProduct({productId: p1}))
    ->thenEvent(ProductDiscontinued({productId: p1}))
  )

  // Allowed from either live state: the decision is about the product's future
  // rather than about where it sits today.
  // scenario-id: b5657df3-79b9-40c7-810d-6d13366f0599
  test("discontinue on an archived product produces ProductDiscontinued", () =>
    givenEvents([ProductAdded, ProductArchived])
    ->whenCmd(DiscontinueProduct({productId: p1}))
    ->thenEvent(ProductDiscontinued({productId: p1}))
  )

  // scenario-id: 0464d28d-3a8d-45a0-bd09-6fc006d023a8
  test("discontinue on a discontinued product produces no events (idempotent)", () =>
    givenEvents([ProductAdded, ProductDiscontinued])
    ->whenCmd(DiscontinueProduct({productId: p1}))
    ->thenNoEvent
  )
})
