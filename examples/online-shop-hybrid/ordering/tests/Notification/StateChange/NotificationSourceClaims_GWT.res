@@reventless.gwt

// What a claim does to the request that reads it is the trait's, and is asserted
// through the conformance binding next door. What is left here is this slice's
// own half: the claim set, and both commands being idempotent.
//
// Idempotence matters more than it looks. These commands are relayed, so they
// arrive at-least-once — a re-delivered claim that published a second fact would
// put a duplicate in the log for a takeover that happened once.

describe("NotificationSourceClaims StateChangeSlice", () => {
  let source = "OrderingDcbEventLog:OrderPlaced"

  let claimed: array<consumedEvent> = [
    NotificationSourceClaimed({sourceId: source, by: "campaign-rules"}),
  ]

  test("claiming an unclaimed source is recorded", () =>
    givenEvents([])
    ->whenCmd(ClaimNotificationSource({sourceId: source, by: "campaign-rules"}))
    ->thenEvent(NotificationSourceClaimed({sourceId: source, by: "campaign-rules"}))
  )

  test("re-claiming a source you already hold is a no-op", () =>
    givenEvents(claimed)
    ->whenCmd(ClaimNotificationSource({sourceId: source, by: "campaign-rules"}))
    ->thenNoEvent
  )

  // A takeover by somebody else is recorded rather than refused: the claim says
  // who owns the source now, and the last writer is the answer.
  test("a different owner taking the source over is recorded", () =>
    givenEvents(claimed)
    ->whenCmd(ClaimNotificationSource({sourceId: source, by: "other-rules"}))
    ->thenEvent(NotificationSourceClaimed({sourceId: source, by: "other-rules"}))
  )

  test("releasing a claimed source is recorded", () =>
    givenEvents(claimed)
    ->whenCmd(ReleaseNotificationSource({sourceId: source}))
    ->thenEvent(NotificationSourceReleased({sourceId: source}))
  )

  test("releasing a source nobody holds is a no-op", () =>
    givenEvents([])->whenCmd(ReleaseNotificationSource({sourceId: source}))->thenNoEvent
  )
})
