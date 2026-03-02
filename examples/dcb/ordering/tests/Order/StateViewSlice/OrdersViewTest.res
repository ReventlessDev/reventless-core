// Pure unit tests for OrdersView StateViewSlice projection.

open Reventless
open Jest
open Expect

let baseOrder: OrdersView.state = {
  orderId: "ord-1",
  customerId: "cust-1",
  productIds: ["prod-1"],
  status: "placed",
}

// Apply the first Update action's function to a base state for assertion.
let applyFirstUpdate = (actions, baseState) =>
  actions->Array.reduce(baseState, (s, action) =>
    switch action {
    | Projection.Update(_, fn) => fn(s)
    | _ => s
    })

describe("OrdersView.project:", () => {
  test("OrderPlaced creates new state", () =>
    expect(
      OrdersView.project(
        None,
        OrderingEventLog.OrderPlaced({
          orderId: "ord-1",
          customerId: "cust-1",
          productIds: ["prod-1"],
        }),
      ),
    )->toEqual([
      Projection.Set(
        "ord-1",
        {
          OrdersView.orderId: "ord-1",
          customerId: "cust-1",
          productIds: ["prod-1"],
          status: "placed",
        },
      ),
    ])
  )

  test("OrderShipped Update function sets status to shipped", () =>
    expect(
      OrdersView.project(None, OrderingEventLog.OrderShipped({orderId: "ord-1"}))
      ->applyFirstUpdate(baseOrder),
    )->toEqual({...baseOrder, status: "shipped"})
  )

  test("OrderCancelled Update function sets status to cancelled", () =>
    expect(
      OrdersView.project(
        None,
        OrderingEventLog.OrderCancelled({orderId: "ord-1", productIds: ["prod-1"]}),
      )
      ->applyFirstUpdate(baseOrder),
    )->toEqual({...baseOrder, status: "cancelled"})
  )

  test("Customer events return empty (not handled by OrdersView)", () =>
    expect(
      OrdersView.project(
        None,
        OrderingEventLog.CustomerRegistered({
          customerId: "cust-1",
          email: "alice@example.com",
          address: "123 Main St",
        }),
      ),
    )->toEqual([])
  )
})
