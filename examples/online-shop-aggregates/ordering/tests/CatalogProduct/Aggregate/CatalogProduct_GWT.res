@@reventless.gwt

describe("CatalogProduct Behavior", () => {
  test("Sync on new aggregate produces Synced", () =>
    givenEvents([])
    ->whenCmd(Sync({name: "Laptop", price: 999.99}))
    ->thenEvent(Synced({name: "Laptop", price: 999.99}))
  )

  test("Sync on already-synced aggregate produces no events (idempotent)", () =>
    givenEvents([Synced({name: "Laptop", price: 999.99})])
    ->whenCmd(Sync({name: "Laptop", price: 999.99}))
    ->thenNoEvent
  )

  test("UpdatePrice on never-synced aggregate produces no events (idempotent)", () =>
    givenEvents([])
    ->whenCmd(UpdatePrice({price: 1.0}))
    ->thenNoEvent
  )

  test("UpdatePrice on synced aggregate produces PriceUpdated", () =>
    givenEvents([Synced({name: "Laptop", price: 999.99})])
    ->whenCmd(UpdatePrice({price: 899.99}))
    ->thenEvent(PriceUpdated({price: 899.99}))
  )
})
