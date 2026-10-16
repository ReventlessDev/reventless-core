@@reventless.automation

// The recipient's choice and their unsubscribing set and clear their schedule;
// every outcome of a request finishes the day's digest, as in `NotificationIntake`.
module OrderingDcbSource = {
  let name = "OrderingDcbEventLog"

  @schema
  type event =
    | DigestTimeChosen({recipientId: string, hour: int, minute: int, zone: string})
    | NotificationUnsubscribed({
        recipientId: string,
        category: NotificationPreferences.category,
        channel: NotificationPreferences.channel,
      })
    | NotificationRequested({reference: string})
    | NotificationSuppressed({reference: string})
    | NotificationUndeliverable({reference: string})
    | NotificationDeferred({reference: string})
}

/** The recipient's time of day, on their own clock. */
let dailyAt = (~hour, ~minute, ~zone) => Reventless.Schedule.Calendar({
  calendar: Daily({hour, minute}),
  zone: ?(zone == "" ? None : Some(zone)),
})

// The key is the recipient whose time came.
module FromClock = Mapping.Make(
  Reventless.Clock,
  MarketingDigest,
  {
    open Reventless.Clock
    let collect = (Tick({key, at}), ~sourceId as _, _ctx) => [
      (itemId(key, at), ({recipientId: key}: MarketingDigest.todoItem)),
    ]
    let resolve = _ => None
  },
)

module FromOrderingDcb = Mapping.Make(
  OrderingDcbSource,
  MarketingDigest,
  {
    open OrderingDcbSource

    let collect = (_, ~sourceId as _, _ctx) => []

    let resolve = event =>
      switch event {
      | NotificationRequested({reference})
      | NotificationSuppressed({reference})
      | NotificationUndeliverable({reference})
      | NotificationDeferred({reference}) =>
        Some(reference)
      | DigestTimeChosen(_)
      | NotificationUnsubscribed(_) =>
        None
      }

    // Unsubscribing from marketing by email stops the digest: a time can only be
    // chosen while it is on, and a schedule that only ever sends nothing is one
    // nobody should pay for.
    let reschedule = event =>
      switch event {
      | DigestTimeChosen({recipientId, hour, minute, zone}) => [
          Set({key: recipientId, time: dailyAt(~hour, ~minute, ~zone)}),
        ]
      | NotificationUnsubscribed({recipientId, category: Marketing, channel: Email}) => [
          Clear({key: recipientId}),
        ]
      | _ => []
      }
  },
)

let mappings: array<module(Mapping)> = [module(FromClock), module(FromOrderingDcb)]

// The item id travels as the request's reference and comes back on its outcome.
// The wording is fixed: what the offers are is the catalog's, and this shop has
// no campaign component yet to say.
let process = (id, item: MarketingDigest.todoItem) => Some((
  item.recipientId,
  MarketingDigest.RequestNotification({
    recipientId: item.recipientId,
    category: Marketing,
    reference: id,
    subjectType: "",
    subjectRef: "",
    subject: "This week's offers",
    body: "A look at what is new in the shop this week.",
    sourceId: `${OrderingDcbSource.name}:DigestTimeChosen`,
    origin: Default,
  }),
))

// A day's digest that never got an answer is not worth announcing: tomorrow's
// comes regardless.
let onExhausted = (_id, _item) => None
