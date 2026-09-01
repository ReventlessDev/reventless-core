@@reventless.behavior

// One recipient's row: where to reach them, and the cells of the kind × channel
// matrix they have an explicit opinion about. Only explicit choices are stored —
// the rest is `defaultPosture`, so a category added later starts at its intended
// posture for everybody instead of at whatever an absent record decodes to.
type choice = {category: category, channel: channel, enabled: bool}

type state = {email: option<string>, choices: array<choice>}

let initialState = {email: None, choices: []}

// Whether a recipient who has said nothing should be notified.
//
// Per category, never globally. A transactional confirmation is one they asked
// for by placing the order — withholding it until they opt in would be a broken
// shop, not a courtesy — while marketing is the opposite, and one global default
// forces both onto whichever answer is worse for the other.
//
// Email only: a channel a recipient has not chosen is not a channel they gave an
// address for, so defaulting SMS on would mean guessing where to send.
let defaultPosture = (category, channel) =>
  switch (category, channel) {
  | (OrderConfirmation, Email)
  | (ShippingUpdate, Email) => true
  | (OrderConfirmation | ShippingUpdate, Sms | Push)
  | (Marketing, _) => false
  }

let enabled = (state, category, channel) =>
  switch state.choices->Array.find(c => c.category == category && c.channel == channel) {
  | Some({enabled}) => enabled
  | None => defaultPosture(category, channel)
  }

let withChoice = (state, category, channel, isEnabled) => {
  ...state,
  choices: Array.concat(
    state.choices->Array.filter(c => !(c.category == category && c.channel == channel)),
    [{category, channel, enabled: isEnabled}],
  ),
}

// The address for a channel, or `None` when the directory holds none.
//
// One arm has an answer and two do not, and that asymmetry is the honest state
// of this trait rather than an oversight: an email is one address per person,
// while push is one *per device* — a set that churns as installs come and go —
// and neither a number nor a device token is announced by anything the host
// publishes today. A recipient who enabled one of those has said what they want
// and cannot be served, which is recorded as undeliverable below rather than
// quietly skipped.
let addressFor = (state, channel) =>
  switch channel {
  | Email => state.email
  | Sms | Push => None
  }

let evolve = (state, event: consumedEvent) =>
  switch event {
  | RecipientAnnounced({email}) => {...state, email: Some(email)}
  | NotificationSubscribed({category, channel}) => withChoice(state, category, channel, true)
  | NotificationUnsubscribed({category, channel}) => withChoice(state, category, channel, false)
  }

let allChannels = [Email, Sms, Push]

let decide = (state, command) =>
  switch command {
  // Idempotent, which it can afford to be: the relay that publishes this is an
  // outbound slice, whose row completes on the publish rather than on an event
  // coming back. A re-announced address that is already the one on file is work
  // already done, and recording it again would put a change in the log where
  // nothing changed.
  | AnnounceRecipient({recipientId, email}) =>
    state.email == Some(email) ? Ok([]) : Ok([RecipientAnnounced({recipientId, email})])

  // A person is at the other end of these two, so a recipient the directory has
  // never heard of is refused rather than recorded: they can be told, and told
  // is better than a fact nobody reads.
  | Subscribe({recipientId, category, channel}) =>
    switch state.email {
    | None => Error(RecipientUnknown)
    | Some(_) =>
      enabled(state, category, channel)
        ? Ok([])
        : Ok([NotificationSubscribed({recipientId, category, channel})])
    }
  | Unsubscribe({recipientId, category, channel}) =>
    switch state.email {
    | None => Error(RecipientUnknown)
    | Some(_) =>
      enabled(state, category, channel)
        ? Ok([NotificationUnsubscribed({recipientId, category, channel})])
        : Ok([])
    }

  // The dispatch decision, and the only place the directory and the matrix are
  // read together. Exactly one outcome is published whatever happens, because
  // the relay upstream resolves on it — an outcome-free path is a row that
  // retries until it is abandoned.
  //
  // No dedupe on `reference`: the relay is a TODO list, which publishes once per
  // item and resolves on the outcome, so a second request for one occurrence
  // would be the framework's guarantee failing rather than this rule's. Keeping
  // every reference ever seen in a snapshotted state to re-check that guarantee
  // would cost more than it buys.
  | RequestNotification({recipientId, category, reference, subject, body}) =>
    switch state.email {
    | None => Ok([NotificationUndeliverable({recipientId, category, reference})])
    | Some(_) =>
      let addressed =
        allChannels
        ->Array.filter(channel => enabled(state, category, channel))
        ->Array.filterMap(channel =>
          addressFor(state, channel)->Option.map(address => NotificationRequested({
            recipientId,
            category,
            reference,
            channel,
            address,
            subject,
            body,
          }))
        )
      switch addressed {
      // Nothing to send, and the two reasons are not the same fact. Every channel
      // switched off is the recipient's decision working; every enabled channel
      // lacking an address is this trait falling short, and reporting both as
      // "suppressed" would hide the second behind the first for good.
      | [] =>
        allChannels->Array.some(channel => enabled(state, category, channel))
          ? Ok([NotificationUndeliverable({recipientId, category, reference})])
          : Ok([NotificationSuppressed({recipientId, category, reference})])
      | events => Ok(events)
      }
    }

  | RecordDelivery({recipientId, reference, providerRef}) =>
    Ok([NotificationDelivered({recipientId, reference, providerRef})])
  | RecordDeliveryFailure({recipientId, reference, reason}) =>
    Ok([NotificationFailed({recipientId, reference, reason})])
  }
