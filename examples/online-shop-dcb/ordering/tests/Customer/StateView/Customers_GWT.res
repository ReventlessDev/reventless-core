@@reventless.gwt

describe("Customers StateViewSlice", () => {
  test("CustomerRegistered creates a row", () =>
    givenEvents([])
    ->whenEvent(CustomerRegistered({customerId: "c1", email: "alice@x.y", address: "123 Main"}))
    ->thenStateWithId(
      "c1",
      {customerId: "c1", email: "alice@x.y", address: "123 Main", deactivated: false},
    )
  )

  test("EmailChanged updates the email", () =>
    givenEvents([
      CustomerRegistered({customerId: "c1", email: "alice@x.y", address: "123 Main"}),
    ])
    ->whenEvent(EmailChanged({customerId: "c1", email: "alice2@x.y"}))
    ->thenStateWithId(
      "c1",
      {customerId: "c1", email: "alice2@x.y", address: "123 Main", deactivated: false},
    )
  )

  test("AddressChanged updates the address", () =>
    givenEvents([
      CustomerRegistered({customerId: "c1", email: "alice@x.y", address: "123 Main"}),
    ])
    ->whenEvent(AddressChanged({customerId: "c1", address: "789 Pine"}))
    ->thenStateWithId(
      "c1",
      {customerId: "c1", email: "alice@x.y", address: "789 Pine", deactivated: false},
    )
  )

  test("CustomerDeactivated sets deactivated flag", () =>
    givenEvents([
      CustomerRegistered({customerId: "c1", email: "alice@x.y", address: "123 Main"}),
    ])
    ->whenEvent(CustomerDeactivated({customerId: "c1"}))
    ->thenStateWithId(
      "c1",
      {customerId: "c1", email: "alice@x.y", address: "123 Main", deactivated: true},
    )
  )
})
