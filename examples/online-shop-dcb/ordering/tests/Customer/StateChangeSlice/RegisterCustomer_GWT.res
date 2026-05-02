@@reventless.gwt

describe("RegisterCustomer StateChangeSlice", () => {
  test("empty event log produces CustomerRegistered", () =>
    givenEvents([])
    ->whenCmd(
      RegisterCustomer({customerId: "c1", email: "alice@x.y", address: "123 Main"}),
    )
    ->thenEvent(
      CustomerRegistered({customerId: "c1", email: "alice@x.y", address: "123 Main"}),
    )
  )

  test("existing customer returns CustomerAlreadyRegistered", () =>
    givenEvents([CustomerRegistered])
    ->whenCmd(
      RegisterCustomer({customerId: "c1", email: "bob@x.y", address: "456 Oak"}),
    )
    ->thenError(CustomerAlreadyRegistered)
  )
})
