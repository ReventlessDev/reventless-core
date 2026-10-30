@@reventless.gwt

open Ordering_Examples

describe("Customer Decision", () => {
  // scenario-id: 190d3516-9b61-4ed3-bc89-beea8997f380
  test("Register on new aggregate produces Registered", () =>
    givenEvents([])
    ->whenCmd(Register({email: aliceEmail, address: mainStreet}))
    ->thenEvent(Registered({email: Value(aliceEmail), address: Value(mainStreet)}))
  )

  // scenario-id: 452a23c6-37e2-4ec7-b5eb-d0278a4ddc01
  test("Register on existing aggregate returns CustomerAlreadyRegistered", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
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
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->whenCmd(UpdateEmail({email: aliceNewEmail}))
    ->thenEvent(EmailUpdated({email: Value(aliceNewEmail)}))
  )

  // scenario-id: 1c6780c2-cba6-4e88-8d44-0f67ad7e12fd
  test("UpdateEmail to same email produces no events (idempotent)", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->whenCmd(UpdateEmail({email: aliceEmail}))
    ->thenNoEvent
  )

  // scenario-id: 287b5b63-d27d-413e-a092-c88a871a493d
  test("UpdateEmail on deactivated customer returns CustomerAlreadyDeactivated", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)}), Deactivated])
    ->whenCmd(UpdateEmail({email: anyEmail}))
    ->thenError(CustomerAlreadyDeactivated)
  )

  // scenario-id: 4f2b8d33-8e4d-45b4-8177-e3a6da0adc4d
  test("UpdateAddress on active customer produces AddressUpdated", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->whenCmd(UpdateAddress({address: "789 Pine"}))
    ->thenEvent(AddressUpdated({address: Value("789 Pine")}))
  )

  // scenario-id: 997eb9bf-32ba-4b94-b73b-be81e3700715
  test("UpdateAddress to same address produces no events (idempotent)", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->whenCmd(UpdateAddress({address: "123 Main"}))
    ->thenNoEvent
  )

  // The case a human comes to the UI for: the geocoder found *a* point and put it
  // in the wrong place. Same address, different point — a correction, not a
  // retry. An idempotency guard that compared only the address would swallow it.
  // scenario-id: 69496313-3f43-4051-a45b-477e7f6660d8
  test("SetAddressLocation with the same address but a new point is a correction", () =>
    givenEvents([
      Registered({email: Value(aliceEmail), address: Value(mainStreet)}),
      LocationSet({location: {lat: 51.2093, lng: 3.2247}, resolvedFrom: Value("123 Main")}),
    ])
    ->whenCmd(SetAddressLocation({address: "123 Main", location: {lat: 51.5, lng: 3.5}}))
    ->thenEvent(AddressLocated({address: Value("123 Main"), location: {lat: 51.5, lng: 3.5}}))
  )

  // scenario-id: d1776e95-e536-4b16-9d8b-652546c77b0c
  test("SetAddressLocation repeating both halves is idempotent", () =>
    givenEvents([
      Registered({email: Value(aliceEmail), address: Value(mainStreet)}),
      AddressLocated({address: Value("123 Main"), location: {lat: 51.5, lng: 3.5}}),
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
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->whenCmd(Deactivate)
    ->thenEvent(Deactivated)
  )

  // scenario-id: 9268384d-762b-451a-91d5-ce8edb553b81
  test("Deactivate on deactivated customer produces no events (idempotent)", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)}), Deactivated])
    ->whenCmd(Deactivate)
    ->thenNoEvent
  )

  // scenario-id: 77896a0a-a306-4018-83ad-294419eca258
  test("Reactivate on deactivated customer produces Reactivated", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)}), Deactivated])
    ->whenCmd(Reactivate)
    ->thenEvent(Reactivated)
  )

  // Accepted rather than refused, because commands are retried: a redelivered
  // `Reactivate` must not fail the second time. It is still not a command to
  // offer here, which is what the declared edge says and this scenario is what
  // holds the two answers apart.
  // scenario-id: d611f10b-b550-4aa7-9907-0fe4e8812811
  test("Reactivate on active customer produces no events (idempotent)", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
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
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->whenCmd(MarkEmailVerified({email: aliceEmail}))
    ->thenEvent(EmailVerified({email: Value(aliceEmail)}))
  )

  // 🚨 The verdict names the address it is about, so one naming an address the
  // customer has moved off is dropped rather than applied. Without this the
  // aggregate would record the *new* address as proven on the strength of a
  // proof issued for the old one.
  // scenario-id: 0c373007-f4df-4d4f-a686-c1cc9d58a599
  test("a verdict for a superseded address produces no event", () =>
    givenEvents([
      Registered({email: Value(aliceEmail), address: Value(mainStreet)}),
      EmailUpdated({email: Value(aliceNewEmail)}),
    ])
    ->whenCmd(MarkEmailVerified({email: aliceEmail}))
    ->thenNoEvent
  )

  // Commands arrive at least once, so the second delivery must record nothing.
  // scenario-id: 5678dfb3-da66-4f14-8319-a7cf5783f579
  test("a redelivered verdict produces no second event", () =>
    givenEvents([
      Registered({email: Value(aliceEmail), address: Value(mainStreet)}),
      EmailVerified({email: Value(aliceEmail)}),
    ])
    ->whenCmd(MarkEmailVerified({email: aliceEmail}))
    ->thenNoEvent
  )

  // Changing the address unproves it, so the same address proven again is a new
  // fact rather than a repeat — this is the fold's half of the guard.
  // scenario-id: a6c68c84-0109-450e-a483-6907137a8ef0
  test("a re-verified address after a change is recorded again", () =>
    givenEvents([
      Registered({email: Value(aliceEmail), address: Value(mainStreet)}),
      EmailVerified({email: Value(aliceEmail)}),
      EmailUpdated({email: Value(aliceNewEmail)}),
    ])
    ->whenCmd(MarkEmailVerified({email: aliceNewEmail}))
    ->thenEvent(EmailVerified({email: Value(aliceNewEmail)}))
  )

  // Swallowed rather than refused, so a proof settling while the customer was
  // being deactivated does not leave the reporting slice retrying forever.
  // scenario-id: 62f40d78-be08-4d03-85b1-2cd1db773d79
  test("a verdict landing after deactivation produces no events", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)}), Deactivated])
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

