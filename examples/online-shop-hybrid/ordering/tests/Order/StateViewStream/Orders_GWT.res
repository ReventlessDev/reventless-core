@@reventless.gwt

open OrderingExamples

// Minor units, the way `Money` counts them: 2500 is €25.00. The lines are the
// write side's own — this view copies them through rather than deriving anything
// from them, apart from `itemCount`.

let dockLine: orderLine = {
  productId: p1,
  name: "Fathom Dock",
  quantity: 1,
  unitPrice: Reventless.Money.make(~amount=2500.0, ~currency=Reventless.Currency.EUR),
  lineTotal: Reventless.Money.make(~amount=2500.0, ~currency=Reventless.Currency.EUR),
}

let chargerLine: orderLine = {
  productId: p2,
  name: "Cirrus Charger",
  quantity: 2,
  unitPrice: Reventless.Money.make(~amount=1000.0, ~currency=Reventless.Currency.EUR),
  lineTotal: Reventless.Money.make(~amount=2000.0, ~currency=Reventless.Currency.EUR),
}

// Every event a projection GWT feeds carries the harness's fixed producer time,
// so every trail entry below is stamped with that one instant.
let trail = (states: array<lifecycle>) =>
  states->Array.map((state): Reventless.Lifecycle.Trail.entry<lifecycle> => {
    state,
    at: "1970-01-01T00:00:00Z",
  })

describe("Orders StateViewSlice", () => {
  // scenario-id: f758b677-2fad-4184-b8f6-185a47a9c4ea
  test("OrderPlaced creates a row with status Placed", () =>
    givenEvents([])
    ->whenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1, p2],
        lines: [dockLine, chargerLine],
        total: Reventless.Money.make(~amount=4500.0, ~currency=Reventless.Currency.EUR),
        shippingMethod: Standard,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      }),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: o1,
        customerId: c1,
        productIds: [p1, p2],
        lines: [dockLine, chargerLine],
        total: Reventless.Money.make(~amount=4500.0, ~currency=Reventless.Currency.EUR),
        itemCount: 3,
        lifecycle: Placed,
        shippingMethod: Standard,
        placedAt: epoch,
        trail: trail([Placed]),
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      },
    )
  )

  // The declared span is carried straight from the event onto the row, with
  // `customerId` beside it as the resource ref — which is what lets a scheduler
  // mode lay a bar out from the row without guessing the pair from field names.
  // scenario-id: 5e6fe37a-b46a-4cbf-a26f-8716e7303848
  test("a requested delivery window lands on the row", () => {
    let window =
      Reventless.DateRange.make(
        ~start="2026-03-02T09:00:00Z",
        ~end_="2026-03-02T11:00:00Z",
      )->Result.getOrThrow
    givenEvents([])
    ->whenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        deliveryWindow: Some(window),
        firstProductName: None,
        firstProductImage: None,
      }),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        itemCount: 1,
        lifecycle: Placed,
        shippingMethod: Standard,
        placedAt: epoch,
        trail: trail([Placed]),
        deliveryWindow: Some(window),
        firstProductName: None,
        firstProductImage: None,
      },
    )
  })

  // scenario-id: 47f4cef5-a851-43d9-b90d-db04732e7d1e
  test("the shipping method chosen at placement is projected onto the row", () =>
    givenEvents([])
    ->whenEvent(
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Pickup,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      }),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        itemCount: 1,
        lifecycle: Placed,
        shippingMethod: Pickup,
        placedAt: epoch,
        trail: trail([Placed]),
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      },
    )
  )

  // scenario-id: b7b61aa4-8318-4d7c-a7e2-1ed39fa41627
  test("OrderShipped updates status to Shipped", () =>
    givenEvents([
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Express,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      }),
    ])
    ->whenEvent(OrderShipped({orderId: o1}))
    ->thenStateWithId(
      "o1",
      {
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        itemCount: 1,
        lifecycle: Shipped,
        shippingMethod: Express,
        placedAt: epoch,
        trail: trail([Placed, Shipped]),
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      },
    )
  )

  // scenario-id: f3b24de1-8e25-41a6-abd8-2baf4e71d864
  test("OrderCancelled updates status to Cancelled", () =>
    givenEvents([
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      }),
    ])
    ->whenEvent(OrderCancelled({orderId: o1}))
    ->thenStateWithId(
      "o1",
      {
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        itemCount: 1,
        lifecycle: Cancelled,
        shippingMethod: Standard,
        placedAt: epoch,
        trail: trail([Placed, Cancelled]),
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      },
    )
  )

  // The way back. A cancelled order that is reopened is `Placed` again, and
  // `ShipOrder` says so on its own side — so a view that did not fold this event
  // would leave a reopened order rendering `Cancelled` for the rest of its life
  // while shipping perfectly well. The two halves have to agree, and only a
  // scenario on each says whether they do.
  // scenario-id: 118aa260-d7d6-4fce-aafb-3d9135b97c9a
  test("OrderReopened puts a cancelled order back to Placed", () =>
    givenEvents([
      OrderPlaced({
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        shippingMethod: Standard,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      }),
      OrderCancelled({orderId: o1}),
    ])
    ->whenEvent(OrderReopened({orderId: o1}))
    ->thenStateWithId(
      "o1",
      {
        orderId: o1,
        customerId: c1,
        productIds: [p1],
        lines: [dockLine],
        total: dockPrice,
        itemCount: 1,
        lifecycle: Placed,
        shippingMethod: Standard,
        placedAt: epoch,
        trail: trail([Placed, Cancelled, Placed]),
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      },
    )
  )
})
