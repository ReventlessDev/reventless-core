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

// Which of this host's occurrences a row stands for. The todo carries the
// occurrence, not the finished sentence: the category and the wording are chosen
// from it in one place, so a second notifiable event cannot quietly reuse the
// first one's category.
@schema
type occurrence =
  | Placed
  | Shipped

@schema
type todoItem = {recipientId: string, orderId: string, occurrence: occurrence}

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
  })

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "NotificationPreferences"
