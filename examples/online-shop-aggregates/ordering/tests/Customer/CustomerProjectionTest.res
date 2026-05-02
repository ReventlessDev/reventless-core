// Unit tests for Customer projection mappings.
// Uses the ProjectionTest DSL for async projection testing.

include ReventlessGwt.MultiSourceProjection_GWT.Make(Customers_Projections.CustomerMapping)

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
      Customers.email: "alice@example.com",
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
      Customers.email: "alice2@example.com",
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
      Customers.email: "alice@example.com",
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
      Customers.email: "alice@example.com",
      address: "123 Main St",
      deactivated: true,
    })
  )
})
