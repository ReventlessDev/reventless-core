@@reventless.projection

// Flattened for the row: the view is read by people and by a console, and a
// union to select through would buy nothing here.
let originName = (origin: NotificationPreferences.origin) =>
  switch origin {
  | Default => "Default"
  | Configured({ruleId, ruleVersion}) => `${ruleId}@${ruleVersion}`
  }

let channelName = (channel: NotificationPreferences.channel) =>
  switch channel {
  | Email => "Email"
  | Sms => "Sms"
  | Push => "Push"
  }

// A decision opens the row and a settlement closes it. `Update` rather than
// `UpdateWithDefault` on the settlements: a delivery report for a notification
// nothing decided would be a row invented from a fact that cannot exist, and
// dropping it is what makes that visible instead of fabricating a half-row.
let project = ({event, meta}) =>
  switch event {
  | NotificationRequested({recipientId, category, reference, channel, subjectType, subjectRef, origin}) => [
      Set(
        reference,
        {
          reference,
          recipientId,
          category,
          outcome: Requested,
          channel: channelName(channel),
          subjectType,
          subjectRef,
          origin: originName(origin),
          detail: "",
          decidedAt: meta.time,
          settledAt: "",
        },
      ),
    ]
  // Decided and settled in the same breath — nothing follows a decision not to
  // send, so these rows carry both timestamps from the start rather than sitting
  // open forever waiting for a settlement that is not coming.
  | NotificationSuppressed({recipientId, category, reference, subjectType, subjectRef, origin}) => [
      Set(
        reference,
        {
          reference,
          recipientId,
          category,
          outcome: Suppressed,
          channel: "",
          subjectType,
          subjectRef,
          origin: originName(origin),
          detail: "the recipient is not subscribed to this notification",
          decidedAt: meta.time,
          settledAt: meta.time,
        },
      ),
    ]
  | NotificationUndeliverable({recipientId, category, reference, subjectType, subjectRef, origin}) => [
      Set(
        reference,
        {
          reference,
          recipientId,
          category,
          outcome: Undeliverable,
          channel: "",
          subjectType,
          subjectRef,
          origin: originName(origin),
          detail: "no address on file for a channel the recipient wants",
          decidedAt: meta.time,
          settledAt: meta.time,
        },
      ),
    ]
  | NotificationDelivered({reference, providerRef}) => [
      Update(reference, state => {
        ...state,
        outcome: Delivered,
        detail: providerRef,
        settledAt: meta.time,
      }),
    ]
  | NotificationFailed({reference, reason}) => [
      Update(reference, state => {...state, outcome: Failed, detail: reason, settledAt: meta.time}),
    ]
  }
