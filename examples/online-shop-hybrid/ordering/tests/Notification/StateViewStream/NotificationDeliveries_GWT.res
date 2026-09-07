// An order that is placed and then ships is TWO notifications, and the reference
// key is the only thing keeping them apart — it is this view's row key, the
// intake relay's TODO id, and how that TODO row is resolved, all at once.
//
// Driven by the relay's own rule table rather than by string literals: a change
// that made the reference the bare order id would collapse both notifications
// onto one row and let the second outcome overwrite the first, with no error
// anywhere. That is the failure these two scenarios exist to make loud.

@@reventless.gwt

module Rule = TraitNotification.Notification_Rule

// A rule id that no longer exists yields a reference matching neither expected
// key, so the literals below fail rather than the lookup passing quietly.
let referenceOf = ruleId =>
  NotificationIntake_Automation.defaultRules
  ->Rule.byId(ruleId)
  ->Option.mapOr("no such rule", rule => Rule.reference(rule, ~subject="o1"))

let confirm = referenceOf("confirm")
let ship = referenceOf("ship")

let requested = (category, reference) =>
  NotificationRequested({
    recipientId: "c1",
    category,
    reference,
    channel: NotificationPreferences.Email,
    subjectType: "Order",
    subjectRef: "o1",
    origin: NotificationPreferences.Default,
  })

let row = (category, reference, outcome, detail, settledAt): state => {
  reference,
  recipientId: "c1",
  category,
  outcome,
  channel: "Email",
  subjectType: "Order",
  subjectRef: "o1",
  origin: "Default",
  detail,
  decidedAt: "time",
  settledAt,
}

describe("NotificationDeliveries StateViewSliceStream", () => {
  // The expected keys are written out rather than taken from the relay, and that
  // is the whole point: a dict keyed by the derived values would collapse to one
  // entry exactly when the relay does, and the scenario would keep passing while
  // a notification went missing. Spelling them out also pins the format, which
  // is load-bearing in three places — this row key, the relay's TODO id, and how
  // that TODO row is resolved.
  test("placing and then shipping one order leaves two rows", () =>
    givenEvents([])
    ->whenEvents([
      requested(NotificationPreferences.OrderConfirmation, confirm),
      requested(NotificationPreferences.ShippingUpdate, ship),
    ])
    ->thenAllStates(
      Dict.fromArray([
        ("confirm:o1", [row(NotificationPreferences.OrderConfirmation, confirm, Requested, "", "")]),
        ("ship:o1", [row(NotificationPreferences.ShippingUpdate, ship, Requested, "", "")]),
      ]),
    )
  )

  // The half that fails silently. One outcome must close one row: if the two
  // notifications shared a key, delivering the confirmation would also settle the
  // shipping update, and the shop would report a message it never sent.
  test("settling the confirmation leaves the shipping update still open", () =>
    givenEvents([
      requested(NotificationPreferences.OrderConfirmation, confirm),
      requested(NotificationPreferences.ShippingUpdate, ship),
    ])
    ->whenEvent(
      NotificationDelivered({recipientId: "c1", reference: confirm, providerRef: "provider-1"}),
    )
    ->thenAllStates(
      Dict.fromArray([
        (
          confirm,
          [
            row(
              NotificationPreferences.OrderConfirmation,
              confirm,
              Delivered,
              "provider-1",
              "time",
            ),
          ],
        ),
        (ship, [row(NotificationPreferences.ShippingUpdate, ship, Requested, "", "")]),
      ]),
    )
  )
})
