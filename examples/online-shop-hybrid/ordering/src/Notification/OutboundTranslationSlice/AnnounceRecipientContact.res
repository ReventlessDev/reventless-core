// AnnounceRecipientContact OutboundTranslationSlice.
//
// The other half of the graft point: it relays this host's contact
// announcements into the notification directory, so a recipient is reachable
// because they registered rather than because they visited a settings screen.
//
// **An OutboundTranslationSlice rather than an automation, and not by
// preference.** An automation's `collect` is handed the event and the ambient
// context and nothing else, so it can only work with events that name their own
// subject. `Registered({email, address})` does not — the aggregate id is what
// addressed it — and this is the one component the framework passes a
// `~sourceId` to. Same reason the geocoding slice next door is one.
//
// It calls nothing external, which is why it declares no capability and names no
// system: the "translation" is the relay itself, and the item completes when the
// command is published rather than when an event comes back.

@@reventless.spec

// Both arms, not only registration. An address that changed and was not relayed
// leaves the directory confirming orders to the old inbox, which is the exact
// staleness the whole design exists to avoid.
@schema
type consumedEvent =
  | Registered({email: string})
  | EmailUpdated({email: string})

@schema
type outboundItem = {recipientId: string, email: string}

@schema
type inboundCommand = AnnounceRecipient({recipientId: string, email: string})

// One attempt is enough for a relay with nothing to fail against, but a budget
// of one would turn a transient publish error into a lost address. Three, and
// then the row is visible in the sweep.
let maxRetries = 3
let heartbeatInterval = 60
let targetName = Some("NotificationPreferences")

// The Customer aggregate by its Spec.name.
let sourceNames = ["Customer"]

// No external box on the Event Graph: this slice reaches nothing outside the
// plugin, and drawing one would put a system on the map that does not exist.
let externalSystem = None

// Nothing to provision. The relay is pure — a deployment could run it with no
// messaging provider at all, and the directory would still be correct.
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
