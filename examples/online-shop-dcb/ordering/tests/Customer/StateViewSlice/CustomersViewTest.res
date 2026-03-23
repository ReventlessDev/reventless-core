// Pure unit tests for CustomersView StateViewSlice projection.

open Reventless
open Jest
open Expect

let baseCustomer: CustomersView.state = {
  customerId: "cust-1",
  email: "alice@example.com",
  address: "123 Main St",
  deactivated: false,
}

// Apply the first Update action's function to a base state for assertion.
let applyFirstUpdate = (actions, baseState) =>
  actions->Array.reduce(baseState, (s, action) =>
    switch action {
    | Projection.Update(_, fn) => fn(s)
    | _ => s
    })

describe("CustomersView.project:", () => {
  test("CustomerRegistered creates new state", () =>
    expect(
      CustomersView.project(
        OrderingEventLog.CustomerRegistered({
          customerId: "cust-1",
          email: "alice@example.com",
          address: "123 Main St",
        }),
      ),
    )->toEqual([
      Projection.Set(
        "cust-1",
        {
          CustomersView.customerId: "cust-1",
          email: "alice@example.com",
          address: "123 Main St",
          deactivated: false,
        },
      ),
    ])
  )

  test("EmailChanged Update function changes email", () =>
    expect(
      CustomersView.project(
        OrderingEventLog.EmailChanged({customerId: "cust-1", email: "alice2@example.com"}),
      )->applyFirstUpdate(baseCustomer),
    )->toEqual({...baseCustomer, email: "alice2@example.com"})
  )

  test("AddressChanged Update function changes address", () =>
    expect(
      CustomersView.project(
        OrderingEventLog.AddressChanged({customerId: "cust-1", address: "789 Pine Rd"}),
      )->applyFirstUpdate(baseCustomer),
    )->toEqual({...baseCustomer, address: "789 Pine Rd"})
  )

  test("CustomerDeactivated Update function sets deactivated=true", () =>
    expect(
      CustomersView.project(
        OrderingEventLog.CustomerDeactivated({customerId: "cust-1"}),
      )->applyFirstUpdate(baseCustomer),
    )->toEqual({...baseCustomer, deactivated: true})
  )

  test("Order events return empty (not handled by CustomersView)", () =>
    expect(
      CustomersView.project(
        OrderingEventLog.OrderPlaced({
          orderId: "ord-1",
          customerId: "cust-1",
          productIds: ["prod-1"],
        }),
      ),
    )->toEqual([])
  )
})
