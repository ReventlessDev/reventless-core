// Pure unit tests for Order StateChangeSlice decision logic.
// Tests reduce and decide functions for PlaceOrder, ShipOrder, and CancelOrder.

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

    test("Customer events do not change model", () =>
      expect(
        PlaceOrder.reduce(
          PlaceOrder.initialDecisionModel,
          OrderingEventLog.CustomerRegistered({
            customerId: "cust-1",
            email: "alice@example.com",
            address: "123 Main St",
          }),
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
  let placedModel: ShipOrder.decisionModel = {exists: true, shipped: false, cancelled: false}

  describe("reduce", () => {
    test("OrderPlaced sets exists=true", () =>
      expect(
        ShipOrder.reduce(
          ShipOrder.initialDecisionModel,
          OrderingEventLog.OrderPlaced({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1"],
          }),
        ),
      )->toEqual({ShipOrder.exists: true, shipped: false, cancelled: false})
    )

    test("OrderShipped sets shipped=true", () =>
      expect(
        ShipOrder.reduce(placedModel, OrderingEventLog.OrderShipped({orderId: "ord-1"})),
      )->toEqual({ShipOrder.exists: true, shipped: true, cancelled: false})
    )

    test("OrderCancelled sets cancelled=true", () =>
      expect(
        ShipOrder.reduce(placedModel, OrderingEventLog.OrderCancelled({orderId: "ord-1"})),
      )->toEqual({ShipOrder.exists: true, shipped: false, cancelled: true})
    )
  })

  describe("decide", () => {
    test("on non-existent order returns OrderNotFound", () =>
      expect(
        ShipOrder.decide(
          ShipOrder.initialDecisionModel,
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(ShipOrder.OrderNotFound))
    )

    test("on cancelled order returns OrderAlreadyCancelled", () =>
      expect(
        ShipOrder.decide(
          {...placedModel, cancelled: true},
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(ShipOrder.OrderAlreadyCancelled))
    )

    test("on already shipped order returns Ok([]) (idempotent)", () =>
      expect(
        ShipOrder.decide(
          {...placedModel, shipped: true},
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on placed order produces OrderShipped", () =>
      expect(
        ShipOrder.decide(placedModel, ShipOrder.ShipOrder({orderId: "ord-1"})),
      )->toEqual(Ok([OrderingEventLog.OrderShipped({orderId: "ord-1"})]))
    )
  })
})

describe("CancelOrder:", () => {
  let placedModel: CancelOrder.decisionModel = {exists: true, shipped: false, cancelled: false}

  describe("decide", () => {
    test("on non-existent order returns OrderNotFound", () =>
      expect(
        CancelOrder.decide(
          CancelOrder.initialDecisionModel,
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(CancelOrder.OrderNotFound))
    )

    test("on shipped order returns OrderAlreadyShipped", () =>
      expect(
        CancelOrder.decide(
          {...placedModel, shipped: true},
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(CancelOrder.OrderAlreadyShipped))
    )

    test("on already cancelled order returns Ok([]) (idempotent)", () =>
      expect(
        CancelOrder.decide(
          {...placedModel, cancelled: true},
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on placed order produces OrderCancelled", () =>
      expect(
        CancelOrder.decide(placedModel, CancelOrder.CancelOrder({orderId: "ord-1"})),
      )->toEqual(Ok([OrderingEventLog.OrderCancelled({orderId: "ord-1"})]))
    )
  })
})
