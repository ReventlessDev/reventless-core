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

  test("Reactivate on deactivated customer produces Reactivated", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"}), Deactivated])
    ->whenCmd(Reactivate)
    ->thenEvent(Reactivated)
  )

  // Accepted rather than refused, because commands are retried: a redelivered
  // `Reactivate` must not fail the second time. It is still not a command to
  // offer here, which is what the declared edge says and this scenario is what
  // holds the two answers apart.
  test("Reactivate on active customer produces no events (idempotent)", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenCmd(Reactivate)
    ->thenNoEvent
  )

  test("Reactivate on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(Reactivate)
    ->thenError(CustomerNotFound)
  )
})

// The verification graft's write-back. The first scenario is the security test:
// it is what stops "change the address, then present the old one's link" from
// marking the new address proven.
describe("Customer email verification", () => {
  test("MarkEmailVerified for the current address produces EmailVerified", () =>
    givenEvents([Registered({email: "alice@x.y", address: "123 Main"})])
    ->whenCmd(MarkEmailVerified({email: "alice@x.y"}))
    ->thenEvent(EmailVerified({email: "alice@x.y"}))
  )

  // 🚨 The verdict names the address it is about, so one naming an address the
  // customer has moved off is dropped rather than applied. Without this the
  // aggregate would record the *new* address as proven on the strength of a
  // proof issued for the old one.
  test("a verdict for a superseded address produces no event", () =>
    givenEvents([
      Registered({email: "alice@x.y", address: "123 Main"}),
      EmailUpdated({email: "alice2@x.y"}),
    ])
    ->whenCmd(MarkEmailVerified({email: "alice@x.y"}))
    ->thenNoEvent
  )

  // Commands arrive at least once, so the second delivery must record nothing.
  test("a redelivered verdict produces no second event", () =>
    givenEvents([
      Registered({email: "alice@x.y", address: "123 Main"}),
      EmailVerified({email: "alice@x.y"}),
    ])
    ->whenCmd(MarkEmailVerified({email: "alice@x.y"}))
    ->thenNoEvent
  )

  // Changing the address unproves it, so the same address proven again is a new
  // fact rather than a repeat — this is the fold's half of the guard.
  test("a re-verified address after a change is recorded again", () =>
    givenEvents([
      Registered({email: "alice@x.y", address: "123 Main"}),
      EmailVerified({email: "alice@x.y"}),
      EmailUpdated({email: "alice2@x.y"}),
    ])
    ->whenCmd(MarkEmailVerified({email: "alice2@x.y"}))
    ->thenEvent(EmailVerified({email: "alice2@x.y"}))
  )

  // Swallowed rather than refused, so a proof settling while the customer was
  // being deactivated does not leave the reporting slice retrying forever.
  test("a verdict landing after deactivation produces no events", () =>
    givenEvents([
      Registered({email: "alice@x.y", address: "123 Main"}),
      Deactivated,
    ])
    ->whenCmd(MarkEmailVerified({email: "alice@x.y"}))
    ->thenNoEvent
  )

  test("MarkEmailVerified on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(MarkEmailVerified({email: "alice@x.y"}))
    ->thenError(CustomerNotFound)
  )
})
