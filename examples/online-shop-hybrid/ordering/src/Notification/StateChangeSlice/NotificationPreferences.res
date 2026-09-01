// NotificationPreferences StateChangeSlice.
//
// The notification competency's one decision point. It holds, per recipient, the
// address to reach them at and which kinds of notification they want on which
// channel, and it turns a request to notify into either an addressed message or
// a recorded reason there was none.
//
// **The address is resolved here, not carried by the occurrence.** `OrderPlaced`
// names a customer, not an inbox — and putting the inbox in it would freeze a
// mutable fact into an append-only log, so a customer who changed their email
// would have old orders confirmed to the old one. The directory below is folded
// from announcements the host already publishes (`Registered`, `EmailUpdated`,
// relayed by `NotificationIntake`), and the address is read at the moment the
// message is composed. That is the address of record.
//
// So an unregistered recipient is not a hole: a customer who registered is in
// the directory because registering announced them, not because they visited a
// preference screen.

@@reventless.spec

// What a recipient subscribes to: a KIND of notification, not a raw event name.
// A preference screen listing event types would be a log dump; these are the
// choices a person can hold an opinion about.
@schema
type category =
  | OrderConfirmation
  | ShippingUpdate
  | Marketing

// How they are reached. Mirrors `Reventless.Messaging.channel` — the domain
// declares its own so the vocabulary carries a schema and survives on the wire;
// `SendNotification_Translation` is the one place the two are mapped.
@schema
type channel =
  | Email
  | Sms
  | Push

// Its own past facts, and nothing else. What lets one component hold the
// directory and make the dispatch decision without either half reaching for the
// other's state.
@schema
type consumedEvent =
  | RecipientAnnounced({recipientId: string, email: string})
  | NotificationSubscribed({recipientId: string, category: category, channel: channel})
  | NotificationUnsubscribed({recipientId: string, category: category, channel: channel})

@schema
type command =
  // Relayed from the host's own announcements, never called by a client — a
  // caller who could register someone else's address would be redirecting their
  // mail.
  | @noApi AnnounceRecipient({recipientId: string, email: string})
  // The client door. A recipient manages one cell of their kind × channel matrix
  // at a time; the screen renders the matrix from the read model beside it.
  // `@owner` is what stops them managing somebody else's: the resolver overwrites
  // the field with the authenticated caller before the command is published.
  | Subscribe({@owner recipientId: string, category: category, channel: channel})
  | Unsubscribe({@owner recipientId: string, category: category, channel: channel})
  // Also relayed: a notifiable thing happened. `reference` is the requester's own
  // key for it, echoed back on whichever outcome follows, so the automation that
  // asked can tell its work is finished. Opaque here on purpose — this slice must
  // not know what an order is.
  | @noApi
  RequestNotification({
      recipientId: string,
      category: category,
      reference: string,
      subject: string,
      body: string,
    })
  // Reported by the send slice once the provider has settled. Trait-owned state,
  // so this is not a host side effect — the host is never written to at all.
  | @noApi RecordDelivery({recipientId: string, reference: string, providerRef: string})
  | @noApi RecordDeliveryFailure({recipientId: string, reference: string, reason: string})

@schema
type error =
  // Subscribing someone the directory has never heard of. A client-facing
  // refusal, unlike the relayed commands, which record a fact instead: a person
  // is at the other end of this one and can be told.
  | RecipientUnknown

@schema
type event =
  | RecipientAnnounced({recipientId: string, email: string})
  | NotificationSubscribed({recipientId: string, category: category, channel: channel})
  | NotificationUnsubscribed({recipientId: string, category: category, channel: channel})
  // The addressed message. `address` is the snapshot the send slice delivers to,
  // and the reason this event exists rather than the send slice reading state.
  | NotificationRequested({
      recipientId: string,
      category: category,
      reference: string,
      channel: channel,
      address: string,
      subject: string,
      body: string,
    })
  // Both of the ways not to send, kept apart because they mean opposite things.
  // A recipient who declined is the system working; a recipient with no address
  // is the system missing something, and one fact for both would hide every
  // delivery gap behind a legitimate preference.
  | NotificationSuppressed({recipientId: string, category: category, reference: string})
  | NotificationUndeliverable({recipientId: string, category: category, reference: string})
  | NotificationDelivered({recipientId: string, reference: string, providerRef: string})
  | NotificationFailed({recipientId: string, reference: string, reason: string})
