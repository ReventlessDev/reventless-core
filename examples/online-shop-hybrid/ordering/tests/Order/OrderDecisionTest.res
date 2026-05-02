// Pure unit tests for Order StateChangeSlice decision logic.
// Tests PlaceOrder, ShipOrder, CancelOrder evolve and decide functions.

open Jest
open Expect

describe("PlaceOrder:", () => {
  let withProducts = (productIds): PlaceOrder_Behavior.state => {
    let s = Set.make()
    productIds->Array.forEach(id => s->Set.add(id))
    {placedOrderIds: Set.make(), availableProductIds: s}
  }

  describe("evolve", () => {
    test(
      "OrderPlaced records the orderId in placedOrderIds",
      () => {
        let state = PlaceOrder_Behavior.evolve(
          withProducts(["prod-1"]),
          PlaceOrder.OrderPlaced({orderId: "ord-1"}),
        )
        expect(state.placedOrderIds->Set.has("ord-1"))->toBe(true)
      },
    )

    test(
      "CatalogProductSynced adds to availableProductIds",
      () => {
        let state = PlaceOrder_Behavior.evolve(
          PlaceOrder_Behavior.initialState,
          PlaceOrder.CatalogProductSynced({productId: "prod-1"}),
        )
        expect(state.availableProductIds->Set.has("prod-1"))->toBe(true)
      },
    )
  })

  describe("decide", () => {
    test(
      "with available products produces OrderPlaced",
      () =>
        expect(
          PlaceOrder_Behavior.decide(
            withProducts(["prod-1", "prod-2"]),
            PlaceOrder.PlaceOrder({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1", "prod-2"],
            }),
          ),
        )->toEqual(
          Ok([
            PlaceOrder.OrderPlaced({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1", "prod-2"],
            }),
          ]),
        ),
    )

    test(
      "with missing products returns ProductsNotAvailable",
      () =>
        expect(
          PlaceOrder_Behavior.decide(
            withProducts(["prod-1"]),
            PlaceOrder.PlaceOrder({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1", "prod-2"],
            }),
          ),
        )->toEqual(Error(PlaceOrder.ProductsNotAvailable({missing: ["prod-2"]}))),
    )

    test(
      "on existing order returns OrderAlreadyPlaced",
      () => {
        let state = withProducts(["prod-1"])
        state.placedOrderIds->Set.add("ord-1")
        expect(
          PlaceOrder_Behavior.decide(
            state,
            PlaceOrder.PlaceOrder({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1"],
            }),
          ),
        )->toEqual(Error(PlaceOrder.OrderAlreadyPlaced))
      },
    )

    test(
      "OrderPlaced from a sibling order does not block this order",
      () => {
        // Regression: the multi-clause query also fetches OrderPlaced events
        // from sibling orders that share a productId. They must not falsely
        // mark "this order exists".
        let state = withProducts(["prod-1"])
        state.placedOrderIds->Set.add("ord-other")
        expect(
          PlaceOrder_Behavior.decide(
            state,
            PlaceOrder.PlaceOrder({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1"],
            }),
          ),
        )->toEqual(
          Ok([
            PlaceOrder.OrderPlaced({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1"],
            }),
          ]),
        )
      },
    )
  })
})

describe("ShipOrder:", () => {
  describe("decide", () => {
    test(
      "on non-existent order returns OrderNotFound",
      () =>
        expect(
          ShipOrder_Behavior.decide(ShipOrder_Behavior.initialState, ShipOrder.ShipOrder({orderId: "ord-1"})),
        )->toEqual(Error(ShipOrder.OrderNotFound)),
    )

    test(
      "on placed order produces OrderShipped",
      () =>
        expect(
          ShipOrder_Behavior.decide(
            {ShipOrder_Behavior.exists: true, shipped: false, cancelled: false},
            ShipOrder.ShipOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Ok([ShipOrder.OrderShipped({orderId: "ord-1"})])),
    )

    test(
      "on shipped order is idempotent (no events)",
      () =>
        expect(
          ShipOrder_Behavior.decide(
            {ShipOrder_Behavior.exists: true, shipped: true, cancelled: false},
            ShipOrder.ShipOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Ok([])),
    )

    test(
      "on cancelled order returns OrderAlreadyCancelled",
      () =>
        expect(
          ShipOrder_Behavior.decide(
            {ShipOrder_Behavior.exists: true, shipped: false, cancelled: true},
            ShipOrder.ShipOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Error(ShipOrder.OrderAlreadyCancelled)),
    )
  })
})

describe("CancelOrder:", () => {
  describe("decide", () => {
    test(
      "on non-existent order returns OrderNotFound",
      () =>
        expect(
          CancelOrder_Behavior.decide(
            CancelOrder_Behavior.initialState,
            CancelOrder.CancelOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Error(CancelOrder.OrderNotFound)),
    )

    test(
      "on placed order produces OrderCancelled with productIds",
      () =>
        expect(
          CancelOrder_Behavior.decide(
            {CancelOrder_Behavior.exists: true, shipped: false, cancelled: false, productId: ["prod-1"]},
            CancelOrder.CancelOrder({orderId: "ord-1"}),
          ),
        )->toEqual(
          Ok([CancelOrder.OrderCancelled({orderId: "ord-1", productId: ["prod-1"]})]),
        ),
    )

    test(
      "on cancelled order is idempotent (no events)",
      () =>
        expect(
          CancelOrder_Behavior.decide(
            {CancelOrder_Behavior.exists: true, shipped: false, cancelled: true, productId: ["prod-1"]},
            CancelOrder.CancelOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Ok([])),
    )

    test(
      "on shipped order returns OrderAlreadyShipped",
      () =>
        expect(
          CancelOrder_Behavior.decide(
            {CancelOrder_Behavior.exists: true, shipped: true, cancelled: false, productId: ["prod-1"]},
            CancelOrder.CancelOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Error(CancelOrder.OrderAlreadyShipped)),
    )
  })
})
