// NotificationIntake AutomationSlice.
//
// Half of the graft point: it turns this host's occurrences into requests to
// notify somebody about them. The other half is `AnnounceRecipientContact`,
// which relays who that somebody is reachable at.
//
// Everything downstream is host-free — `NotificationPreferences` decides and
// `SendNotification` delivers, neither knowing what an order is. This file is
// where "a placed order is an OrderConfirmation, a shipped one is a
// ShippingUpdate, and here is what each says" is written down, which is why it
// is a file a graft has to be given rather than handed whole.

@@reventless.spec

// The row a rule composes from. It carries the rule's id rather than a kind of
// occurrence: the rule holds the category, the subject and the wording, so a
// second notifiable event is a second entry in the table next door.
//
// It is also the payload the wording is rendered against, so every field here is
// a path a template may name — `{{ orderId }}`.
@schema
type todoItem = {ruleId: string, recipientId: string, orderId: string}

@schema
type command =
  RequestNotification({
    recipientId: string,
    category: NotificationPreferences.category,
    reference: string,
    subjectType: string,
    subjectRef: string,
    subject: string,
    body: string,
    sourceId: string,
    origin: NotificationPreferences.origin,
  })

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "NotificationPreferences"
