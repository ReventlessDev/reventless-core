@@reventless.gwt

open Ordering_Examples

describe("CatalogProduct Behavior", () => {
  // scenario-id: e0d3dd62-1687-4920-a1ad-d61733936926
  test("Sync on new aggregate produces Synced", () =>
    givenEvents([])
    ->whenCmd(Sync({name: laptop, price: 999.99}))
    ->thenEvent(Synced({name: laptop, price: 999.99}))
  )

  // scenario-id: aa7ebc46-2b74-440d-92b1-d5b6262de254
  test("Sync on already-synced aggregate produces no events (idempotent)", () =>
    givenEvents([Synced({name: laptop, price: 999.99})])
    ->whenCmd(Sync({name: laptop, price: 999.99}))
    ->thenNoEvent
  )

  // scenario-id: 69fe9b40-3a62-497d-b39b-098173ef8cd5
  test("UpdatePrice on never-synced aggregate produces no events (idempotent)", () =>
    givenEvents([])
    ->whenCmd(UpdatePrice({price: 1.0}))
    ->thenNoEvent
  )

  // scenario-id: fef61ceb-02a6-4d0c-a1e9-297c99a4d7d9
  test("UpdatePrice on synced aggregate produces PriceUpdated", () =>
    givenEvents([Synced({name: laptop, price: 999.99})])
    ->whenCmd(UpdatePrice({price: 899.99}))
    ->thenEvent(PriceUpdated({price: 899.99}))
  )
})
