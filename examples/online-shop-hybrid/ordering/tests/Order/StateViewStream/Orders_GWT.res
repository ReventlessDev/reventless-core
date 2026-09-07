@@reventless.gwt

// Minor units, the way `Money` counts them: 2500 is €25.00. The lines are the
// write side's own — this view copies them through rather than deriving anything
// from them, apart from `itemCount`.
let eur = amount => Reventless.Money.make(~amount, ~currency=EUR)

let dockLine: orderLine = {
  productId: "p1",
  name: "Fathom Dock",
  quantity: 1,
  unitPrice: eur(2500.0),
  lineTotal: eur(2500.0),
}

let chargerLine: orderLine = {
  productId: "p2",
  name: "Cirrus Charger",
  quantity: 2,
  unitPrice: eur(1000.0),
  lineTotal: eur(2000.0),
}

describe("Orders StateViewSlice", () => {
  test("OrderPlaced creates a row with status Placed", () =>
    givenEvents([])
    ->whenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        lines: [dockLine, chargerLine],
        total: eur(4500.0),
        shippingMethod: Standard,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      }),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1", "p2"],
        lines: [dockLine, chargerLine],
        total: eur(4500.0),
        itemCount: 3,
        lifecycle: Placed,
        shippingMethod: Standard,
        placedAt: "1970-01-01T00:00:00Z",
        shippedAt: None,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      },
    )
  )

  // The declared span is carried straight from the event onto the row, with
  // `customerId` beside it as the resource ref — which is what lets a scheduler
  // mode lay a bar out from the row without guessing the pair from field names.
  test("a requested delivery window lands on the row", () => {
    let window = Reventless.DateRange.make(
      ~start="2026-03-02T09:00:00Z",
      ~end_="2026-03-02T11:00:00Z",
    )->Result.getOrThrow
    givenEvents([])
    ->whenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [dockLine],
        total: eur(2500.0),
        shippingMethod: Standard,
        deliveryWindow: Some(window),
        firstProductName: None,
        firstProductImage: None,
      }),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [dockLine],
        total: eur(2500.0),
        itemCount: 1,
        lifecycle: Placed,
        shippingMethod: Standard,
        placedAt: "1970-01-01T00:00:00Z",
        shippedAt: None,
        deliveryWindow: Some(window),
        firstProductName: None,
        firstProductImage: None,
      },
    )
  })

  test("the shipping method chosen at placement is projected onto the row", () =>
    givenEvents([])
    ->whenEvent(
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [dockLine],
        total: eur(2500.0),
        shippingMethod: Pickup,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      }),
    )
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [dockLine],
        total: eur(2500.0),
        itemCount: 1,
        lifecycle: Placed,
        shippingMethod: Pickup,
        placedAt: "1970-01-01T00:00:00Z",
        shippedAt: None,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      },
    )
  )

  test("OrderShipped updates status to Shipped", () =>
    givenEvents([
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [dockLine],
        total: eur(2500.0),
        shippingMethod: Express,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      }),
    ])
    ->whenEvent(OrderShipped({orderId: "o1"}))
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [dockLine],
        total: eur(2500.0),
        itemCount: 1,
        lifecycle: Shipped,
        shippingMethod: Express,
        placedAt: "1970-01-01T00:00:00Z",
        shippedAt: Some("1970-01-01T00:00:00Z"),
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      },
    )
  )

  test("OrderCancelled updates status to Cancelled", () =>
    givenEvents([
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [dockLine],
        total: eur(2500.0),
        shippingMethod: Standard,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      }),
    ])
    ->whenEvent(OrderCancelled({orderId: "o1"}))
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [dockLine],
        total: eur(2500.0),
        itemCount: 1,
        lifecycle: Cancelled,
        shippingMethod: Standard,
        placedAt: "1970-01-01T00:00:00Z",
        shippedAt: None,
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
  test("OrderReopened puts a cancelled order back to Placed", () =>
    givenEvents([
      OrderPlaced({
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [dockLine],
        total: eur(2500.0),
        shippingMethod: Standard,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      }),
      OrderCancelled({orderId: "o1"}),
    ])
    ->whenEvent(OrderReopened({orderId: "o1"}))
    ->thenStateWithId(
      "o1",
      {
        orderId: "o1",
        customerId: "c1",
        productIds: ["p1"],
        lines: [dockLine],
        total: eur(2500.0),
        itemCount: 1,
        lifecycle: Placed,
        shippingMethod: Standard,
        placedAt: "1970-01-01T00:00:00Z",
        shippedAt: None,
        deliveryWindow: None,
        firstProductName: None,
        firstProductImage: None,
      },
    )
  )
})
