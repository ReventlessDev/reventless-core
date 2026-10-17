// MarketingDigest AutomationSlice.
//
// A digest of the shop's offers, sent to each recipient at the time of day they
// chose. The slice declares no `schedule`: every time comes from an event, one per
// recipient, keyed by their id, so the tick names whose time came.
//
// Not the notification trait's `Digest` delivery, which gathers a rule's
// occurrences into one message per window. This one has no occurrences to gather;
// it is a message the shop sends on the recipient's clock.

@@reventless.spec

@schema
type todoItem = {recipientId: string}

@schema
type command =
  | RequestNotification({
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
let targetName = "NotificationPreferences"
