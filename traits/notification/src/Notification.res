/**
The host contract of the notification trait: a per-recipient contact directory, a
kind × channel subscription matrix, and the decision to send, suppress or record
a message as undeliverable.

Like the attachments trait and unlike the geocoding one, the graft *is* a
StateChangeSlice of the host, so the contract is over that slice. Unlike either,
this trait **brings its own components** rather than adding arms to something the
host already had — the slice, the send, and both views are its own, and only the
two relays that feed it are shaped by the host.

The rules live in `Notification_Rules` and are asserted through a host by
`Notification_Conformance`; the spec surface the host maps onto them is written by
`Notification_Scaffold`.

## What this trait refuses to know

What an occurrence *is*. It is told a recipient, a kind, and a reference; it is
never told there was an order. That is why the two relays are the only files a
graft has to be given, and everything else can be handed over whole.
*/

/**
This trait's own account of itself — see `AddressGeocoding.declaration` for why the
version is read rather than written.

`SelfContained` is the whole reason this specimen was built third: it brings its own
components and grafts by reading host events alone, writing nothing back. The two
earlier traits share a posture; this one is the reason `posture` exists.
*/
let declaration: Reventless.Trait.t = {
  trait: "@reventlessdev/trait-notification",
  version: Reventless.PackageVersion.fromModuleUrl(%raw(`import.meta.url`)),
  posture: SelfContained,
}

/**
The platform capabilities a host of this trait needs, for its send slice's
`capabilityNeeds` to name.

Exported as a value rather than written into the emitted text, for the reason the
geocoding trait exports its own: forgetting it is silent. An unprovisioned sender
answers `Unavailable`, every send retries its budget, and every message this host
was ever asked for is recorded as failed — a permanent wrong outcome with no error
anywhere. A host that spells this gets a deploy-time refusal instead.

It is also what lets a listing say what the trait needs without running the
emitter: a literal buried in generated text is not a fact anything can read.
*/
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = [Messaging]

/** One host, bound.

    `category` is abstract: a host's kinds are its own vocabulary, and the rules
    hold for any of them. `posture` is the host's answer to the one question the
    rules cannot settle — whether an unheard-from recipient should be notified —
    and it is a member rather than a constant because it is per category. */
module type Binding = {
  /** The host's own kind-of-notification type. */
  type category
  /** Two kinds that differ in posture: one an unheard-from recipient gets, and
      one they do not. A host with only transactional kinds cannot satisfy this,
      which is the suite refusing to certify a matrix with nothing to choose. */
  let transactional: category
  let optional: category

  module Spec: ReventlessGwt.Behavior_GWT.BehaviorSpec
  module Behavior: ReventlessGwt.Behavior_GWT.Behavior with module Spec = Spec

  /** History that brings the recipient into existence with nothing on file. */
  let created: array<Spec.consumedEvent>

  /** The competency's own facts, as the slice consumes them. */
  let announcedC: string => Spec.consumedEvent
  let subscribedC: (category, Notification_Rules.channel) => Spec.consumedEvent
  let unsubscribedC: (category, Notification_Rules.channel) => Spec.consumedEvent

  let announce: string => Spec.command
  let subscribe: (category, Notification_Rules.channel) => Spec.command
  let unsubscribe: (category, Notification_Rules.channel) => Spec.command
  /** `reference` is the requester's key, echoed on whichever outcome follows. */
  let request: (category, string) => Spec.command

  /** The competency's facts, as the slice emits them. */
  let announced: string => Spec.event
  let subscribed: (category, Notification_Rules.channel) => Spec.event
  let unsubscribed: (category, Notification_Rules.channel) => Spec.event
  let requested: (category, string, Notification_Rules.channel, string) => Spec.event
  let suppressed: (category, string) => Spec.event
  let undeliverable: (category, string) => Spec.event

  /** The refusal for managing preferences for somebody nobody has announced. */
  let recipientUnknown: Spec.error

  /** An address the host's announce command accepts, and the channel it lands on.
      Email today for every host; named rather than assumed so the suite asserts
      against the channel the host actually announces. */
  let addressA: string
  let addressB: string
  let announcedChannel: Notification_Rules.channel
  /** A channel the host announces no address for, so the suite can tell
      "unreachable" apart from "not wanted". `None` for a host that announces
      every channel it offers — the two assertions that need it are skipped. */
  let unreachableChannel: option<Notification_Rules.channel>
}
