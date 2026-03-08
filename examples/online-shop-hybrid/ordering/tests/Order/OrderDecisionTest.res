// Pure unit tests for Order StateChangeSlice decision logic.
// Tests PlaceOrder, ShipOrder, CancelOrder.

open Jest
open Expect

describe("PlaceOrder:", () => {
  describe("reduce", () => {
    test("OrderPlaced sets exists=true", () =>
      expect(
        PlaceOrder.reduce(
          PlaceOrder.initialDecisionModel,
          OrderingEventLog.OrderPlaced({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1"],
          }),
        ),
      )->toEqual({PlaceOrder.exists: true})
    )

    test("other events do not change model", () =>
      expect(
        PlaceOrder.reduce(
          PlaceOrder.initialDecisionModel,
          OrderingEventLog.OrderShipped({orderId: "ord-1"}),
        ),
      )->toEqual(PlaceOrder.initialDecisionModel)
    )
  })

  describe("decide", () => {
    test("on non-existent order produces OrderPlaced", () =>
      expect(
        PlaceOrder.decide(
          PlaceOrder.initialDecisionModel,
          PlaceOrder.PlaceOrder({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1", "prod-2"],
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
      )
    )

    test("on existing order returns OrderAlreadyPlaced", () =>
      expect(
        PlaceOrder.decide(
          {PlaceOrder.exists: true},
          PlaceOrder.PlaceOrder({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1"],
          }),
        ),
      )->toEqual(Error(PlaceOrder.OrderAlreadyPlaced))
    )
  })
})

describe("ShipOrder:", () => {
  describe("decide", () => {
    test("on non-existent order returns OrderNotFound", () =>
      expect(
        ShipOrder.decide(
          ShipOrder.initialDecisionModel,
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(ShipOrder.OrderNotFound))
    )

    test("on placed order produces OrderShipped", () =>
      expect(
        ShipOrder.decide(
          {ShipOrder.exists: true, shipped: false, cancelled: false},
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Ok([OrderingEventLog.OrderShipped({orderId: "ord-1"})]))
    )

    test("on shipped order is idempotent (no events)", () =>
      expect(
        ShipOrder.decide(
          {ShipOrder.exists: true, shipped: true, cancelled: false},
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on cancelled order returns OrderAlreadyCancelled", () =>
      expect(
        ShipOrder.decide(
          {ShipOrder.exists: true, shipped: false, cancelled: true},
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(ShipOrder.OrderAlreadyCancelled))
    )
  })
})

describe("CancelOrder:", () => {
  describe("decide", () => {
    test("on non-existent order returns OrderNotFound", () =>
      expect(
        CancelOrder.decide(
          CancelOrder.initialDecisionModel,
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(CancelOrder.OrderNotFound))
    )

    test("on placed order produces OrderCancelled with productIds", () =>
      expect(
        CancelOrder.decide(
          {CancelOrder.exists: true, shipped: false, cancelled: false, productIds: ["prod-1"]},
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(
        Ok([OrderingEventLog.OrderCancelled({orderId: "ord-1", productIds: ["prod-1"]})]),
      )
    )

    test("on cancelled order is idempotent (no events)", () =>
      expect(
        CancelOrder.decide(
          {CancelOrder.exists: true, shipped: false, cancelled: true, productIds: ["prod-1"]},
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on shipped order returns OrderAlreadyShipped", () =>
      expect(
        CancelOrder.decide(
          {CancelOrder.exists: true, shipped: true, cancelled: false, productIds: ["prod-1"]},
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(CancelOrder.OrderAlreadyShipped))
    )
  })
})
