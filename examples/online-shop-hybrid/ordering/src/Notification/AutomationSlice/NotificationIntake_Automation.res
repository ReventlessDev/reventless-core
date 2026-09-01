@@reventless.automation

// A TODO id is also the `reference` the request carries, so the outcome event
// echoes back exactly what resolves the row.
let confirmationKey = orderId => `confirm:${orderId}`

// One source: this plugin's DCB log, which is where the occurrence is and where
// every outcome lands. `OrderPlaced` names its own customer, which is what lets
// an automation read it at all — see the sibling contact relay for the events
// that do not.
module OrderingDcbSource = {
  let name = "OrderingDcbEventLog"

  @schema
  type event =
    | OrderPlaced({orderId: string, customerId: string})
    // Every way a request can end. All three resolve the row, because all three
    // mean the decision was made — a suppressed notification is a finished piece
    // of work, not a failed one.
    | NotificationRequested({reference: string})
    | NotificationSuppressed({reference: string})
    | NotificationUndeliverable({reference: string})
}

module FromOrderingDcb = Mapping.Make(
  OrderingDcbSource,
  NotificationIntake,
  {
    open OrderingDcbSource

    let collect = (event, ~sourceId as _, _ctx) =>
      switch event {
      | OrderPlaced({orderId, customerId}) => [
          (
            confirmationKey(orderId),
            ({recipientId: customerId, orderId}: NotificationIntake.todoItem),
          ),
        ]
      | NotificationRequested(_)
      | NotificationSuppressed(_)
      | NotificationUndeliverable(_) => []
      }

    let resolve = event =>
      switch event {
      | NotificationRequested({reference})
      | NotificationSuppressed({reference})
      | NotificationUndeliverable({reference}) =>
        Some(reference)
      | OrderPlaced(_) => None
      }
  },
)

let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]

// The one place this host's occurrences are given a kind and a wording. A trait
// cannot write this: `OrderConfirmation` is a category the trait declares, but
// which of the host's events earns it, and what the sentence says, is the host's.
let process = (id, item: NotificationIntake.todoItem) =>
  Some((
    item.recipientId,
    NotificationIntake.RequestNotification({
      recipientId: item.recipientId,
      category: OrderConfirmation,
      reference: id,
      subject: `Your order ${item.orderId} is confirmed`,
      body: `Thanks — we have your order ${item.orderId} and will let you know when it ships.`,
    }),
  ))

// Nothing to say. A relay that gave up published no command, so the notification
// competency never heard of the occurrence — and a delivery-failed fact for a
// notification nobody requested would put a row in the log for something that
// was never attempted.
let onExhausted = (_id, _item) => None
