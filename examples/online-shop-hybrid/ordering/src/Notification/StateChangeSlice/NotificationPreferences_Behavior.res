@@reventless.behavior

// The directory, the matrix and the dispatch decision are the trait's; this file
// is the mapping onto them plus the two things the trait has no opinion about —
// which kinds this shop offers, and whether an unheard-from shopper gets them.
module Rules = TraitNotification.Notification_Rules

// Whether a recipient who has said nothing should be notified. Per category,
// never globally: a confirmation is one they asked for by placing the order, and
// withholding it until they opt in would be a broken shop; marketing is the
// opposite, and one global default forces both onto whichever answer is worse for
// the other.
//
// Email only. A channel a shopper has not chosen is not a channel they gave an
// address for, so defaulting SMS on would mean guessing where to send.
let posture = (category: string, channel: Rules.channel) =>
  switch (category, channel) {
  | ("OrderConfirmation", Email)
  | ("ShippingUpdate", Email) => true
  | _ => false
  }

let categoryKey = (category: category) =>
  switch category {
  | OrderConfirmation => "OrderConfirmation"
  | ShippingUpdate => "ShippingUpdate"
  | Marketing => "Marketing"
  }

let categoryOf = (key: string) =>
  switch key {
  | "ShippingUpdate" => ShippingUpdate
  | "Marketing" => Marketing
  // The transactional default. A key this build does not know can only come from
  // an event an older or newer version of this slice wrote, and confirming an
  // order the shopper placed is the safer of the two ways to be wrong.
  | _ => OrderConfirmation
  }

let channelKey = (channel: channel): Rules.channel =>
  switch channel {
  | Email => Email
  | Sms => Sms
  | Push => Push
  }

let channelOf = (channel: Rules.channel): channel =>
  switch channel {
  | Email => Email
  | Sms => Sms
  | Push => Push
  }

// The trait's own value, refolded per decision. The host stores nothing else:
// what the shop knows about a recipient's notification preferences IS the trait's
// directory, so a second record beside it would be a second source of truth.
type state = Rules.t

let initialState = Rules.empty

let evolve = (state, event: consumedEvent) =>
  switch event {
  | RecipientAnnounced({email}) => state->Rules.evolve(Announced({channel: Email, address: email}))
  | NotificationSubscribed({category, channel}) =>
    state->Rules.evolve(Subscribed({category: categoryKey(category), channel: channelKey(channel)}))
  | NotificationUnsubscribed({category, channel}) =>
    state->Rules.evolve(
      Unsubscribed({category: categoryKey(category), channel: channelKey(channel)}),
    )
  }

// The trait decides; this names what it decided in the shop's own vocabulary.
let named = (recipientId, fact: Rules.fact) =>
  switch fact {
  | Announced({address}) => RecipientAnnounced({recipientId, email: address})
  | Subscribed({category, channel}) =>
    NotificationSubscribed({
      recipientId,
      category: categoryOf(category),
      channel: channelOf(channel),
    })
  | Unsubscribed({category, channel}) =>
    NotificationUnsubscribed({
      recipientId,
      category: categoryOf(category),
      channel: channelOf(channel),
    })
  | Requested({category, reference, channel, address}) =>
    NotificationRequested({
      recipientId,
      category: categoryOf(category),
      reference,
      channel: channelOf(channel),
      address,
      // Composed by the requester and carried through untouched — the trait has
      // no opinion about wording or about what an occurrence is, so neither the
      // sentence nor the subject is on its fact. All four ride on the command and
      // are put back in `decide`.
      subjectType: "",
      subjectRef: "",
      subject: "",
      body: "",
    })
  | Suppressed({category, reference}) =>
    NotificationSuppressed({
      recipientId,
      category: categoryOf(category),
      reference,
      subjectType: "",
      subjectRef: "",
    })
  | Undeliverable({category, reference}) =>
    NotificationUndeliverable({
      recipientId,
      category: categoryOf(category),
      reference,
      subjectType: "",
      subjectRef: "",
    })
  }

let through = (state, recipientId, op) =>
  switch state->Rules.decide(op, ~posture) {
  | Ok(facts) => Ok(facts->Array.map(named(recipientId, _)))
  | Error(#RecipientUnknown) => Error(RecipientUnknown)
  }

let decide = (state, command) =>
  switch command {
  | AnnounceRecipient({recipientId, email}) =>
    through(state, recipientId, Announce({channel: Email, address: email}))
  | Subscribe({recipientId, category, channel}) =>
    through(state, recipientId, Subscribe({category: categoryKey(category), channel: channelKey(channel)}))
  | Unsubscribe({recipientId, category, channel}) =>
    through(state, recipientId, Unsubscribe({category: categoryKey(category), channel: channelKey(channel)}))

  // The one arm the mapping cannot be pure about: the words and the subject
  // belong to the requester, and the trait's facts carry neither, because a trait
  // has no business holding a sentence and refuses to know what an occurrence is.
  // So the facts are named as usual and both are put back on the way out.
  //
  // All three outcomes get the subject, not just the sent one: what a suppressed
  // or undeliverable notification was about is exactly what makes those rows
  // worth reading.
  | RequestNotification({recipientId, category, reference, subjectType, subjectRef, subject, body}) =>
    through(state, recipientId, Request({category: categoryKey(category), reference}))->Result.map(
      events =>
        events->Array.map(event =>
          switch event {
          | NotificationRequested(fields) =>
            NotificationRequested({...fields, subjectType, subjectRef, subject, body})
          | NotificationSuppressed(fields) =>
            NotificationSuppressed({...fields, subjectType, subjectRef})
          | NotificationUndeliverable(fields) =>
            NotificationUndeliverable({...fields, subjectType, subjectRef})
          | other => other
          }
        ),
    )

  // Reported by the send slice once the provider has settled. No rule to state —
  // the outcome is whatever the provider said — so these stay here rather than
  // being pushed through a trait that would only pass them along.
  | RecordDelivery({recipientId, reference, providerRef}) =>
    Ok([NotificationDelivered({recipientId, reference, providerRef})])
  | RecordDeliveryFailure({recipientId, reference, reason}) =>
    Ok([NotificationFailed({recipientId, reference, reason})])
  }
