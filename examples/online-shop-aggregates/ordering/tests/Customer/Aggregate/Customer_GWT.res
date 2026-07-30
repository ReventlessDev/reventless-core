@@reventless.gwt

describe("Customer Behavior", () => {
  test("Register on new aggregate produces Registered", () =>
    givenEvents([])
    ->whenCmd(Register({email: "alice@example.com", address: "123 Main St"}))
    ->thenEvent(Registered({email: "alice@example.com", address: "123 Main St"}))
  )

  test("Register on existing aggregate returns CustomerAlreadyRegistered", () =>
    givenEvents([Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenCmd(Register({email: "bob@example.com", address: "456 Oak Ave"}))
    ->thenError(CustomerAlreadyRegistered)
  )

  test("Register on deactivated aggregate returns CustomerAlreadyDeactivated", () =>
    givenEvents([
      Registered({email: "alice@example.com", address: "123 Main St"}),
      Deactivated,
    ])
    ->whenCmd(Register({email: "bob@example.com", address: "456 Oak Ave"}))
    ->thenError(CustomerAlreadyDeactivated)
  )

  test("UpdateEmail on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateEmail({email: "bob@example.com"}))
    ->thenError(CustomerNotFound)
  )

  test("UpdateEmail on active customer produces EmailUpdated", () =>
    givenEvents([Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenCmd(UpdateEmail({email: "alice2@example.com"}))
    ->thenEvent(EmailUpdated({email: "alice2@example.com"}))
  )

  test("UpdateEmail to same email produces no events (idempotent)", () =>
    givenEvents([Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenCmd(UpdateEmail({email: "alice@example.com"}))
    ->thenNoEvent
  )

  test("UpdateEmail on deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([
      Registered({email: "alice@example.com", address: "123 Main St"}),
      Deactivated,
    ])
    ->whenCmd(UpdateEmail({email: "bob@example.com"}))
    ->thenError(CustomerAlreadyDeactivated)
  )

  test("UpdateAddress on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateAddress({address: "x"}))
    ->thenError(CustomerNotFound)
  )

  test("UpdateAddress on active customer produces AddressUpdated", () =>
    givenEvents([Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenCmd(UpdateAddress({address: "789 Pine Rd"}))
    ->thenEvent(AddressUpdated({address: "789 Pine Rd"}))
  )

  test("UpdateAddress to same address produces no events (idempotent)", () =>
    givenEvents([Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenCmd(UpdateAddress({address: "123 Main St"}))
    ->thenNoEvent
  )

  test("Deactivate on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(Deactivate)
    ->thenError(CustomerNotFound)
  )

  test("Deactivate on active customer produces Deactivated", () =>
    givenEvents([Registered({email: "alice@example.com", address: "123 Main St"})])
    ->whenCmd(Deactivate)
    ->thenEvent(Deactivated)
  )

  test("Deactivate on deactivated customer produces no events (idempotent)", () =>
    givenEvents([
      Registered({email: "alice@example.com", address: "123 Main St"}),
      Deactivated,
    ])
    ->whenCmd(Deactivate)
    ->thenNoEvent
  )
})
