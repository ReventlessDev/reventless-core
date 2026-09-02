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
  // channel and an address — no sentence, because a trait has no business holding
  // one, and no subject, because it refuses to know what an occurrence is. So
  // both travel on the command and are put back after the decision, which is host
  // code and is the one part of this mapping that is not a rename.
  test("the requester's own wording and subject survive the decision", () =>
    givenEvents(announced)
    ->whenCmd(
      RequestNotification({
        recipientId: "c1",
        category: OrderConfirmation,
        reference: "confirm:o1",
        subjectType: "Order",
        subjectRef: "o1",
        subject: "Your order o1 is confirmed",
        body: "Thanks — we have your order o1 and will let you know when it ships.",
        sourceId: "OrderingDcbEventLog:OrderPlaced",
        origin: Default,
      }),
    )
    ->thenEvent(
      NotificationRequested({
        recipientId: "c1",
        category: OrderConfirmation,
        reference: "confirm:o1",
        channel: Email,
        address: "buyer@example.com",
        subjectType: "Order",
        subjectRef: "o1",
        subject: "Your order o1 is confirmed",
        body: "Thanks — we have your order o1 and will let you know when it ships.",
        origin: Default,
      }),
    )
  )

  // The subject rides through a decision NOT to send as well. A suppressed row
  // that could not say what it was about would leave the view able to report that
  // something was withheld and not which order it concerned.
  test("a suppressed request still records what it was about", () =>
    givenEvents(announced)
    ->whenCmd(
      RequestNotification({
        recipientId: "c1",
        category: Marketing,
        reference: "promo:o1",
        subjectType: "Order",
        subjectRef: "o1",
        subject: "Deals for you",
        body: "Have a look.",
        sourceId: "OrderingDcbEventLog:OrderPlaced",
        origin: Default,
      }),
    )
    ->thenEvent(
      NotificationSuppressed({
        recipientId: "c1",
        category: Marketing,
        reference: "promo:o1",
        subjectType: "Order",
        subjectRef: "o1",
        origin: Default,
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
