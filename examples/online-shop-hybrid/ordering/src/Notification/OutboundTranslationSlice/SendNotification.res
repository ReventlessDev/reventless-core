// SendNotification OutboundTranslationSlice.
//
// Delivers a message that has already been addressed and already been decided
// on. Everything it needs is on `NotificationRequested` — the channel, the
// address as of the moment the message was composed, and the words — so this
// slice reads no state and knows nothing about who the recipient is or why they
// are being written to.
//
// It reports the settled outcome back to `NotificationPreferences`, which is
// trait-owned state. The host is still never written to, which is what makes
// this competency graftable onto a host that has nothing to say about mail.

@@reventless.spec

// Only the addressed request. The suppressed and undeliverable outcomes are
// decisions not to send, so there is nothing here to do about them — they are
// the delivery view's business, not this slice's.
@schema
type consumedEvent =
  | NotificationRequested({
      recipientId: string,
      reference: string,
      channel: NotificationPreferences.channel,
      address: string,
      subject: string,
      body: string,
    })

@schema
type outboundItem = {
  recipientId: string,
  reference: string,
  channel: NotificationPreferences.channel,
  address: string,
  subject: string,
  body: string,
}

@schema
type inboundCommand =
  | RecordDelivery({recipientId: string, reference: string, providerRef: string})
  | RecordDeliveryFailure({recipientId: string, reference: string, reason: string})

// Retries are for a provider that is down, not one that has refused. The port's
// own `retriable` rule decides which is which, in the translation next door.
let maxRetries = 3
let heartbeatInterval = 60
let targetName = Some("NotificationPreferences")

// This plugin's own DCB event log — `NotificationRequested` is a DCB event.
let sourceNames: array<string> = []

// Drawn as an external box outside this plugin in the Event Graph. Named for the
// capability rather than a provider: which one is behind it is the deployment's
// decision, and this slice never learns the answer.
let externalSystem = Some("Messaging")

// Declared, so a deployment that provisions no sender fails rather than queueing
// every confirmation until it is abandoned.
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = [Messaging]

// Grafted, and this is the only record of it that survives into a deployed
// plugin — every other signal (the dependency, the spread, the rules alias, the
// conformance binding) is source-side. The value comes from the trait, so a
// rename or a removed dependency is a build error rather than a stale row.
let traits = [TraitNotification.Notification.declaration]
