// Pure unit tests for Order StateChangeSlice decision logic.
// Tests evolve and decide functions for PlaceOrder, ShipOrder, and CancelOrder.

open Jest
open Expect

describe("PlaceOrder:", () => {
  describe("evolve", () => {
    test("OrderPlaced sets exists=true", () =>
      expect(
        PlaceOrder_Behavior.evolve(
          PlaceOrder_Behavior.initialState,
          PlaceOrder.OrderPlaced,
        ),
      )->toEqual({PlaceOrder_Behavior.exists: true})
    )
  })

  describe("decide", () => {
    test("on non-existent order produces OrderPlaced", () =>
      expect(
        PlaceOrder_Behavior.decide(
          PlaceOrder_Behavior.initialState,
          PlaceOrder.PlaceOrder({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1", "prod-2"],
          }),
        ),
      )->toEqual(
        Ok([
          PlaceOrder.OrderPlaced({
            orderId: "ord-1",
            customerId: "cust-1",
            productIds: ["prod-1", "prod-2"],
          }),
        ]),
      )
    )

    test("on existing order returns OrderAlreadyPlaced", () =>
      expect(
        PlaceOrder_Behavior.decide(
          {PlaceOrder_Behavior.exists: true},
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
  let placedState: ShipOrder_Behavior.state = {exists: true, shipped: false, cancelled: false}

  describe("evolve", () => {
    test("OrderPlaced sets exists=true", () =>
      expect(
        ShipOrder_Behavior.evolve(
          ShipOrder_Behavior.initialState,
          ShipOrder.OrderPlaced,
        ),
      )->toEqual({ShipOrder_Behavior.exists: true, shipped: false, cancelled: false})
    )

    test("OrderShipped sets shipped=true", () =>
      expect(
        ShipOrder_Behavior.evolve(placedState, ShipOrder.OrderShipped),
      )->toEqual({ShipOrder_Behavior.exists: true, shipped: true, cancelled: false})
    )

    test("OrderCancelled sets cancelled=true", () =>
      expect(
        ShipOrder_Behavior.evolve(placedState, ShipOrder.OrderCancelled),
      )->toEqual({ShipOrder_Behavior.exists: true, shipped: false, cancelled: true})
    )
  })

  describe("decide", () => {
    test("on non-existent order returns OrderNotFound", () =>
      expect(
        ShipOrder_Behavior.decide(
          ShipOrder_Behavior.initialState,
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(ShipOrder.OrderNotFound))
    )

    test("on cancelled order returns OrderAlreadyCancelled", () =>
      expect(
        ShipOrder_Behavior.decide(
          {...placedState, cancelled: true},
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(ShipOrder.OrderAlreadyCancelled))
    )

    test("on already shipped order returns Ok([]) (idempotent)", () =>
      expect(
        ShipOrder_Behavior.decide(
          {...placedState, shipped: true},
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on placed order produces OrderShipped", () =>
      expect(
        ShipOrder_Behavior.decide(placedState, ShipOrder.ShipOrder({orderId: "ord-1"})),
      )->toEqual(Ok([ShipOrder.OrderShipped({orderId: "ord-1"})]))
    )
  })
})

describe("CancelOrder:", () => {
  let placedState: CancelOrder_Behavior.state = {
    exists: true,
    shipped: false,
    cancelled: false,
    productIds: ["prod-1"],
  }

  describe("decide", () => {
    test("on non-existent order returns OrderNotFound", () =>
      expect(
        CancelOrder_Behavior.decide(
          CancelOrder_Behavior.initialState,
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(CancelOrder.OrderNotFound))
    )

    test("on shipped order returns OrderAlreadyShipped", () =>
      expect(
        CancelOrder_Behavior.decide(
          {...placedState, shipped: true},
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(CancelOrder.OrderAlreadyShipped))
    )

    test("on already cancelled order returns Ok([]) (idempotent)", () =>
      expect(
        CancelOrder_Behavior.decide(
          {...placedState, cancelled: true},
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on placed order produces OrderCancelled", () =>
      expect(
        CancelOrder_Behavior.decide(placedState, CancelOrder.CancelOrder({orderId: "ord-1"})),
      )->toEqual(
        Ok([CancelOrder.OrderCancelled({orderId: "ord-1", productIds: ["prod-1"]})]),
      )
    )
  })
})
