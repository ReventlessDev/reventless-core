@@reventless.gwt

open Ordering_Examples

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
  // scenario-id: d290b174-0fd6-4bbc-8993-bc5b40743474
  test("the requester's own wording and subject survive the decision", () =>
    givenEvents(announced)
    ->whenCmd(
      RequestNotification({
        recipientId: customerRef,
        category: OrderConfirmation,
        reference: confirmReference,
        subjectType: orderSubject,
        subjectRef: orderRef,
        subject: confirmationSubject,
        body: confirmationBody,
        sourceId: orderPlacedSource,
        origin: Default,
      }),
    )
    ->thenEvent(
      NotificationRequested({
        recipientId: customerRef,
        category: OrderConfirmation,
        reference: confirmReference,
        channel: Email,
        address: "buyer@example.com",
        subjectType: orderSubject,
        subjectRef: orderRef,
        subject: confirmationSubject,
        body: confirmationBody,
        origin: Default,
      }),
    )
  )

  // The subject rides through a decision NOT to send as well. A suppressed row
  // that could not say what it was about would leave the view able to report that
  // something was withheld and not which order it concerned.
  // scenario-id: f1a44d87-8963-4d34-8ce1-d3b590cd1894
  test("a suppressed request still records what it was about", () =>
    givenEvents(announced)
    ->whenCmd(
      RequestNotification({
        recipientId: customerRef,
        category: Marketing,
        reference: "promo:o1",
        subjectType: orderSubject,
        subjectRef: orderRef,
        subject: "Deals for you",
        body: "Have a look.",
        sourceId: orderPlacedSource,
        origin: Default,
      }),
    )
    ->thenEvent(
      NotificationSuppressed({
        recipientId: customerRef,
        category: Marketing,
        reference: "promo:o1",
        subjectType: orderSubject,
        subjectRef: orderRef,
        origin: Default,
      }),
    )
  )

  // No rule to state — the outcome is whatever the provider said — which is why
  // these two arms stayed in the host rather than being pushed through a trait
  // that would only pass them along.
  // scenario-id: b80a14eb-1927-409b-b17c-f0b9212b4250
  test("an accepted send is recorded with the provider's own id", () =>
    givenEvents(announced)
    ->whenCmd(
      RecordDelivery({recipientId: customerRef, reference: confirmReference, providerRef: sesRef}),
    )
    ->thenEvent(
      NotificationDelivered({
        recipientId: customerRef,
        reference: confirmReference,
        providerRef: sesRef,
      }),
    )
  )

  // scenario-id: 22353423-b156-46a3-956a-a1aa92053f82
  test("a settled refusal is recorded with its reason", () =>
    givenEvents(announced)
    ->whenCmd(
      RecordDeliveryFailure({
        recipientId: customerRef,
        reference: confirmReference,
        reason: suppressedReason,
      }),
    )
    ->thenEvent(
      NotificationFailed({
        recipientId: customerRef,
        reference: confirmReference,
        reason: suppressedReason,
      }),
    )
  )
})
