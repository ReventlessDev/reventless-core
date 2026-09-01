// NotificationIntake AutomationSlice.
//
// Half of the graft point: it turns one of this host's occurrences into a
// request to notify somebody about it. The other half is
// `AnnounceRecipientContact`, which relays who that somebody is reachable at.
//
// Everything downstream is host-free — `NotificationPreferences` decides and
// `SendNotification` delivers, neither knowing what an order is. This file is
// where "a placed order is an OrderConfirmation, and here is what it says" is
// written down, which is why it is a file a graft has to be given rather than
// handed whole.

@@reventless.spec

@schema
type todoItem = {recipientId: string, orderId: string}

@schema
type command =
  RequestNotification({
    recipientId: string,
    category: NotificationPreferences.category,
    reference: string,
    subject: string,
    body: string,
  })

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "NotificationPreferences"
