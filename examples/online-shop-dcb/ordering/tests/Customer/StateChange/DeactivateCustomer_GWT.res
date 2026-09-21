@@reventless.gwt

let cid = CustomerId.make

describe("DeactivateCustomer StateChangeSlice", () => {
  test("non-existent customer returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(DeactivateCustomer({customerId: cid("c1")}))
    ->thenError(CustomerNotFound)
  )

  test("existing customer produces CustomerDeactivated", () =>
    givenEvents([CustomerRegistered])
    ->whenCmd(DeactivateCustomer({customerId: cid("c1")}))
    ->thenEvent(CustomerDeactivated({customerId: cid("c1")}))
  )

  test("already deactivated customer produces no events (idempotent)", () =>
    givenEvents([CustomerRegistered, CustomerDeactivated])
    ->whenCmd(DeactivateCustomer({customerId: cid("c1")}))
    ->thenNoEvent
  )
})
