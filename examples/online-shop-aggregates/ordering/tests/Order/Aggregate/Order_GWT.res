@@reventless.gwt

open Ordering_Examples

// Ids are typed; the literals are made once, here.
let cust1 = CustomerId.make("cust-1")
let prod1 = CatalogSpec.ProductId.make("prod-1")
let prod2 = CatalogSpec.ProductId.make("prod-2")

describe("Order Behavior", () => {
  // scenario-id: 4f723805-10e2-4b72-b40a-6cf71e91c375
  test("Place on new aggregate produces Placed", () =>
    givenEvents([])
    ->whenCmd(Place({customerId: cust1, productIds: [prod1, prod2]}))
    ->thenEvent(Placed({customerId: cust1, productIds: [prod1, prod2]}))
  )

  // scenario-id: 061fb189-7195-474f-8010-0a0339d7cf11
  test("Place on existing order returns OrderAlreadyPlaced", () =>
    givenEvents([Placed({customerId: cust1, productIds: [prod1]})])
    ->whenCmd(Place({customerId: cust1, productIds: [prod1]}))
    ->thenError(OrderAlreadyPlaced)
  )

  // scenario-id: 3cb519a2-53ba-4f66-938f-2d5e4a3b736b
  test("Place on shipped order returns OrderAlreadyShipped", () =>
    givenEvents([Placed({customerId: cust1, productIds: [prod1]}), Shipped])
    ->whenCmd(Place({customerId: cust1, productIds: [prod1]}))
    ->thenError(OrderAlreadyShipped)
  )

  // scenario-id: e74bad7c-abe6-4313-9290-b20f75897285
  test("Place on cancelled order returns OrderAlreadyCancelled", () =>
    givenEvents([
      Placed({customerId: cust1, productIds: [prod1]}),
      Cancelled({productIds: [prod1]}),
    ])
    ->whenCmd(Place({customerId: cust1, productIds: [prod1]}))
    ->thenError(OrderAlreadyCancelled)
  )

  // scenario-id: 1e97733f-32dd-473a-86e9-6c2cfec8f813
  test("Ship on non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(Ship)
    ->thenError(OrderNotFound)
  )

  // scenario-id: 54073db7-f835-4d89-a648-71b6dc4869c2
  test("Ship on placed order produces Shipped", () =>
    givenEvents([Placed({customerId: cust1, productIds: [prod1]})])
    ->whenCmd(Ship)
    ->thenEvent(Shipped)
  )

  // scenario-id: 2d4c200e-ece6-40c4-a67d-460f5beca59e
  test("Ship on shipped order produces no events (idempotent)", () =>
    givenEvents([Placed({customerId: cust1, productIds: [prod1]}), Shipped])
    ->whenCmd(Ship)
    ->thenNoEvent
  )

  // scenario-id: 08783980-65d7-4114-b4ef-f0f95b0b3fc5
  test("Ship on cancelled order returns OrderAlreadyCancelled", () =>
    givenEvents([
      Placed({customerId: cust1, productIds: [prod1]}),
      Cancelled({productIds: [prod1]}),
    ])
    ->whenCmd(Ship)
    ->thenError(OrderAlreadyCancelled)
  )

  // scenario-id: 2104ec68-2de0-464b-b8f8-379f47b03db9
  test("Cancel on non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(Cancel)
    ->thenError(OrderNotFound)
  )

  // scenario-id: 3d974a23-5eb6-4463-9824-e61b0fa5a278
  test("Cancel on placed order produces Cancelled", () =>
    givenEvents([Placed({customerId: cust1, productIds: [prod1]})])
    ->whenCmd(Cancel)
    ->thenEvent(Cancelled({productIds: [prod1]}))
  )

  // scenario-id: 6144fcb7-d768-4237-9e67-e530c736210d
  test("Cancel on shipped order returns OrderAlreadyShipped", () =>
    givenEvents([Placed({customerId: cust1, productIds: [prod1]}), Shipped])
    ->whenCmd(Cancel)
    ->thenError(OrderAlreadyShipped)
  )

  // scenario-id: 07679806-2e68-4cdb-b8c0-8cc67bd65fa7
  test("Cancel on cancelled order produces no events (idempotent)", () =>
    givenEvents([
      Placed({customerId: cust1, productIds: [prod1]}),
      Cancelled({productIds: [prod1]}),
    ])
    ->whenCmd(Cancel)
    ->thenNoEvent
  )

  // scenario-id: aa624dbf-659b-4685-8695-4203e23a855f
  test("Refund on non-existent order returns OrderNotFound", () =>
    givenEvents([])
    ->whenCmd(Refund({reason: "lost-in-transit"}))
    ->thenError(OrderNotFound)
  )

  // scenario-id: cf56897b-1cf0-4768-8ada-eae11c069d95
  test("Refund on placed order returns OrderNotCancelled", () =>
    givenEvents([Placed({customerId: cust1, productIds: [prod1]})])
    ->whenCmd(Refund({reason: changedMind}))
    ->thenError(OrderNotCancelled)
  )

  // scenario-id: 802fb4a7-3768-4c6d-8a54-444f44891515
  test("Refund on shipped order returns OrderNotCancelled", () =>
    givenEvents([Placed({customerId: cust1, productIds: [prod1]}), Shipped])
    ->whenCmd(Refund({reason: "delivered-damaged"}))
    ->thenError(OrderNotCancelled)
  )

  // scenario-id: d9f7692d-4d64-41d9-b845-f5958fe95bc0
  test("Refund on cancelled order produces Refunded", () =>
    givenEvents([
      Placed({customerId: cust1, productIds: [prod1]}),
      Cancelled({productIds: [prod1]}),
    ])
    ->whenCmd(Refund({reason: changedMind}))
    ->thenEvent(Refunded({reason: changedMind}))
  )

  // scenario-id: 4ced8701-2214-4f05-89ed-057b130979ad
  test("Refund on already-refunded order produces no events (idempotent)", () =>
    givenEvents([
      Placed({customerId: cust1, productIds: [prod1]}),
      Cancelled({productIds: [prod1]}),
      Refunded({reason: changedMind}),
    ])
    ->whenCmd(Refund({reason: changedMind}))
    ->thenNoEvent
  )
})
