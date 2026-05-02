@@reventless.gwt

describe("ChangeEmail StateChangeSlice", () => {
  test("non-existent customer returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeEmail({customerId: "c1", email: "alice2@x.y"}))
    ->thenError(CustomerNotFound)
  )

  test("active customer produces EmailChanged", () =>
    givenEvents([CustomerRegistered({email: "alice@x.y"})])
    ->whenCmd(ChangeEmail({customerId: "c1", email: "alice2@x.y"}))
    ->thenEvent(EmailChanged({customerId: "c1", email: "alice2@x.y"}))
  )

  test("same email produces no events (idempotent)", () =>
    givenEvents([CustomerRegistered({email: "alice@x.y"})])
    ->whenCmd(ChangeEmail({customerId: "c1", email: "alice@x.y"}))
    ->thenNoEvent
  )

  test("deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([CustomerRegistered({email: "alice@x.y"}), CustomerDeactivated])
    ->whenCmd(ChangeEmail({customerId: "c1", email: "alice2@x.y"}))
    ->thenError(CustomerAlreadyDeactivated)
  )
})
