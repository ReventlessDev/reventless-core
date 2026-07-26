@@reventless.gwt

describe("Customer Behavior", () => {
  test("Register on new aggregate produces Registered", () =>
    givenEvents([])
    ->whenCmd(Register({email: "alice@x.y", address: "123 Main"}))
    ->thenEvent(Registered({email: "alice@x.y", address: "123 Main"}))
  )

  test("Register on existing aggregate returns CustomerAlreadyRegistered", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenCmd(Register({email: "bob@x.y", address: "456 Oak"}))
    ->thenError(CustomerAlreadyRegistered)
  )

  test("UpdateEmail on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateEmail({email: "x@y"}))
    ->thenError(CustomerNotFound)
  )

  test("UpdateEmail on active customer produces EmailUpdated", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenCmd(UpdateEmail({email: "alice2@x.y"}))
    ->thenEvent(EmailUpdated({email: "alice2@x.y"}))
  )

  test("UpdateEmail to same email produces no events (idempotent)", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenCmd(UpdateEmail({email: "alice@x.y"}))
    ->thenNoEvent
  )

  test("UpdateEmail on deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"}), Deactivated])
    ->whenCmd(UpdateEmail({email: "x@y"}))
    ->thenError(CustomerAlreadyDeactivated)
  )

  test("UpdateAddress on active customer produces AddressUpdated", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenCmd(UpdateAddress({address: "789 Pine"}))
    ->thenEvent(AddressUpdated({address: "789 Pine"}))
  )

  test("UpdateAddress to same address produces no events (idempotent)", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenCmd(UpdateAddress({address: "123 Main"}))
    ->thenNoEvent
  )

  test("SetLocation on active customer produces LocationSet", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenCmd(SetLocation({location: {lat: 51.2093, lng: 3.2247}}))
    ->thenEvent(LocationSet({location: {lat: 51.2093, lng: 3.2247}}))
  )

  test("SetLocation on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(SetLocation({location: {lat: 51.2093, lng: 3.2247}}))
    ->thenError(CustomerNotFound)
  )

  test("AttachDocument on active customer produces DocumentAttached", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenCmd(AttachDocument({attachmentRef: "customer-docs/alice/id.pdf"}))
    ->thenEvent(DocumentAttached({attachmentRef: "customer-docs/alice/id.pdf"}))
  )

  test("AttachDocument on deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"}), Deactivated])
    ->whenCmd(AttachDocument({attachmentRef: "customer-docs/alice/id.pdf"}))
    ->thenError(CustomerAlreadyDeactivated)
  )

  test("Deactivate on active customer produces Deactivated", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenCmd(Deactivate)
    ->thenEvent(Deactivated)
  )

  test("Deactivate on deactivated customer produces no events (idempotent)", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"}), Deactivated])
    ->whenCmd(Deactivate)
    ->thenNoEvent
  )
})
