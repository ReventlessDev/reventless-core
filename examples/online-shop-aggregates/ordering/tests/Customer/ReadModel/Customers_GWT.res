@@reventless.gwt(Customers_Projections.CustomerMapping)

describe("Customers ReadModel ← Customer", () => {
  test("Registered sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Customer.Registered({email: "alice@example.com", address: "123 Main St"}))
    ->thenState({Customers.email: "alice@example.com", address: "123 Main St", deactivated: false})
  )

  test("EmailUpdated updates the email", () =>
    givenEvents([Customer.Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenEvent(Customer.EmailUpdated({email: "alice2@example.com"}))
    ->thenState({Customers.email: "alice2@example.com", address: "123 Main St", deactivated: false})
  )

  test("AddressUpdated updates the address", () =>
    givenEvents([Customer.Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenEvent(Customer.AddressUpdated({address: "789 Pine Rd"}))
    ->thenState({Customers.email: "alice@example.com", address: "789 Pine Rd", deactivated: false})
  )

  test("Deactivated sets deactivated flag", () =>
    givenEvents([Customer.Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenEvent(Customer.Deactivated)
    ->thenState({Customers.email: "alice@example.com", address: "123 Main St", deactivated: true})
  )
})
