// The digest's schedules are set and cleared by events, one per recipient, and
// each recipient's tick asks for their digest.

@@reventless.gwt

module Ordering = Mapping(FromOrderingDcb)

open OrderingDcbSource

let berlin730 = Reventless.Schedule.Calendar({
  calendar: Daily({hour: 7, minute: 30}),
  zone: "Europe/Berlin",
})
let utc18 = Reventless.Schedule.Calendar({calendar: Daily({hour: 18, minute: 0})})
let evening = Date.fromString("2026-10-16T18:00:00Z")->Date.getTime
let eveningItem = "c1@2026-10-16T18:00Z"

describe("MarketingDigest AutomationSlice", () => {
  // scenario-id: 8ac6f9a3-b673-4fad-b46c-89378c19332e
  test("each recipient's choice is their own schedule, read on their own clock", () =>
    givenEvents([
      Ordering.event(DigestTimeChosen({recipientId: "c1", hour: 18, minute: 0, zone: ""})),
      Ordering.event(
        DigestTimeChosen({recipientId: "c2", hour: 7, minute: 30, zone: "Europe/Berlin"}),
      ),
    ])
    ->whenSweep
    ->thenSchedules([("c1", utc18), ("c2", berlin730)])
  )

  // scenario-id: 91a7e28a-0364-4e92-a53f-07f48643937e
  test(
    "unsubscribing from marketing by email stops the digest; another channel or category does not",
    () =>
      givenEvents([
        Ordering.event(DigestTimeChosen({recipientId: "c1", hour: 18, minute: 0, zone: ""})),
        Ordering.event(
          DigestTimeChosen({recipientId: "c2", hour: 7, minute: 30, zone: "Europe/Berlin"}),
        ),
        Ordering.event(
          NotificationUnsubscribed({recipientId: "c1", category: Marketing, channel: Email}),
        ),
        Ordering.event(
          NotificationUnsubscribed({recipientId: "c2", category: ShippingUpdate, channel: Email}),
        ),
        Ordering.event(
          NotificationUnsubscribed({recipientId: "c2", category: Marketing, channel: Sms}),
        ),
      ])
      ->whenSweep
      ->thenSchedules([("c2", berlin730)]),
  )

  // scenario-id: 2052c29a-9548-4b87-8838-38b450d07e95
  test("the recipient's tick asks for their digest, the day's item as its reference", () =>
    givenEvents([
      Ordering.event(DigestTimeChosen({recipientId: "c1", hour: 18, minute: 0, zone: ""})),
    ])
    ->whenTick(~key="c1", ~at=evening)
    ->thenCommands([
      (
        "c1",
        RequestNotification({
          recipientId: "c1",
          category: Marketing,
          reference: eveningItem,
          subjectType: "",
          subjectRef: "",
          subject: "This week's offers",
          body: "A look at what is new in the shop this week.",
          sourceId: "OrderingDcbEventLog:DigestTimeChosen",
          origin: Default,
        }),
      ),
    ])
  )

  // A suppressed digest is a finished one: the recipient opted out of nothing yet,
  // or the shop has no address, and either way there is nothing to retry.
  // scenario-id: da707fa5-81f2-40f9-b6bd-da63372ef103
  test("any outcome of the request finishes the day's digest", () =>
    givenEvents([
      Ordering.event(DigestTimeChosen({recipientId: "c1", hour: 18, minute: 0, zone: ""})),
    ])
    ->whenTick(~key="c1", ~at=evening)
    ->andThenEvents([Ordering.event(NotificationSuppressed({reference: eveningItem}))])
    ->thenScenarioTodos([])
  )
})
