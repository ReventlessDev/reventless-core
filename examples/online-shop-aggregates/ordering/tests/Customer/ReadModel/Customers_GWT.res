@@reventless.gwt(Customers_Projections.CustomerMapping)

describe("Customers ReadModel ← Customer", () => {
  // scenario-id: d64df451-1238-400b-b146-4bd84dfb232b
  test("Registered sets initial read model state", () =>
    givenEvents([])
    ->whenEvent(Customer.Registered({email: "alice@example.com", address: "123 Main St"}))
    ->thenState({Customers.email: "alice@example.com", address: "123 Main St", deactivated: false})
  )

  // scenario-id: 80d62196-a14f-4da6-9993-384996b0be93
  test("EmailUpdated updates the email", () =>
    givenEvents([Customer.Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenEvent(Customer.EmailUpdated({email: "alice2@example.com"}))
    ->thenState({Customers.email: "alice2@example.com", address: "123 Main St", deactivated: false})
  )

  // scenario-id: 55ce1763-d498-440d-8c19-2dc8adfa69e2
  test("AddressUpdated updates the address", () =>
    givenEvents([Customer.Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenEvent(Customer.AddressUpdated({address: "789 Pine Rd"}))
    ->thenState({Customers.email: "alice@example.com", address: "789 Pine Rd", deactivated: false})
  )

  // scenario-id: 9885a011-7448-431f-ae96-629aae5f9823
  test("Deactivated sets deactivated flag", () =>
    givenEvents([Customer.Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenEvent(Customer.Deactivated)
    ->thenState({Customers.email: "alice@example.com", address: "123 Main St", deactivated: true})
  )
})
