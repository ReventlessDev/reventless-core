@@reventless.gwt

open Ordering_Examples

describe("Customer Behavior", () => {
  // scenario-id: 190d3516-9b61-4ed3-bc89-beea8997f380
  test("Register on new aggregate produces Registered", () =>
    givenEvents([])
    ->whenCmd(Register({email: aliceEmail, address: mainStreet}))
    ->thenEvent(Registered({email: aliceEmail, address: mainStreet}))
  )

  // scenario-id: 452a23c6-37e2-4ec7-b5eb-d0278a4ddc01
  test("Register on existing aggregate returns CustomerAlreadyRegistered", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(Register({email: "bob@x.y", address: "456 Oak"}))
    ->thenError(CustomerAlreadyRegistered)
  )

  // scenario-id: 530ffecc-7e9c-4c72-8694-53e7e979bece
  test("UpdateEmail on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(UpdateEmail({email: anyEmail}))
    ->thenError(CustomerNotFound)
  )

  // scenario-id: 9bdca4cd-2f47-4f4b-bf53-df742acbe9b2
  test("UpdateEmail on active customer produces EmailUpdated", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(UpdateEmail({email: aliceNewEmail}))
    ->thenEvent(EmailUpdated({email: aliceNewEmail}))
  )

  // scenario-id: 1c6780c2-cba6-4e88-8d44-0f67ad7e12fd
  test("UpdateEmail to same email produces no events (idempotent)", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(UpdateEmail({email: aliceEmail}))
    ->thenNoEvent
  )

  // scenario-id: 287b5b63-d27d-413e-a092-c88a871a493d
  test("UpdateEmail on deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet}), Deactivated])
    ->whenCmd(UpdateEmail({email: anyEmail}))
    ->thenError(CustomerAlreadyDeactivated)
  )

  // scenario-id: 4f2b8d33-8e4d-45b4-8177-e3a6da0adc4d
  test("UpdateAddress on active customer produces AddressUpdated", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(UpdateAddress({address: "789 Pine"}))
    ->thenEvent(AddressUpdated({address: "789 Pine"}))
  )

  // scenario-id: 997eb9bf-32ba-4b94-b73b-be81e3700715
  test("UpdateAddress to same address produces no events (idempotent)", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(UpdateAddress({address: "123 Main"}))
    ->thenNoEvent
  )

  // The case a human comes to the UI for: the geocoder found *a* point and put it
  // in the wrong place. Same address, different point — a correction, not a
  // retry. An idempotency guard that compared only the address would swallow it.
  // scenario-id: 69496313-3f43-4051-a45b-477e7f6660d8
  test("SetAddressLocation with the same address but a new point is a correction", () =>
    givenEvents([
      Registered({email: aliceEmail, address: mainStreet}),
      LocationSet({location: {lat: 51.2093, lng: 3.2247}, resolvedFrom: "123 Main"}),
    ])
    ->whenCmd(SetAddressLocation({address: "123 Main", location: {lat: 51.5, lng: 3.5}}))
    ->thenEvent(AddressLocated({address: "123 Main", location: {lat: 51.5, lng: 3.5}}))
  )

  // scenario-id: d1776e95-e536-4b16-9d8b-652546c77b0c
  test("SetAddressLocation repeating both halves is idempotent", () =>
    givenEvents([
      Registered({email: aliceEmail, address: mainStreet}),
      AddressLocated({address: "123 Main", location: {lat: 51.5, lng: 3.5}}),
    ])
    ->whenCmd(SetAddressLocation({address: "123 Main", location: {lat: 51.5, lng: 3.5}}))
    ->thenNoEvent
  )

  // scenario-id: a213e10f-88e6-4c95-a3a9-74781df32f47
  test("SetLocation on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(SetLocation({location: {lat: 51.2093, lng: 3.2247}, resolvedFrom: "123 Main"}))
    ->thenError(CustomerNotFound)
  )

  // scenario-id: c4235648-a20d-4cc4-9481-23ea840e6b8d
  test("Deactivate on active customer produces Deactivated", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(Deactivate)
    ->thenEvent(Deactivated)
  )

  // scenario-id: 9268384d-762b-451a-91d5-ce8edb553b81
  test("Deactivate on deactivated customer produces no events (idempotent)", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet}), Deactivated])
    ->whenCmd(Deactivate)
    ->thenNoEvent
  )

  // scenario-id: 77896a0a-a306-4018-83ad-294419eca258
  test("Reactivate on deactivated customer produces Reactivated", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet}), Deactivated])
    ->whenCmd(Reactivate)
    ->thenEvent(Reactivated)
  )

  // Accepted rather than refused, because commands are retried: a redelivered
  // `Reactivate` must not fail the second time. It is still not a command to
  // offer here, which is what the declared edge says and this scenario is what
  // holds the two answers apart.
  // scenario-id: d611f10b-b550-4aa7-9907-0fe4e8812811
  test("Reactivate on active customer produces no events (idempotent)", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(Reactivate)
    ->thenNoEvent
  )

  // scenario-id: 9d9c4f2e-01e3-436c-82cb-b944f62be2db
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
  // scenario-id: 4c8094de-47ba-4401-ab59-d0ffa9096048
  test("MarkEmailVerified for the current address produces EmailVerified", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet})])
    ->whenCmd(MarkEmailVerified({email: aliceEmail}))
    ->thenEvent(EmailVerified({email: aliceEmail}))
  )

  // 🚨 The verdict names the address it is about, so one naming an address the
  // customer has moved off is dropped rather than applied. Without this the
  // aggregate would record the *new* address as proven on the strength of a
  // proof issued for the old one.
  // scenario-id: 0c373007-f4df-4d4f-a686-c1cc9d58a599
  test("a verdict for a superseded address produces no event", () =>
    givenEvents([
      Registered({email: aliceEmail, address: mainStreet}),
      EmailUpdated({email: aliceNewEmail}),
    ])
    ->whenCmd(MarkEmailVerified({email: aliceEmail}))
    ->thenNoEvent
  )

  // Commands arrive at least once, so the second delivery must record nothing.
  // scenario-id: 5678dfb3-da66-4f14-8319-a7cf5783f579
  test("a redelivered verdict produces no second event", () =>
    givenEvents([
      Registered({email: aliceEmail, address: mainStreet}),
      EmailVerified({email: aliceEmail}),
    ])
    ->whenCmd(MarkEmailVerified({email: aliceEmail}))
    ->thenNoEvent
  )

  // Changing the address unproves it, so the same address proven again is a new
  // fact rather than a repeat — this is the fold's half of the guard.
  // scenario-id: a6c68c84-0109-450e-a483-6907137a8ef0
  test("a re-verified address after a change is recorded again", () =>
    givenEvents([
      Registered({email: aliceEmail, address: mainStreet}),
      EmailVerified({email: aliceEmail}),
      EmailUpdated({email: aliceNewEmail}),
    ])
    ->whenCmd(MarkEmailVerified({email: aliceNewEmail}))
    ->thenEvent(EmailVerified({email: aliceNewEmail}))
  )

  // Swallowed rather than refused, so a proof settling while the customer was
  // being deactivated does not leave the reporting slice retrying forever.
  // scenario-id: 62f40d78-be08-4d03-85b1-2cd1db773d79
  test("a verdict landing after deactivation produces no events", () =>
    givenEvents([Registered({email: aliceEmail, address: mainStreet}), Deactivated])
    ->whenCmd(MarkEmailVerified({email: aliceEmail}))
    ->thenNoEvent
  )

  // scenario-id: b6d4a64c-f855-4d1e-8c17-67730205ac2f
  test("MarkEmailVerified on non-existent aggregate returns CustomerNotFound", () =>
    givenEvents([])
    ->whenCmd(MarkEmailVerified({email: aliceEmail}))
    ->thenError(CustomerNotFound)
  )
})
