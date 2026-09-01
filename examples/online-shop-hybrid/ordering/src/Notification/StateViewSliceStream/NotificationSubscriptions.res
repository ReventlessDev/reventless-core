// NotificationSubscriptions StateViewSliceStream.
//
// The read side of the kind × channel matrix — what a notification settings
// screen renders, and the second view this competency owns outright. One row per
// recipient, because that is the unit a person manages.
//
// The matrix is materialised in full rather than storing only what the recipient
// chose. A screen has to show a cell they never touched at its real setting, and
// the alternative — the client re-deriving the default posture — puts the rule in
// two places and lets them disagree.

@@reventless.spec

@schema
type subscription = {
  category: NotificationPreferences.category,
  channel: NotificationPreferences.channel,
  enabled: bool,
  // Whether an address exists for this channel. A cell a recipient can switch on
  // and never hear from is worse than one that is greyed out and says why.
  deliverable: bool,
}

@schema
type state = {
  // A recipient reads their own row and nobody else's. The same field the
  // `Subscribe` command is `@owner`-stamped on, so the read and the write agree
  // on whose preferences these are.
  @owner recipientId: string,
  @displayName email: string,
  subscriptions: array<subscription>,
}

@schema
type consumedEvent =
  | RecipientAnnounced({recipientId: string, email: string})
  | NotificationSubscribed({
      recipientId: string,
      category: NotificationPreferences.category,
      channel: NotificationPreferences.channel,
    })
  | NotificationUnsubscribed({
      recipientId: string,
      category: NotificationPreferences.category,
      channel: NotificationPreferences.channel,
    })
