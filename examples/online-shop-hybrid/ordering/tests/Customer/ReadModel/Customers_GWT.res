@@reventless.gwt(Customers_Projections.CustomerMapping)

describe("Customers ReadModel ← Customer", () => {
  test("Registered sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Customer.Registered({email: "alice@x.y", address: "123 Main"}))
    ->thenState({Customers.email: "alice@x.y", address: "123 Main", deactivated: false})
  )

  test("EmailUpdated updates the email", () =>
    givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenEvent(Customer.EmailUpdated({email: "alice2@x.y"}))
    ->thenState({Customers.email: "alice2@x.y", address: "123 Main", deactivated: false})
  )

  test("AddressUpdated updates the address", () =>
    givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenEvent(Customer.AddressUpdated({address: "789 Pine"}))
    ->thenState({Customers.email: "alice@x.y", address: "789 Pine", deactivated: false})
  )

  test("Deactivated sets deactivated flag", () =>
    givenEvents([Customer.Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenEvent(Customer.Deactivated)
    ->thenState({Customers.email: "alice@x.y", address: "123 Main", deactivated: true})
  )
})
