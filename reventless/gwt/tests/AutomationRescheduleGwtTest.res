// Schedules set by events. The marketing digest declares no time: each recipient's
// time comes from the event that records their choice, a tick of their key makes
// their digest's item, and unsubscribing clears their schedule. The reminder sets a
// once-only time counted from when the order was placed, cleared when it ships.

module MarketingDigest = {
  let name = "MarketingDigest"
  let moduleUrl = ""

  @schema
  type todoItem = {recipientId: string}

  @schema
  type command = RequestNotification({recipientId: string, reference: string})

  let maxRetries = 3
  let targetName = "NotificationPreferences"
  let schedule = None
}

module MarketingDigest_Automation = {
  module M = Reventless.AutomationSlice.Mappings.Make(MarketingDigest)
  module type Mapping = M.Mapping
  let moduleUrl = ""

  module OrderingDcbSource = {
    module Id = Reventless.Id.String
    let name = "OrderingDcbEventLog"
    @schema
    type category = Marketing | Orders
    @schema
    type event =
      | DigestTimeChosen({recipientId: string, time: Reventless.Schedule.time})
      | NotificationUnsubscribed({recipientId: string, category: category})
      | NotificationRequested({recipientId: string, reference: string})
  }

  module FromClock = Reventless.AutomationSlice.Mapping.Make(
    Reventless.Clock,
    MarketingDigest,
    {
      open Reventless.Clock
      // The key is the recipient whose time came.
      let collect = (Tick({key, at}), ~sourceId as _, _ctx) => [
        (itemId(key, at), ({recipientId: key}: MarketingDigest.todoItem)),
      ]
      let resolve = _ => None
      let reschedule = _ => []
    },
  )

  module FromOrderingDcb = Reventless.AutomationSlice.Mapping.Make(
    OrderingDcbSource,
    MarketingDigest,
    {
      open OrderingDcbSource
      let collect = (_, ~sourceId as _, _ctx) => []
      let resolve = event =>
        switch event {
        | NotificationRequested({reference}) => Some(reference)
        | _ => None
        }
      let reschedule = event =>
        switch event {
        | DigestTimeChosen({recipientId, time}) => [
            Reventless.AutomationSlice.Set({key: recipientId, time}),
          ]
        | NotificationUnsubscribed({recipientId, category: Marketing}) => [
            Clear({key: recipientId}),
          ]
        | _ => []
        }
    },
  )

  let mappings: array<module(Mapping)> = [module(FromClock), module(FromOrderingDcb)]

  // The item id travels as the request's reference and comes back on NotificationRequested.
  let process = (id, item: MarketingDigest.todoItem, ~now as _) => Some((
    item.recipientId,
    MarketingDigest.RequestNotification({recipientId: item.recipientId, reference: id}),
  ))
  let onExhausted = (_id, _item: MarketingDigest.todoItem) => None
}

module Digest = {
  open MarketingDigest_Automation
  include Automation_GWT.FromSlice(MarketingDigest, MarketingDigest_Automation)
  module OrderingLog = Mapping(FromOrderingDcb)
}

let time = iso => Date.fromString(iso)->Date.getTime
let at18 = Reventless.Schedule.Calendar({calendar: Daily({hour: 18, minute: 0})})
let at730Berlin = Reventless.Schedule.Calendar({
  calendar: Daily({hour: 7, minute: 30}),
  zone: "Europe/Berlin",
})

JestBind.describe("a schedule per customer: the marketing digest", () => {
  open Digest
  open MarketingDigest_Automation.OrderingDcbSource

  test("each recipient's choice sets their own schedule", () =>
    givenEvents([
      OrderingLog.event(DigestTimeChosen({recipientId: "r1", time: at18})),
      OrderingLog.event(DigestTimeChosen({recipientId: "r2", time: at730Berlin})),
    ])
    ->whenSweep
    ->thenSchedules([("r1", at18), ("r2", at730Berlin)])
  )

  test("a recipient's tick makes their digest, with the item id as reference", () =>
    givenEvents([OrderingLog.event(DigestTimeChosen({recipientId: "r1", time: at18}))])
    ->whenTick(~key="r1", ~at=time("2026-10-16T18:00:00Z"))
    ->thenCommands([
      (
        "r1",
        MarketingDigest.RequestNotification({recipientId: "r1", reference: "r1@2026-10-16T18:00Z"}),
      ),
    ])
  )

  test("the request's own event completes the digest", () =>
    givenEvents([OrderingLog.event(DigestTimeChosen({recipientId: "r1", time: at18}))])
    ->whenTick(~key="r1", ~at=time("2026-10-16T18:00:00Z"))
    ->andThenEvents([
      OrderingLog.event(
        NotificationRequested({recipientId: "r1", reference: "r1@2026-10-16T18:00Z"}),
      ),
    ])
    ->thenScenarioTodos([])
  )

  test("unsubscribing from marketing clears the recipient's schedule, and only theirs", () =>
    givenEvents([
      OrderingLog.event(DigestTimeChosen({recipientId: "r1", time: at18})),
      OrderingLog.event(DigestTimeChosen({recipientId: "r2", time: at730Berlin})),
      OrderingLog.event(NotificationUnsubscribed({recipientId: "r1", category: Marketing})),
      OrderingLog.event(NotificationUnsubscribed({recipientId: "r2", category: Orders})),
    ])
    ->whenSweep
    ->thenSchedules([("r2", at730Berlin)])
  )

  test("a later choice replaces the earlier one", () =>
    givenEvents([
      OrderingLog.event(DigestTimeChosen({recipientId: "r1", time: at18})),
      OrderingLog.event(DigestTimeChosen({recipientId: "r1", time: at730Berlin})),
    ])
    ->whenSweep
    ->thenSchedules([("r1", at730Berlin)])
  )
})

