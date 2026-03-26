// Pure unit tests for Order StateChangeSlice decision logic.
// Tests evolve and decide functions for PlaceOrder, ShipOrder, and CancelOrder.

open Jest
open Expect

describe("PlaceOrder:", () => {
  describe("evolve", () => {
    test("OrderPlaced sets exists=true", () =>
      expect(
        PlaceOrder.evolve(
          PlaceOrder.initialState,
          PlaceOrder.OrderPlaced,
        ),
      )->toEqual({PlaceOrder.exists: true})
    )
  })

  describe("decide", () => {
    test("on non-existent order produces OrderPlaced", () =>
      expect(
        PlaceOrder.decide(
          PlaceOrder.initialState,
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
  let placedState: ShipOrder.state = {exists: true, shipped: false, cancelled: false}

  describe("evolve", () => {
    test("OrderPlaced sets exists=true", () =>
      expect(
        ShipOrder.evolve(
          ShipOrder.initialState,
          ShipOrder.OrderPlaced,
        ),
      )->toEqual({ShipOrder.exists: true, shipped: false, cancelled: false})
    )

    test("OrderShipped sets shipped=true", () =>
      expect(
        ShipOrder.evolve(placedState, ShipOrder.OrderShipped),
      )->toEqual({ShipOrder.exists: true, shipped: true, cancelled: false})
    )

    test("OrderCancelled sets cancelled=true", () =>
      expect(
        ShipOrder.evolve(placedState, ShipOrder.OrderCancelled),
      )->toEqual({ShipOrder.exists: true, shipped: false, cancelled: true})
    )
  })

  describe("decide", () => {
    test("on non-existent order returns OrderNotFound", () =>
      expect(
        ShipOrder.decide(
          ShipOrder.initialState,
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(ShipOrder.OrderNotFound))
    )

    test("on cancelled order returns OrderAlreadyCancelled", () =>
      expect(
        ShipOrder.decide(
          {...placedState, cancelled: true},
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(ShipOrder.OrderAlreadyCancelled))
    )

    test("on already shipped order returns Ok([]) (idempotent)", () =>
      expect(
        ShipOrder.decide(
          {...placedState, shipped: true},
          ShipOrder.ShipOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on placed order produces OrderShipped", () =>
      expect(
        ShipOrder.decide(placedState, ShipOrder.ShipOrder({orderId: "ord-1"})),
      )->toEqual(Ok([ShipOrder.OrderShipped({orderId: "ord-1"})]))
    )
  })
})

describe("CancelOrder:", () => {
  let placedState: CancelOrder.state = {
    exists: true,
    shipped: false,
    cancelled: false,
    productIds: ["prod-1"],
  }

  describe("decide", () => {
    test("on non-existent order returns OrderNotFound", () =>
      expect(
        CancelOrder.decide(
          CancelOrder.initialState,
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(CancelOrder.OrderNotFound))
    )

    test("on shipped order returns OrderAlreadyShipped", () =>
      expect(
        CancelOrder.decide(
          {...placedState, shipped: true},
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Error(CancelOrder.OrderAlreadyShipped))
    )

    test("on already cancelled order returns Ok([]) (idempotent)", () =>
      expect(
        CancelOrder.decide(
          {...placedState, cancelled: true},
          CancelOrder.CancelOrder({orderId: "ord-1"}),
        ),
      )->toEqual(Ok([]))
    )

    test("on placed order produces OrderCancelled", () =>
      expect(
        CancelOrder.decide(placedState, CancelOrder.CancelOrder({orderId: "ord-1"})),
      )->toEqual(
        Ok([CancelOrder.OrderCancelled({orderId: "ord-1", productIds: ["prod-1"]})]),
      )
    )
  })
})
