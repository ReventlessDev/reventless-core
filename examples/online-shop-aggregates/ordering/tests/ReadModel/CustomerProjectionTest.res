// Unit tests for Customer projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

include ReventlessInMemory.ProjectionTest.Make(CustomersProjections.CustomerMapping)

describe("CustomerProjection:", () => {
  test("Registered sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(
      Customer.Registered({
        email: "alice@example.com",
        address: "123 Main St",
      }),
    )
    ->thenState({
      CustomersReadModel.email: "alice@example.com",
      address: "123 Main St",
      deactivated: false,
    })
  )

  test("EmailUpdated after registration updates email", () =>
    givenEvents([
      Customer.Registered({
        email: "alice@example.com",
        address: "123 Main St",
      }),
    ])
    ->whenEvent(Customer.EmailUpdated({email: "alice2@example.com"}))
    ->thenState({
      CustomersReadModel.email: "alice2@example.com",
      address: "123 Main St",
      deactivated: false,
    })
  )

  test("AddressUpdated after registration updates address", () =>
    givenEvents([
      Customer.Registered({
        email: "alice@example.com",
        address: "123 Main St",
      }),
    ])
    ->whenEvent(Customer.AddressUpdated({address: "789 Pine Rd"}))
    ->thenState({
      CustomersReadModel.email: "alice@example.com",
      address: "789 Pine Rd",
      deactivated: false,
    })
  )

  test("Deactivated after registration sets deactivated flag", () =>
    givenEvents([
      Customer.Registered({
        email: "alice@example.com",
        address: "123 Main St",
      }),
    ])
    ->whenEvent(Customer.Deactivated)
    ->thenState({
      CustomersReadModel.email: "alice@example.com",
      address: "123 Main St",
      deactivated: true,
    })
  )
})
