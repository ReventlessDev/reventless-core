@@reventless.gwt

describe("DeactivateCustomer StateChangeSlice", () => {
  test("non-existent customer returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(DeactivateCustomer({customerId: "c1"}))
    ->thenError(CustomerNotFound)
  )

  test("existing customer produces CustomerDeactivated", () =>
    givenEvents([CustomerRegistered])
    ->whenCmd(DeactivateCustomer({customerId: "c1"}))
    ->thenEvent(CustomerDeactivated({customerId: "c1"}))
  )

  test("already deactivated customer produces no events (idempotent)", () =>
    givenEvents([CustomerRegistered, CustomerDeactivated])
    ->whenCmd(DeactivateCustomer({customerId: "c1"}))
    ->thenNoEvent
  )
})
