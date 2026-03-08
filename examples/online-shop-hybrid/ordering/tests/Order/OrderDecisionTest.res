// Pure unit tests for Order StateChangeSlice decision logic.
// Tests PlaceOrder, ShipOrder, CancelOrder.

open Jest
open Expect

describe("PlaceOrder:", () => {
  let withProducts = productIds => {
    let s = Set.make()
    productIds->Array.forEach(id => s->Set.add(id))
    {PlaceOrder.exists: false, availableProductIds: s}
  }

  describe("reduce", () => {
    test(
      "OrderPlaced sets exists=true",
      () => {
        let model = PlaceOrder.reduce(
          withProducts(["prod-1"]),
          OrderingEventLog.OrderPlaced({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1"],
          }),
        )
        expect(model.exists)->toBe(true)
      },
    )

    test(
      "CatalogProductSynced adds to availableProductIds",
      () => {
        let model = PlaceOrder.reduce(
          PlaceOrder.initialDecisionModel,
          OrderingEventLog.CatalogProductSynced({
            productId: "prod-1",
            name: "Widget",
            price: 9.99,
          }),
        )
        expect(model.availableProductIds->Set.has("prod-1"))->toBe(true)
      },
    )

    test(
      "other events do not change model",
      () => {
        let model = PlaceOrder.reduce(
          PlaceOrder.initialDecisionModel,
          OrderingEventLog.OrderShipped({orderId: "ord-1"}),
        )
        expect(model.exists)->toBe(false)
      },
    )
  })

  describe("decide", () => {
    test(
      "with available products produces OrderPlaced",
      () =>
        expect(
          PlaceOrder.decide(
            withProducts(["prod-1", "prod-2"]),
            PlaceOrder.PlaceOrder({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1", "prod-2"],
            }),
          ),
        )->toEqual(
          Ok([
            OrderingEventLog.OrderPlaced({
              orderId: "ord-1",
              customerId: "cust-1",
              productIds: ["prod-1", "prod-2"],
            }),
          ]),
        ),
    )

    test(
      "with missing products returns ProductsNotAvailable",
      () =>
        expect(
          PlaceOrder.decide(
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
        let model = withProducts(["prod-1"])
        expect(
          PlaceOrder.decide(
            {...model, exists: true},
            PlaceOrder.PlaceOrder({
              orderId: "ord-1",
              customerId: "cust-1",
              productId: ["prod-1"],
            }),
          ),
        )->toEqual(Error(PlaceOrder.OrderAlreadyPlaced))
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
          ShipOrder.decide(ShipOrder.initialDecisionModel, ShipOrder.ShipOrder({orderId: "ord-1"})),
        )->toEqual(Error(ShipOrder.OrderNotFound)),
    )

    test(
      "on placed order produces OrderShipped",
      () =>
        expect(
          ShipOrder.decide(
            {ShipOrder.exists: true, shipped: false, cancelled: false},
            ShipOrder.ShipOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Ok([OrderingEventLog.OrderShipped({orderId: "ord-1"})])),
    )

    test(
      "on shipped order is idempotent (no events)",
      () =>
        expect(
          ShipOrder.decide(
            {ShipOrder.exists: true, shipped: true, cancelled: false},
            ShipOrder.ShipOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Ok([])),
    )

    test(
      "on cancelled order returns OrderAlreadyCancelled",
      () =>
        expect(
          ShipOrder.decide(
            {ShipOrder.exists: true, shipped: false, cancelled: true},
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
          CancelOrder.decide(
            CancelOrder.initialDecisionModel,
            CancelOrder.CancelOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Error(CancelOrder.OrderNotFound)),
    )

    test(
      "on placed order produces OrderCancelled with productIds",
      () =>
        expect(
          CancelOrder.decide(
            {CancelOrder.exists: true, shipped: false, cancelled: false, productIds: ["prod-1"]},
            CancelOrder.CancelOrder({orderId: "ord-1"}),
          ),
        )->toEqual(
          Ok([OrderingEventLog.OrderCancelled({orderId: "ord-1", productIds: ["prod-1"]})]),
        ),
    )

    test(
      "on cancelled order is idempotent (no events)",
      () =>
        expect(
          CancelOrder.decide(
            {CancelOrder.exists: true, shipped: false, cancelled: true, productIds: ["prod-1"]},
            CancelOrder.CancelOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Ok([])),
    )

    test(
      "on shipped order returns OrderAlreadyShipped",
      () =>
        expect(
          CancelOrder.decide(
            {CancelOrder.exists: true, shipped: true, cancelled: false, productIds: ["prod-1"]},
            CancelOrder.CancelOrder({orderId: "ord-1"}),
          ),
        )->toEqual(Error(CancelOrder.OrderAlreadyShipped)),
    )
  })
})
