@@reventless.gwt

open Ordering_Examples

describe("Customers StateViewSlice", () => {
  // scenario-id: 56a23bc7-31ce-4e9c-a7f1-d523e75aefba
  test("CustomerRegistered creates a row", () =>
    givenEvents([])
    ->whenEvent(CustomerRegistered({customerId: c1, email: aliceEmail, address: mainStreet}))
    ->thenStateWithId(
      "c1",
      {customerId: c1, email: aliceEmail, address: mainStreet, deactivated: false},
    )
  )

  // scenario-id: 941f8ba9-3740-49f7-bb3a-e3aca90f10bf
  test("EmailChanged updates the email", () =>
    givenEvents([CustomerRegistered({customerId: c1, email: aliceEmail, address: mainStreet})])
    ->whenEvent(EmailChanged({customerId: c1, email: aliceNewEmail}))
    ->thenStateWithId(
      "c1",
      {customerId: c1, email: aliceNewEmail, address: mainStreet, deactivated: false},
    )
  )

  // scenario-id: 778d3e61-2b9b-4f55-a4ca-57f5e476a09b
  test("AddressChanged updates the address", () =>
    givenEvents([CustomerRegistered({customerId: c1, email: aliceEmail, address: mainStreet})])
    ->whenEvent(AddressChanged({customerId: c1, address: pineStreet}))
    ->thenStateWithId(
      "c1",
      {customerId: c1, email: aliceEmail, address: pineStreet, deactivated: false},
    )
  )

  // scenario-id: 783d84a5-3b4d-41df-bf3c-abaa9c717bd7
  test("CustomerDeactivated sets deactivated flag", () =>
    givenEvents([CustomerRegistered({customerId: c1, email: aliceEmail, address: mainStreet})])
    ->whenEvent(CustomerDeactivated({customerId: c1}))
    ->thenStateWithId(
      "c1",
      {customerId: c1, email: aliceEmail, address: mainStreet, deactivated: true},
    )
  )
})
