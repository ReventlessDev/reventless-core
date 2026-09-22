@@reventless.gwt

open OrderingExamples

describe("RegisterCustomer StateChangeSlice", () => {
  // scenario-id: fd616ac0-6ee3-47ef-b74f-212a7befac4a
  test("empty event log produces CustomerRegistered", () =>
    givenEvents([])
    ->whenCmd(RegisterCustomer({customerId: c1, email: aliceEmail, address: mainStreet}))
    ->thenEvent(CustomerRegistered({customerId: c1, email: aliceEmail, address: mainStreet}))
  )

  // scenario-id: d99db741-d659-456e-b84f-9af30a7d8a41
  test("existing customer returns CustomerAlreadyRegistered", () =>
    givenEvents([CustomerRegistered])
    ->whenCmd(RegisterCustomer({customerId: c1, email: "bob@x.y", address: "456 Oak"}))
    ->thenError(CustomerAlreadyRegistered)
  )
})
