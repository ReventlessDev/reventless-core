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

  // The case a human comes to the UI for: the geocoder found *a* point and put it
  // in the wrong place. Same address, different point — a correction, not a
  // retry. An idempotency guard that compared only the address would swallow it.
  test("SetAddressLocation with the same address but a new point is a correction", () =>
    givenEvents([
      Registered({email: "alice@x.y", address: "123 Main"}),
      LocationSet({location: {lat: 51.2093, lng: 3.2247}, resolvedFrom: "123 Main"}),
    ])
    ->whenCmd(SetAddressLocation({address: "123 Main", location: {lat: 51.5, lng: 3.5}}))
    ->thenEvent(AddressLocated({address: "123 Main", location: {lat: 51.5, lng: 3.5}}))
  )

  test("SetAddressLocation repeating both halves is idempotent", () =>
    givenEvents([
      Registered({email: "alice@x.y", address: "123 Main"}),
      AddressLocated({address: "123 Main", location: {lat: 51.5, lng: 3.5}}),
    ])
    ->whenCmd(SetAddressLocation({address: "123 Main", location: {lat: 51.5, lng: 3.5}}))
    ->thenNoEvent
  )

  test("SetLocation on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(SetLocation({location: {lat: 51.2093, lng: 3.2247}, resolvedFrom: "123 Main"}))
    ->thenError(CustomerNotFound)
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
