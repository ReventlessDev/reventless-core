// NotificationDeliveries StateViewSliceStream.
//
// What was decided and what became of it, one row per notification. Trait-owned:
// the host contributes no field to it, which is the half of this competency the
// first two traits do not have — their status lives on the host's own row.
//
// The framework's outbound TODO already tracks Pending / Completed / Abandoned
// for the send. This view is the domain-visible answer instead: it starts at the
// decision, so a notification that was never sent because the recipient said no
// has a row here and no row there.

@@reventless.spec

@schema
type outcome =
  | Requested
  | Delivered
  // The recipient's decision. Not a failure, and the reason this is a lifecycle
  // rather than a boolean beside one.
  | @retired Suppressed
  // Nobody could be reached — no address on file for a channel they wanted.
  | Undeliverable
  | Failed

@schema
type state = {
  reference: string,
  // Whose notification this is. A recipient reading this view sees only their
  // own rows; an operator sees all of them.
  @owner recipientId: string,
  category: NotificationPreferences.category,
  @lifecycle outcome: outcome,
  // Empty until a channel was actually chosen — a suppressed notification never
  // picked one, and naming one anyway would claim a decision that was not made.
  channel: string,
  // Where it was actually sent: the inbox, the number, the device token. Whatever
  // the chosen channel addresses, which is why this is one field and not three —
  // the channel beside it says how to read it.
  //
  // Recorded rather than looked up, and that is the point of keeping it here. The
  // directory holds the address of *record*, which changes; this is the address a
  // message went to at the time. A support conversation about a confirmation
  // nobody received is about the second, and joining to the first would answer a
  // different question convincingly.
  //
  // Empty on the same terms as `channel` — a notification that was suppressed, or
  // that had no address to reach, never had one.
  address: string,
  // The provider's own id once it accepted, or the reason it did not. One field
  // because exactly one of them is ever true, and the outcome says which.
  detail: string,
  decidedAt: @s.matches(Reventless.DateTime.string) string,
  settledAt: @s.matches(Reventless.DateTime.string) string,
}

@schema
type consumedEvent =
  | NotificationRequested({
      recipientId: string,
      category: NotificationPreferences.category,
      reference: string,
      channel: NotificationPreferences.channel,
      address: string,
    })
  | NotificationSuppressed({
      recipientId: string,
      category: NotificationPreferences.category,
      reference: string,
    })
  | NotificationUndeliverable({
      recipientId: string,
      category: NotificationPreferences.category,
      reference: string,
    })
  | NotificationDelivered({recipientId: string, reference: string, providerRef: string})
  | NotificationFailed({recipientId: string, reference: string, reason: string})
