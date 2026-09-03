@@reventless.automation

module Rule = TraitNotification.Notification_Rule

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
    // Every way a request can end. All four resolve the row, because all four
    // mean the decision was made — a suppressed notification is a finished piece
    // of work, not a failed one, and a deferred one is somebody else's work.
    //
    // Missing the fourth is not a missing nicety: an unresolved row retries its
    // whole budget and lands in `onExhausted`, so a handover would look like a
    // slow failure with nothing in the log to explain it.
    | NotificationRequested({reference: string})
    | NotificationSuppressed({reference: string})
    | NotificationUndeliverable({reference: string})
    | NotificationDeferred({reference: string})
}

// The one place this host's occurrences are given a kind and a wording, and it
// is a table of values rather than a switch. A trait cannot write this: the
// categories are ones the trait declares, but which of the host's events earns
// which — and what the sentence says — is the host's.
//
// A rule's id is also the namespace of the references it writes, so an order
// that is placed and then ships is two notifications and two delivery rows.
let defaultRules: array<Rule.t> = [
  {
    id: "confirm",
    version: "1",
    source: {log: OrderingDcbSource.name, eventType: "OrderPlaced"},
    filter: Always,
    category: "OrderConfirmation",
    recipientPath: "recipientId",
    subjectType: "Order",
    subjectPath: "orderId",
    content: [
      {
        locale: "en",
        subject: "Your order {{ orderId }} is confirmed",
        body: "Thanks — we have your order {{ orderId }} and will let you know when it ships.",
      },
    ],
  },
  {
    id: "ship",
    version: "1",
    source: {log: OrderingDcbSource.name, eventType: "OrderShipped"},
    filter: Always,
    category: "ShippingUpdate",
    recipientPath: "recipientId",
    subjectType: "Order",
    subjectPath: "orderId",
    content: [
      {
        locale: "en",
        subject: "Your order {{ orderId }} is on its way",
        body: "Good news — order {{ orderId }} has shipped.",
      },
    ],
  },
]

// The dispatch is the table's, so the switch below only takes an event apart.
// Two rules on one event type are two notifications, with no arm to add.
let todosFor = (~eventType, ~recipientId, ~orderId) =>
  defaultRules
  ->Rule.forEvent(~log=OrderingDcbSource.name, ~eventType)
  ->Array.map(rule => (
    Rule.reference(rule, ~subject=orderId),
    ({ruleId: rule.id, recipientId, orderId}: NotificationIntake.todoItem),
  ))

module FromOrderingDcb = Mapping.Make(
  OrderingDcbSource,
  NotificationIntake,
  {
    open OrderingDcbSource

    let collect = (event, ~sourceId as _, _ctx) =>
      switch event {
      | OrderPlaced({orderId, customerId}) =>
        todosFor(~eventType="OrderPlaced", ~recipientId=customerId, ~orderId)
      | OrderShipped({orderId, customerId}) =>
        todosFor(~eventType="OrderShipped", ~recipientId=customerId, ~orderId)
      | NotificationRequested(_)
      | NotificationSuppressed(_)
      | NotificationUndeliverable(_)
      | NotificationDeferred(_) => []
      }

    let resolve = event =>
      switch event {
      | NotificationRequested({reference})
      | NotificationSuppressed({reference})
      | NotificationUndeliverable({reference})
      | NotificationDeferred({reference}) =>
        Some(reference)
      | OrderPlaced(_)
      | OrderShipped(_) => None
      }
  },
)

let mappings: array<module(Mapping)> = [module(FromOrderingDcb)]

let process = (id, item: NotificationIntake.todoItem) =>
  switch defaultRules->Rule.byId(item.ruleId) {
  // A rule this build no longer carries. Its rows retry and are abandoned in
  // `onExhausted`, which is what a deployment that dropped a rule asked for.
  | None => None
  | Some(rule) =>
    let payload = item->Reventless.Util_Sury.toJson(NotificationIntake.todoItemSchema)
    switch (Rule.matches(rule.filter, ~payload), Rule.recipientOf(rule, ~payload)) {
    | (false, _) | (_, None) => None
    | (true, Some(recipientId)) =>
      let (subject, body) = Rule.compose(rule, ~payload, ~schema=NotificationIntake.todoItemSchema)
      Some((
        recipientId,
        NotificationIntake.RequestNotification({
          recipientId,
          category: NotificationPreferences_Behavior.categoryOf(rule.category),
          reference: id,
          subjectType: rule.subjectType,
          subjectRef: Rule.subjectOf(rule, ~payload),
          subject,
          body,
          sourceId: Rule.sourceId(rule),
          // This relay IS the compiled table, so every request it makes is the
          // default one — the arm that yields when somebody else claims the source.
          origin: Default,
        }),
      ))
    }
  }

// Nothing to say. A relay that gave up published no command, so the notification
// competency never heard of the occurrence — and a delivery-failed fact for a
// notification nobody requested would put a row in the log for something that
// was never attempted.
let onExhausted = (_id, _item) => None
