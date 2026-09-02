@@reventless.automation

// A TODO id is also the `reference` the request carries, so the outcome event
// echoes back exactly what resolves the row. One key per occurrence, not per
// order: an order that is placed and then ships is two notifications, and a
// shared key would let the first one's outcome close the second one's row.
let confirmationKey = orderId => `confirm:${orderId}`
let shippingKey = orderId => `ship:${orderId}`

// One source: this plugin's DCB log, which is where the occurrence is and where
// every outcome lands. Both order events name their own customer, which is what
// lets an automation read them at all — see the sibling contact relay for the
// events that do not.
module OrderingDcbSource = {
  let name = "OrderingDcbEventLog"

  @schema
  type event =
    | OrderPlaced({orderId: string, customerId: string})
    | OrderShipped({orderId: string, customerId: string})
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
            ({recipientId: customerId, orderId, occurrence: Placed}: NotificationIntake.todoItem),
          ),
        ]
      | OrderShipped({orderId, customerId}) => [
          (
            shippingKey(orderId),
            ({recipientId: customerId, orderId, occurrence: Shipped}: NotificationIntake.todoItem),
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
      | OrderPlaced(_)
      | OrderShipped(_) => None
      }
  },
)

let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]

// The one place this host's occurrences are given a kind and a wording. A trait
// cannot write this: the categories are ones the trait declares, but which of the
// host's events earns which, and what the sentence says, is the host's.
//
// One switch over the occurrence, so adding a notifiable event means adding an
// arm here rather than remembering to change a category further down.
let compose = (item: NotificationIntake.todoItem) =>
  switch item.occurrence {
  | Placed => (
      NotificationPreferences.OrderConfirmation,
      `Your order ${item.orderId} is confirmed`,
      `Thanks — we have your order ${item.orderId} and will let you know when it ships.`,
    )
  | Shipped => (
      NotificationPreferences.ShippingUpdate,
      `Your order ${item.orderId} is on its way`,
      `Good news — order ${item.orderId} has shipped.`,
    )
  }

// What the notification is about, stated plainly beside the reference. The
// reference is a correlation key — one per occurrence, prefixed, and its format
// is this relay's own business; the subject is the order itself, so a delivery
// row can name what it concerned without anybody decoding that string.
let subjectType = "Order"

let process = (id, item: NotificationIntake.todoItem) => {
  let (category, subject, body) = compose(item)
  Some((
    item.recipientId,
    NotificationIntake.RequestNotification({
      recipientId: item.recipientId,
      category,
      reference: id,
      subjectType,
      subjectRef: item.orderId,
      subject,
      body,
    }),
  ))
}

// Nothing to say. A relay that gave up published no command, so the notification
// competency never heard of the occurrence — and a delivery-failed fact for a
// notification nobody requested would put a row in the log for something that
// was never attempted.
let onExhausted = (_id, _item) => None