// A customer is the shopper their id names: they, or an administrator, change
// their profile. Taking a customer out of use, or back, is an administrator's.
describe("Who may act on a Customer", () => {
  // scenario-id: 6dc19620-bd20-4e98-a67b-a78aa39083ca
  test("a customer may register themself", () =>
    givenEvents([])
    ->onId(c1)
    ->asCaller(Caller.owner(c1))
    ->whenCmd(Register({email: aliceEmail, address: mainStreet}))
    ->thenEvent(Registered({email: Value(aliceEmail), address: Value(mainStreet)}))
  )

  // scenario-id: ded81926-2cd1-4b9b-8fbf-2683e23e8114
  test("a customer may not register someone else", () =>
    givenEvents([])
    ->onId(c1)
    ->asCaller(Caller.owner(c2))
    ->whenCmd(Register({email: aliceEmail, address: mainStreet}))
    ->thenForbidden
  )

  // scenario-id: f9cd0f95-17f7-477b-be54-8a60c3010bbd
  test("a customer may change their own email", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->onId(c1)
    ->asCaller(Caller.owner(c1))
    ->whenCmd(UpdateEmail({email: aliceNewEmail}))
    ->thenEvent(EmailUpdated({email: Value(aliceNewEmail)}))
  )

  // scenario-id: 786b0aa7-aef7-4e2a-8889-f603c78098ca
  test("another customer may not change the email", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->onId(c1)
    ->asCaller(Caller.owner(c2))
    ->whenCmd(UpdateEmail({email: aliceNewEmail}))
    ->thenForbidden
  )

  // scenario-id: 5e8240aa-2a3c-49c1-ae4a-ffb29a97d138
  test("another customer may not change the address", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->onId(c1)
    ->asCaller(Caller.owner(c2))
    ->whenCmd(UpdateAddress({address: "789 Pine"}))
    ->thenForbidden
  )

  // scenario-id: 46bfc29e-4cfc-42d8-b2f6-296b28609001
  test("an administrator may change any customer's email", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->onId(c1)
    ->asCaller(Caller.operatorIn([Admin]))
    ->whenCmd(UpdateEmail({email: aliceNewEmail}))
    ->thenEvent(EmailUpdated({email: Value(aliceNewEmail)}))
  )

  // scenario-id: 019e2283-a3b3-4972-8fdf-b470320b5ce3
  test("a caller who is not signed in may not change the email", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->onId(c1)
    ->asCaller(Caller.anonymous)
    ->whenCmd(UpdateEmail({email: aliceNewEmail}))
    ->thenForbidden
  )

  // scenario-id: 69dbc4f8-4009-4caa-9e14-f1dd248d7a2a
  test("a customer may not deactivate themself", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->onId(c1)
    ->asCaller(Caller.owner(c1))
    ->whenCmd(Deactivate)
    ->thenForbidden
  )

  // scenario-id: 7d4c5293-934e-4fb5-81d2-b3b8f96c3e5e
  test("an operator who is not an administrator may not deactivate a customer", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->onId(c1)
    ->asCaller(Caller.operatorIn([Fulfilment]))
    ->whenCmd(Deactivate)
    ->thenForbidden
  )

  // scenario-id: 13f06620-a184-4099-be1c-fc727e74788b
  test("an administrator may deactivate a customer", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)})])
    ->onId(c1)
    ->asCaller(Caller.operatorIn([Admin]))
    ->whenCmd(Deactivate)
    ->thenEvent(Deactivated)
  )

  // scenario-id: c5375866-bf51-47fe-8633-b1b2887e2ab2
  test("a customer may not reactivate themself", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)}), Deactivated])
    ->onId(c1)
    ->asCaller(Caller.owner(c1))
    ->whenCmd(Reactivate)
    ->thenForbidden
  )

  // scenario-id: f2696c97-6582-4ee7-a403-ee5aed6d8c19
  test("an administrator may reactivate a customer", () =>
    givenEvents([Registered({email: Value(aliceEmail), address: Value(mainStreet)}), Deactivated])
    ->onId(c1)
    ->asCaller(Caller.operatorIn([Admin]))
    ->whenCmd(Reactivate)
    ->thenEvent(Reactivated)
  )
})
