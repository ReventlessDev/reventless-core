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

describe("CustomersView_Projection.project:", () => {
  test("CustomerRegistered creates new state", () =>
    expect(
      CustomersView_Projection.project(
        CustomersView.CustomerRegistered({
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
      CustomersView_Projection.project(
        CustomersView.EmailChanged({customerId: "cust-1", email: "alice2@example.com"}),
      )->applyFirstUpdate(baseCustomer),
    )->toEqual({...baseCustomer, email: "alice2@example.com"})
  )

  test("AddressChanged Update function changes address", () =>
    expect(
      CustomersView_Projection.project(
        CustomersView.AddressChanged({customerId: "cust-1", address: "789 Pine Rd"}),
      )->applyFirstUpdate(baseCustomer),
    )->toEqual({...baseCustomer, address: "789 Pine Rd"})
  )

  test("CustomerDeactivated Update function sets deactivated=true", () =>
    expect(
      CustomersView_Projection.project(
        CustomersView.CustomerDeactivated({customerId: "cust-1"}),
      )->applyFirstUpdate(baseCustomer),
    )->toEqual({...baseCustomer, deactivated: true})
  )
})
