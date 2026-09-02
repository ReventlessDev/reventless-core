// The notification trait's own suite, run against this host's graft.
//
// Everything here is the trait's: the directory, the fallback to this shop's
// posture, and the three different facts that mean "nothing was sent". None of it
// is restated in `NotificationPreferences_GWT.res`, which keeps only what the
// trait has no opinion on.

module Binding = {
  type category = NotificationPreferences.category
  let transactional: category = OrderConfirmation
  // Off by posture for a shopper who has said nothing — which is what makes the
  // opt-in half of the matrix assertable.
  let optional: category = Marketing

  module Spec = NotificationPreferences
  module Behavior = NotificationPreferences_Behavior

  // A DCB slice's entity comes into existence with its first fact, so there is
  // no creation event to seed: an unannounced recipient is one with no history.
  let created: array<Spec.consumedEvent> = []

  let recipientId = "recipient-1"

  // Annotated: this slice reads back exactly what it writes, so each of these
  // three names a constructor of both unions and the later declaration would
  // otherwise win. The `C` half is the history side.
  let announcedC = (email): Spec.consumedEvent => RecipientAnnounced({recipientId, email})
  let subscribedC = (category, channel): Spec.consumedEvent =>
    NotificationSubscribed({
      recipientId,
      category,
      channel: Behavior.channelOf(channel),
    })
  let unsubscribedC = (category, channel): Spec.consumedEvent =>
    NotificationUnsubscribed({
      recipientId,
      category,
      channel: Behavior.channelOf(channel),
    })

  let announce = email => Spec.AnnounceRecipient({recipientId, email})
  let subscribe = (category, channel) =>
    Spec.Subscribe({recipientId, category, channel: Behavior.channelOf(channel)})
  let unsubscribe = (category, channel) =>
    Spec.Unsubscribe({recipientId, category, channel: Behavior.channelOf(channel)})
  // The wording and the subject are this host's and the trait carries neither, so
  // the suite supplies whatever it likes and asserts nothing about them.
  let request = (category, reference) =>
    Spec.RequestNotification({
      recipientId,
      category,
      reference,
      subjectType: "Order",
      subjectRef: "o1",
      subject: "subject",
      body: "body",
    })

  let announced = email => Spec.RecipientAnnounced({recipientId, email})
  let subscribed = (category, channel) =>
    Spec.NotificationSubscribed({recipientId, category, channel: Behavior.channelOf(channel)})
  let unsubscribed = (category, channel) =>
    Spec.NotificationUnsubscribed({recipientId, category, channel: Behavior.channelOf(channel)})
  let requested = (category, reference, channel, address) =>
    Spec.NotificationRequested({
      recipientId,
      category,
      reference,
      channel: Behavior.channelOf(channel),
      address,
      subjectType: "Order",
      subjectRef: "o1",
      subject: "subject",
      body: "body",
    })
  // The subject rides through the two decisions not to send as well: what a
  // suppressed or undeliverable notification was about is the whole reason those
  // rows are worth reading.
  let suppressed = (category, reference) =>
    Spec.NotificationSuppressed({
      recipientId,
      category,
      reference,
      subjectType: "Order",
      subjectRef: "o1",
    })
  let undeliverable = (category, reference) =>
    Spec.NotificationUndeliverable({
      recipientId,
      category,
      reference,
      subjectType: "Order",
      subjectRef: "o1",
    })

  let recipientUnknown = Spec.RecipientUnknown

  let addressA = "buyer@example.com"
  let addressB = "new@example.com"
  let announcedChannel: TraitNotification.Notification_Rules.channel = Email
  // This shop announces an inbox and nothing else, so SMS is a channel a shopper
  // can want and not be reached on — which is the state the undeliverable arm
  // exists for.
  let unreachableChannel = Some(TraitNotification.Notification_Rules.Sms)
}

module Conformance = TraitNotification.Notification_Conformance.Make(Binding)

Conformance.register()
