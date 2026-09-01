@@reventless.gwt

// The competency's whole decision surface: who is reachable, what they want, and
// what happens when the two do not add up. The cases that matter are the ones
// where nothing is sent — a notification that goes out is easy to get right, and
// every way of not sending one is a different fact.

describe("NotificationPreferences StateChangeSlice", () => {
  // Annotated because `RecipientAnnounced` is a constructor of both the consumed
  // and the produced union — this slice reads back exactly what it wrote — and
  // the history side is the consumed one.
  let announced: array<consumedEvent> = [
    RecipientAnnounced({recipientId: "c1", email: "buyer@example.com"}),
  ]

  describe("the directory", () => {
    test("an announced contact is recorded", () =>
      givenEvents([])
      ->whenCmd(AnnounceRecipient({recipientId: "c1", email: "buyer@example.com"}))
      ->thenEvent(RecipientAnnounced({recipientId: "c1", email: "buyer@example.com"}))
    )

    // The relay re-announces on every `Registered` and every `EmailUpdated`, and
    // its row completes on the publish rather than on an event coming back — so
    // saying nothing here is safe, and recording a change that did not happen
    // would not be.
    test("re-announcing the address already on file changes nothing", () =>
      givenEvents(announced)
      ->whenCmd(AnnounceRecipient({recipientId: "c1", email: "buyer@example.com"}))
      ->thenNoEvent
    )

    test("a changed address is recorded", () =>
      givenEvents(announced)
      ->whenCmd(AnnounceRecipient({recipientId: "c1", email: "new@example.com"}))
      ->thenEvent(RecipientAnnounced({recipientId: "c1", email: "new@example.com"}))
    )
  })

  describe("the matrix", () => {
    // A person is at the other end of this one, so they are told rather than
    // having a fact recorded about them.
    test("subscribing someone the directory has never heard of is refused", () =>
      givenEvents([])
      ->whenCmd(Subscribe({recipientId: "c1", category: Marketing, channel: Email}))
      ->thenError(RecipientUnknown)
    )

    test("opting in to a category that is off by default is recorded", () =>
      givenEvents(announced)
      ->whenCmd(Subscribe({recipientId: "c1", category: Marketing, channel: Email}))
      ->thenEvent(NotificationSubscribed({recipientId: "c1", category: Marketing, channel: Email}))
    )

    // Already on by default. Recording a subscription here would say the
    // recipient chose something they did not, and the next posture change would
    // then not reach them.
    test("subscribing to a transactional category that is already on says nothing", () =>
      givenEvents(announced)
      ->whenCmd(Subscribe({recipientId: "c1", category: OrderConfirmation, channel: Email}))
      ->thenNoEvent
    )

    test("opting out of a transactional category is recorded", () =>
      givenEvents(announced)
      ->whenCmd(Unsubscribe({recipientId: "c1", category: OrderConfirmation, channel: Email}))
      ->thenEvent(
        NotificationUnsubscribed({recipientId: "c1", category: OrderConfirmation, channel: Email}),
      )
    )
  })

  describe("dispatch", () => {
    // The default posture doing its job: a shopper who has never seen a settings
    // screen still gets the confirmation they asked for by ordering.
    test("a transactional notification goes out with no explicit subscription", () =>
      givenEvents(announced)
      ->whenCmd(
        RequestNotification({
          recipientId: "c1",
          category: OrderConfirmation,
          reference: "confirm:o1",
          subject: "Your order o1 is confirmed",
          body: "Thanks.",
        }),
      )
      ->thenEvent(
        NotificationRequested({
          recipientId: "c1",
          category: OrderConfirmation,
          reference: "confirm:o1",
          channel: Email,
          // The address resolved here, not carried by the occurrence — which is
          // the whole reason this slice holds the directory.
          address: "buyer@example.com",
          subject: "Your order o1 is confirmed",
          body: "Thanks.",
        }),
      )
    )

    // The opposite posture, same recipient, same directory row.
    test("a marketing notification is suppressed with no explicit subscription", () =>
      givenEvents(announced)
      ->whenCmd(
        RequestNotification({
          recipientId: "c1",
          category: Marketing,
          reference: "promo:spring",
          subject: "Spring sale",
          body: "Everything must go.",
        }),
      )
      ->thenEvent(
        NotificationSuppressed({
          recipientId: "c1",
          category: Marketing,
          reference: "promo:spring",
        }),
      )
    )

    test("a recipient who opted out is suppressed", () =>
      givenEvents(
        Array.concat(
          announced,
          [NotificationUnsubscribed({recipientId: "c1", category: OrderConfirmation, channel: Email})],
        ),
      )
      ->whenCmd(
        RequestNotification({
          recipientId: "c1",
          category: OrderConfirmation,
          reference: "confirm:o1",
          subject: "s",
          body: "b",
        }),
      )
      ->thenEvent(
        NotificationSuppressed({
          recipientId: "c1",
          category: OrderConfirmation,
          reference: "confirm:o1",
        }),
      )
    )

    // The case the whole directory exists for. Nobody announced this recipient,
    // so there is no address — and this is a gap in the system, not a preference,
    // which is why it is not the same fact as the two above.
    test("a recipient nobody announced is undeliverable, not suppressed", () =>
      givenEvents([])
      ->whenCmd(
        RequestNotification({
          recipientId: "ghost",
          category: OrderConfirmation,
          reference: "confirm:o9",
          subject: "s",
          body: "b",
        }),
      )
      ->thenEvent(
        NotificationUndeliverable({
          recipientId: "ghost",
          category: OrderConfirmation,
          reference: "confirm:o9",
        }),
      )
    )

    // Wanted, and unreachable. The directory holds an email and nothing else, so
    // a recipient who chose SMS and switched email off has asked for something
    // this trait cannot do — recorded rather than dropped, so the gap is visible
    // instead of looking like a preference being honoured.
    test("a channel with no address on file is undeliverable, not suppressed", () =>
      givenEvents(
        Array.concat(
          announced,
          [
            NotificationSubscribed({recipientId: "c1", category: OrderConfirmation, channel: Sms}),
            NotificationUnsubscribed({
              recipientId: "c1",
              category: OrderConfirmation,
              channel: Email,
            }),
          ],
        ),
      )
      ->whenCmd(
        RequestNotification({
          recipientId: "c1",
          category: OrderConfirmation,
          reference: "confirm:o1",
          subject: "s",
          body: "b",
        }),
      )
      ->thenEvent(
        NotificationUndeliverable({
          recipientId: "c1",
          category: OrderConfirmation,
          reference: "confirm:o1",
        }),
      )
    )
  })

  describe("delivery outcomes", () => {
    test("an accepted send is recorded with the provider's own id", () =>
      givenEvents(announced)
      ->whenCmd(
        RecordDelivery({recipientId: "c1", reference: "confirm:o1", providerRef: "ses-123"}),
      )
      ->thenEvent(
        NotificationDelivered({
          recipientId: "c1",
          reference: "confirm:o1",
          providerRef: "ses-123",
        }),
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
})
