// Unit tests for Customer projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

include ReventlessInMemory.ProjectionTest.Make(CustomersProjections.CustomerMapping)

describe("CustomerProjection:", () => {
  test("CustomerRegistered sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(
      Customer.CustomerRegistered({
        customerId: "cust-1",
        email: "alice@example.com",
        address: "123 Main St",
      }),
    )
    ->thenState({
      CustomersReadModel.customerId: "cust-1",
      email: "alice@example.com",
      address: "123 Main St",
      deactivated: false,
    })
  )

  test("EmailUpdated after registration updates email", () =>
    givenEvents([
      Customer.CustomerRegistered({
        customerId: "cust-1",
        email: "alice@example.com",
        address: "123 Main St",
      }),
    ])
    ->whenEvent(Customer.EmailUpdated({customerId: "cust-1", email: "alice2@example.com"}))
    ->thenState({
      CustomersReadModel.customerId: "cust-1",
      email: "alice2@example.com",
      address: "123 Main St",
      deactivated: false,
    })
  )

  test("AddressUpdated after registration updates address", () =>
    givenEvents([
      Customer.CustomerRegistered({
        customerId: "cust-1",
        email: "alice@example.com",
        address: "123 Main St",
      }),
    ])
    ->whenEvent(Customer.AddressUpdated({customerId: "cust-1", address: "789 Pine Rd"}))
    ->thenState({
      CustomersReadModel.customerId: "cust-1",
      email: "alice@example.com",
      address: "789 Pine Rd",
      deactivated: false,
    })
  )

  test("CustomerDeactivated after registration sets deactivated flag", () =>
    givenEvents([
      Customer.CustomerRegistered({
        customerId: "cust-1",
        email: "alice@example.com",
        address: "123 Main St",
      }),
    ])
    ->whenEvent(Customer.CustomerDeactivated({customerId: "cust-1"}))
    ->thenState({
      CustomersReadModel.customerId: "cust-1",
      email: "alice@example.com",
      address: "123 Main St",
      deactivated: true,
    })
  )
})
