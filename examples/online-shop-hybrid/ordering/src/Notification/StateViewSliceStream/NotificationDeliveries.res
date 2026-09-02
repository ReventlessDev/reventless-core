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
  //
  // `@scan`/`@scanSort` declare the filter and sort surface the key-field
  // inference used to supply on its own. With no `@id` here it picked this field
  // for being the only one named `*Id` — so a second such name anywhere on the
  // row silently took the recipient filter and the whole orderBy off the list
  // query. Declared, the surface no longer depends on that count.
  @owner @scan @scanSort recipientId: string,
  category: NotificationPreferences.category,
  @lifecycle outcome: outcome,
  // Empty until a channel was actually chosen — a suppressed notification never
  // picked one, and naming one anyway would claim a decision that was not made.
  channel: string,
  // What the notification was about. Without these a row is only readable against
  // `reference`, whose format is the requester's private business — so the view
  // could say a notification happened and how it ended, but not what it concerned.
  // `subjectType` is the component's registered name, `subjectRef` that row's id.
  // Both may be empty: a fabricated subject is worse than an absent one.
  //
  // Named `*Ref` rather than `*Id` because two inferences read id fields by name
  // — see `recipientId` above, and the DCB partition on the slice that writes it.
  //
  // No address here, deliberately. Where a message actually went is on
  // `NotificationRequested`, reachable through the per-log event history with its
  // audit metadata: available to an investigation, not to every reader of a view.
  subjectType: string,
  subjectRef: string,
  // The provider's own id once it accepted, or the reason it did not. One field
  // because exactly one of them is ever true, and the outcome says which.
  detail: string,
  decidedAt: @s.matches(Reventless.DateTime.string) string,
  settledAt: @s.matches(Reventless.DateTime.string) string,
}

// `address` is on the published event and is not read here — a consumed variant
// declares only what the projection uses, so leaving it out is what keeps it off
// the row.
@schema
type consumedEvent =
  | NotificationRequested({
      recipientId: string,
      category: NotificationPreferences.category,
      reference: string,
      channel: NotificationPreferences.channel,
      subjectType: string,
      subjectRef: string,
    })
  | NotificationSuppressed({
      recipientId: string,
      category: NotificationPreferences.category,
      reference: string,
      subjectType: string,
      subjectRef: string,
    })
  | NotificationUndeliverable({
      recipientId: string,
      category: NotificationPreferences.category,
      reference: string,
      subjectType: string,
      subjectRef: string,
    })
  | NotificationDelivered({recipientId: string, reference: string, providerRef: string})
  | NotificationFailed({recipientId: string, reference: string, reason: string})
