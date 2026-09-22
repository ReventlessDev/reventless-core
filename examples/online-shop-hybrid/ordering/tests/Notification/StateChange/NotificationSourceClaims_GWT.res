@@reventless.gwt

open OrderingExamples

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

  // scenario-id: 2db3bce9-8286-4e99-80e9-3c2d2f085e08
  test("claiming an unclaimed source is recorded", () =>
    givenEvents([])
    ->whenCmd(ClaimNotificationSource({sourceId: source, by: campaignRules}))
    ->thenEvent(NotificationSourceClaimed({sourceId: source, by: campaignRules}))
  )

  // scenario-id: f02668b2-2c2e-4541-b2da-17259408924c
  test("re-claiming a source you already hold is a no-op", () =>
    givenEvents(claimed)
    ->whenCmd(ClaimNotificationSource({sourceId: source, by: campaignRules}))
    ->thenNoEvent
  )

  // A takeover by somebody else is recorded rather than refused: the claim says
  // who owns the source now, and the last writer is the answer.
  // scenario-id: 1e07555e-b2db-463d-8600-3246e163f7d0
  test("a different owner taking the source over is recorded", () =>
    givenEvents(claimed)
    ->whenCmd(ClaimNotificationSource({sourceId: source, by: "other-rules"}))
    ->thenEvent(NotificationSourceClaimed({sourceId: source, by: "other-rules"}))
  )

  // scenario-id: a30f93a7-eb5b-42fc-9d16-950ca33cbe5a
  test("releasing a claimed source is recorded", () =>
    givenEvents(claimed)
    ->whenCmd(ReleaseNotificationSource({sourceId: source}))
    ->thenEvent(NotificationSourceReleased({sourceId: source}))
  )

  // scenario-id: 2ac75eb5-097e-49ec-9e52-4de2c0576a56
  test("releasing a source nobody holds is a no-op", () =>
    givenEvents([])->whenCmd(ReleaseNotificationSource({sourceId: source}))->thenNoEvent
  )
})
