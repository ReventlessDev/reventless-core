@@reventless.gwt

// What is left after the trait's suite took the competency.
//
// The directory, the matrix and the three ways to send nothing are asserted by
// `NotificationConformance_GWT.res` and are deliberately not restated here: a
// rule the suite covers must not also live in the host's tests, or the two drift
// and neither is the source of truth.
//
// What stays is what this shop knows and the trait does not — its wording, and
// what it does with a provider's answer.

describe("NotificationPreferences StateChangeSlice", () => {
  let announced: array<consumedEvent> = [
    RecipientAnnounced({recipientId: "c1", email: "buyer@example.com"}),
  ]

  // The trait's `Requested` fact carries a recipient, a kind, a reference, a
  // channel and an address — and no sentence, because a trait has no business
  // holding one. So the wording travels on the command and is put back after the
  // decision, which is host code and is the one part of this mapping that is not
  // a rename.
  test("the requester's own wording survives the decision", () =>
    givenEvents(announced)
    ->whenCmd(
      RequestNotification({
        recipientId: "c1",
        category: OrderConfirmation,
        reference: "confirm:o1",
        subject: "Your order o1 is confirmed",
        body: "Thanks — we have your order o1 and will let you know when it ships.",
      }),
    )
    ->thenEvent(
      NotificationRequested({
        recipientId: "c1",
        category: OrderConfirmation,
        reference: "confirm:o1",
        channel: Email,
        address: "buyer@example.com",
        subject: "Your order o1 is confirmed",
        body: "Thanks — we have your order o1 and will let you know when it ships.",
      }),
    )
  )

  // No rule to state — the outcome is whatever the provider said — which is why
  // these two arms stayed in the host rather than being pushed through a trait
  // that would only pass them along.
  test("an accepted send is recorded with the provider's own id", () =>
    givenEvents(announced)
    ->whenCmd(RecordDelivery({recipientId: "c1", reference: "confirm:o1", providerRef: "ses-123"}))
    ->thenEvent(
      NotificationDelivered({recipientId: "c1", reference: "confirm:o1", providerRef: "ses-123"}),
    )
  )

  test("a settled refusal is recorded with its reason", () =>
    givenEvents(announced)
    ->whenCmd(
      RecordDeliveryFailure({
        recipientId: "c1",
        reference: "confirm:o1",
        reason: "address on the suppression list",
      }),
    )
    ->thenEvent(
      NotificationFailed({
        recipientId: "c1",
        reference: "confirm:o1",
        reason: "address on the suppression list",
      }),
    )
  )
})
