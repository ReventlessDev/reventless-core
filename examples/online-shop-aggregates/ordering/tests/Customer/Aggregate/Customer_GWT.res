@@reventless.gwt

open Ordering_Examples

describe("Customer Behavior", () => {
  // scenario-id: 5936d064-3500-474f-ac41-619765828d32
  test("Register on new aggregate produces Registered", () =>
    givenEvents([])
    ->whenCmd(Register({email: aliceEmail, address: mainStreet}))
    ->thenEvent(Registered({email: aliceEmail, address: mainStreet}))
  )

  // scenario-id: 93201f16-17d6-4f94-a096-2dbec3c4306c
  test("Register on existing aggregate returns CustomerAlreadyRegistered", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(Register({email: bobEmail, address: oakAvenue}))
    ->thenError(CustomerAlreadyRegistered)
  )

  // scenario-id: fcbc5972-10f0-43ae-a402-21fa7e398e2b
  test("Register on deactivated aggregate returns CustomerAlreadyDeactivated", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet}), Deactivated])
    ->whenCmd(Register({email: bobEmail, address: oakAvenue}))
    ->thenError(CustomerAlreadyDeactivated)
  )

  // scenario-id: eb52c72f-448a-47f6-b6dc-1454fb0976a6
  test("UpdateEmail on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateEmail({email: bobEmail}))
    ->thenError(CustomerNotFound)
  )

  // scenario-id: 0da39fef-7112-4f6b-93d6-f1479d8d384b
  test("UpdateEmail on active customer produces EmailUpdated", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(UpdateEmail({email: "alice2@example.com"}))
    ->thenEvent(EmailUpdated({email: "alice2@example.com"}))
  )

  // scenario-id: 27d8e526-daa8-4b11-be68-c1107394f75d
  test("UpdateEmail to same email produces no events (idempotent)", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(UpdateEmail({email: aliceEmail}))
    ->thenNoEvent
  )

  // scenario-id: f95d0cde-1011-4566-975b-ef086015d811
  test("UpdateEmail on deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet}), Deactivated])
    ->whenCmd(UpdateEmail({email: bobEmail}))
    ->thenError(CustomerAlreadyDeactivated)
  )

  // scenario-id: 856f318e-b0da-4ae8-98bd-0a27c32cfb68
  test("UpdateAddress on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateAddress({address: "x"}))
    ->thenError(CustomerNotFound)
  )

  // scenario-id: 2f4959d6-b687-4659-b5a6-282a6463d1d8
  test("UpdateAddress on active customer produces AddressUpdated", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(UpdateAddress({address: "789 Pine Rd"}))
    ->thenEvent(AddressUpdated({address: "789 Pine Rd"}))
  )

  // scenario-id: 004ce506-1231-43d7-a659-263af800b815
  test("UpdateAddress to same address produces no events (idempotent)", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(UpdateAddress({address: mainStreet}))
    ->thenNoEvent
  )

  // scenario-id: 8c84e2c8-e77c-497d-bad0-70db6643c3de
  test("Deactivate on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(Deactivate)
    ->thenError(CustomerNotFound)
  )

  // scenario-id: 54c0ec8c-f937-41b7-bed0-963c54702564
  test("Deactivate on active customer produces Deactivated", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(Deactivate)
    ->thenEvent(Deactivated)
  )

  // scenario-id: 083c8024-7e68-44d6-b9ff-61a3250202bf
  test("Deactivate on deactivated customer produces no events (idempotent)", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet}), Deactivated])
    ->whenCmd(Deactivate)
    ->thenNoEvent
  )
})
