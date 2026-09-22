// An order that is placed and then ships is TWO notifications, and the reference
// key is the only thing keeping them apart — it is this view's row key, the
// intake relay's TODO id, and how that TODO row is resolved, all at once.
//
// Driven by the relay's own rule table rather than by string literals: a change
// that made the reference the bare order id would collapse both notifications
// onto one row and let the second outcome overwrite the first, with no error
// anywhere. That is the failure these two scenarios exist to make loud.

@@reventless.gwt

open OrderingExamples

module Rule = TraitNotification.Notification_Rule

// A rule id that no longer exists yields a reference matching neither expected
// key, so the literals below fail rather than the lookup passing quietly.
let referenceOf = ruleId =>
  NotificationIntake_Automation.defaultRules
  ->Rule.byId(ruleId)
  ->Option.mapOr("no such rule", rule => Rule.reference(rule, ~subject="o1"))

let confirm = referenceOf("confirm")
let ship = referenceOf("ship")

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
  decidedAt: "1970-01-01T00:00:00Z",
  settledAt,
}

describe("NotificationDeliveries StateViewSliceStream", () => {
  // The expected keys are written out rather than taken from the relay, and that
  // is the whole point: a dict keyed by the derived values would collapse to one
  // entry exactly when the relay does, and the scenario would keep passing while
  // a notification went missing. Spelling them out also pins the format, which
  // is load-bearing in three places — this row key, the relay's TODO id, and how
  // that TODO row is resolved.
  // scenario-id: 3cc93af9-eecb-4b91-a669-bd0d2824b2cd
  test("placing and then shipping one order leaves two rows", () =>
    givenEvents([])
    ->whenEvents([
      NotificationRequested({
        recipientId: customerRef,
        category: NotificationPreferences.OrderConfirmation,
        reference: confirm,
        channel: NotificationPreferences.Email,
        subjectType: orderSubject,
        subjectRef: orderRef,
        origin: NotificationPreferences.Default,
      }),
      NotificationRequested({
        recipientId: customerRef,
        category: NotificationPreferences.ShippingUpdate,
        reference: ship,
        channel: NotificationPreferences.Email,
        subjectType: orderSubject,
        subjectRef: orderRef,
        origin: NotificationPreferences.Default,
      }),
    ])
    ->thenAllStates(
      Dict.fromArray([
        (
          "confirm:o1",
          [row(NotificationPreferences.OrderConfirmation, confirm, Requested, "", None)],
        ),
        ("ship:o1", [row(NotificationPreferences.ShippingUpdate, ship, Requested, "", None)]),
      ]),
    )
  )

  // The half that fails silently. One outcome must close one row: if the two
  // notifications shared a key, delivering the confirmation would also settle the
  // shipping update, and the shop would report a message it never sent.
  // scenario-id: d4fe96b7-929d-4515-a622-8242be3c1f91
  test("settling the confirmation leaves the shipping update still open", () =>
    givenEvents([
      NotificationRequested({
        recipientId: customerRef,
        category: NotificationPreferences.OrderConfirmation,
        reference: confirm,
        channel: NotificationPreferences.Email,
        subjectType: orderSubject,
        subjectRef: orderRef,
        origin: NotificationPreferences.Default,
      }),
      NotificationRequested({
        recipientId: customerRef,
        category: NotificationPreferences.ShippingUpdate,
        reference: ship,
        channel: NotificationPreferences.Email,
        subjectType: orderSubject,
        subjectRef: orderRef,
        origin: NotificationPreferences.Default,
      }),
    ])
    ->whenEvent(
      NotificationDelivered({
        recipientId: customerRef,
        reference: confirm,
        providerRef: "provider-1",
      }),
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
              Some("1970-01-01T00:00:00Z"),
            ),
          ],
        ),
        (ship, [row(NotificationPreferences.ShippingUpdate, ship, Requested, "", None)]),
      ]),
    )
  )
})
