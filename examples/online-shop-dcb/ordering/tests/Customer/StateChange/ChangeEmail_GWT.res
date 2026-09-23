@@reventless.gwt

open Ordering_Examples

describe("ChangeEmail StateChangeSlice", () => {
  // scenario-id: f82a30f6-fef5-4a05-ac2c-9a419e476f53
  test("non-existent customer returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(ChangeEmail({customerId: c1, email: aliceNewEmail}))
    ->thenError(CustomerNotFound)
  )

  // scenario-id: c772aca9-7aa7-4ee0-bb3e-be1a2dc46967
  test("active customer produces EmailChanged", () =>
    givenEvents([CustomerRegistered({email: aliceEmail})])
    ->whenCmd(ChangeEmail({customerId: c1, email: aliceNewEmail}))
    ->thenEvent(EmailChanged({customerId: c1, email: aliceNewEmail}))
  )

  // scenario-id: 659398db-0145-4e2f-8087-905a1ff03af3
  test("same email produces no events (idempotent)", () =>
    givenEvents([CustomerRegistered({email: aliceEmail})])
    ->whenCmd(ChangeEmail({customerId: c1, email: aliceEmail}))
    ->thenNoEvent
  )

  // scenario-id: c868f35b-ea20-438e-947d-58568db6adbd
  test("deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([CustomerRegistered({email: aliceEmail}), CustomerDeactivated])
    ->whenCmd(ChangeEmail({customerId: c1, email: aliceNewEmail}))
    ->thenError(CustomerAlreadyDeactivated)
  )
})
