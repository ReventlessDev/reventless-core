// Pure unit tests for Orders StateViewSlice projection.

open Reventless
open Jest
open Expect

let baseOrder: Orders.state = {
  orderId: "ord-1",
  customerId: "cust-1",
  productIds: ["prod-1"],
  status: Placed,
}

// Apply the first Update action's function to a base state for assertion.
let applyFirstUpdate = (actions, baseState) =>
  actions->Array.reduce(baseState, (s, action) =>
    switch action {
    | Projection.Update(_, fn) => fn(s)
    | _ => s
    })

describe("Orders_Projection.project:", () => {
  test("OrderPlaced creates new state", () =>
    expect(
      Orders_Projection.project(
        Orders.OrderPlaced({
          orderId: "ord-1",
          customerId: "cust-1",
          productIds: ["prod-1"],
        }),
      ),
    )->toEqual([
      Projection.Set(
        "ord-1",
        {
          Orders.orderId: "ord-1",
          customerId: "cust-1",
          productIds: ["prod-1"],
          status: Placed,
        },
      ),
    ])
  )

  test("OrderShipped Update function sets status to shipped", () =>
    expect(
      Orders_Projection.project(Orders.OrderShipped({orderId: "ord-1"}))
      ->applyFirstUpdate(baseOrder),
    )->toEqual({...baseOrder, status: Shipped})
  )

  test("OrderCancelled Update function sets status to cancelled", () =>
    expect(
      Orders_Projection.project(
        Orders.OrderCancelled({orderId: "ord-1"}),
      )
      ->applyFirstUpdate(baseOrder),
    )->toEqual({...baseOrder, status: Cancelled})
  )
})
