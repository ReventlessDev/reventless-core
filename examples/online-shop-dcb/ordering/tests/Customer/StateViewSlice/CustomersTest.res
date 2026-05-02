// Pure unit tests for Customers StateViewSlice projection.

open Reventless
open Jest
open Expect

let baseCustomer: Customers.state = {
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

describe("Customers_Projection.project:", () => {
  test("CustomerRegistered creates new state", () =>
    expect(
      Customers_Projection.project(
        Customers.CustomerRegistered({
          customerId: "cust-1",
          email: "alice@example.com",
          address: "123 Main St",
        }),
      ),
    )->toEqual([
      Projection.Set(
        "cust-1",
        {
          Customers.customerId: "cust-1",
          email: "alice@example.com",
          address: "123 Main St",
          deactivated: false,
        },
      ),
    ])
  )

  test("EmailChanged Update function changes email", () =>
    expect(
      Customers_Projection.project(
        Customers.EmailChanged({customerId: "cust-1", email: "alice2@example.com"}),
      )->applyFirstUpdate(baseCustomer),
    )->toEqual({...baseCustomer, email: "alice2@example.com"})
  )

  test("AddressChanged Update function changes address", () =>
    expect(
      Customers_Projection.project(
        Customers.AddressChanged({customerId: "cust-1", address: "789 Pine Rd"}),
      )->applyFirstUpdate(baseCustomer),
    )->toEqual({...baseCustomer, address: "789 Pine Rd"})
  )

  test("CustomerDeactivated Update function sets deactivated=true", () =>
    expect(
      Customers_Projection.project(
        Customers.CustomerDeactivated({customerId: "cust-1"}),
      )->applyFirstUpdate(baseCustomer),
    )->toEqual({...baseCustomer, deactivated: true})
  )
})