module Reminder = {
  let name = "OrderReminder"
  let moduleUrl = ""

  @schema
  type todoItem = {orderId: string}

  @schema
  type command = RemindOrder({orderId: string})

  let maxRetries = 3
  let targetName = "Order"
  let schedule = None
}

module Reminder_Automation = {
  module M = Reventless.AutomationSlice.Mappings.Make(Reminder)
  module type Mapping = M.Mapping
  let moduleUrl = ""

  module OrderingDcbSource = {
    module Id = Reventless.Id.String
    let name = "OrderingDcbEventLog"
    @schema
    type event = OrderPlaced({orderId: string}) | OrderShipped({orderId: string})
  }

  module FromClock = Reventless.AutomationSlice.Mapping.Make(
    Reventless.Clock,
    Reminder,
    {
      let collect = (Reventless.Clock.Tick({key, at}), ~sourceId as _, _ctx) => [
        (Reventless.Clock.itemId(key, at), ({orderId: key}: Reminder.todoItem)),
      ]
      let resolve = _ => None
      let reschedule = _ => []
    },
  )

  module FromOrdering = Reventless.AutomationSlice.Mapping.Make(
    OrderingDcbSource,
    Reminder,
    {
      let collect = (_, ~sourceId as _, _ctx) => []
      let resolve = _ => None
      let reschedule = event =>
        switch event {
        | OrderingDcbSource.OrderPlaced({orderId}) => [
            Reventless.AutomationSlice.Set({
              key: orderId,
              time: Once({moment: After(Minutes(10))}),
            }),
          ]
        | OrderShipped({orderId}) => [Clear({key: orderId})]
        }
    },
  )

  let mappings: array<module(Mapping)> = [module(FromClock), module(FromOrdering)]

  let process = (_id, item: Reminder.todoItem, ~now as _) => Some((
    item.orderId,
    Reminder.RemindOrder({orderId: item.orderId}),
  ))
  let onExhausted = (_id, _item: Reminder.todoItem) => None
}

module ReminderGwt = {
  open Reminder_Automation
  include Automation_GWT.FromSlice(Reminder, Reminder_Automation)
  module OrderingLog = Mapping(FromOrdering)
}

let placedAt = time("2026-10-16T09:00:00Z")
let tenPast = Reventless.Schedule.Once({
  moment: At({year: 2026, month: 10, day: 16, hour: 9, minute: 10}),
})

JestBind.describe("a once-only time: the reminder", () => {
  open ReminderGwt
  open Reminder_Automation.OrderingDcbSource

  test("is set ten minutes after the order was recorded", () =>
    givenEvents([OrderingLog.event(OrderPlaced({orderId: "o1"}), ~recordedAt=placedAt)])
    ->whenSweep
    ->thenSchedules([("o1", tenPast)])
  )

  test("is cleared when the order ships", () =>
    givenEvents([
      OrderingLog.event(OrderPlaced({orderId: "o1"}), ~recordedAt=placedAt),
      OrderingLog.event(OrderShipped({orderId: "o1"}), ~recordedAt=placedAt +. 60_000.),
    ])
    ->whenSweep
    ->thenSchedules([])
  )

  test("is cleared once it has fired, and its tick sends the reminder", () => {
    let scenario =
      givenEvents([
        OrderingLog.event(OrderPlaced({orderId: "o1"}), ~recordedAt=placedAt),
      ])->whenTick(~key="o1", ~at=time("2026-10-16T09:10:00Z"))
    switch scenario->thenSchedules([]) {
    | Ok() => scenario->thenCommands([("o1", Reminder.RemindOrder({orderId: "o1"}))])
    | failed => failed
    }
  })
})
