/**
The host contract of the address-geocoding trait: what an aggregate and its
outbound slice expose so the graft rules can be checked against them. The rules —
staleness, redelivery, an outage is not a verdict, the stand-down — live in
`AddressGeocoding_Guards` and `AddressGeocoding_Translate` and are asserted through a
host by `AddressGeocoding_Conformance`; the confidence rule stays core's
(`Reventless.Geocoding`). The spec surface is scaffolded from `spec-fragments/`.
*/

/** Whether the graft reports back into its host. This trait does — the two `@noApi`
    commands — and the runner accepts nothing else yet; the flag is here so a
    competency that only observes is not mis-modelled as one that writes. */
type posture = WritesBack | Observes

/**
The platform capabilities a host of this trait needs, for its outbound slice's
`capabilityNeeds` to name.

Exported as a value rather than stated in the README because forgetting it is
silent and terminal: an unprovisioned geocoder answers `Unavailable`, the slice
retries its budget, `onExhausted` fires, and every address the host ever sees is
recorded as permanently unresolvable — correct data, a permanent wrong verdict,
no error. A host that spells this reaches a deploy-time refusal instead.
*/
let capabilityNeeds: array<Reventless.CapabilityNeed.t> = [Geocoding]

/** One host, bound. Written over an abstract `subject` (the address) so retyping it
    is a re-instantiation of this module, not a break in the trait. */
module type Binding = {
  type subject
  /** The text handed to the geocoder, and the second half of the TODO key. */
  let subjectText: subject => string
  /** Two subjects that differ, for histories in which the address changes. */
  let subjectA: subject
  let subjectB: subject

  let posture: posture

  module Spec: ReventlessGwt.Behavior_GWT.AggregateSpec
  module Behavior: Reventless.Behavior.T with module Spec = Spec

  /** History leaving the entity active at `subject` with nothing resolved. */
  let created: subject => array<Spec.event>
  /** The event a subject change appends. It must invalidate what was resolved. */
  let subjectChanged: subject => Spec.event
  /** The two facts the graft appends. */
  let located: (~point: Reventless.GeoPoint.t, ~resolvedFrom: subject) => Spec.event
  let unresolvable: (~subject: subject, ~reason: string) => Spec.event
  /** The two commands the slice reports through. */
  let setLocation: (~point: Reventless.GeoPoint.t, ~resolvedFrom: subject) => Spec.command
  let markUnresolvable: (~subject: subject, ~reason: string) => Spec.command

  module Slice: ReventlessGwt.OutboundTranslation_GWT.SliceSpec
  let translate: (
    string,
    Slice.outboundItem,
    ~capabilities: Reventless.Capabilities.t,
  ) => promise<result<option<(string, Slice.inboundCommand)>, string>>
  let item: (~entityId: string, ~subject: subject) => Slice.outboundItem
  /** One consumed event per trigger, carrying `subject`. Every event type the slice
      consumes must appear here — the consumed set may not be wider than its triggers. */
  let triggers: subject => array<Slice.consumedEvent>
  /** The host events that carry address and point together. The slice must not
      consume them: that is the stand-down.

      Real events rather than their type names. A name is a string the compiler
      never sees, so a misspelling here does not fail — it names an event that
      cannot be in any consumed set, and the assertion passes for the wrong
      reason, which is the one outcome a conformance suite must not have. The
      runner encodes these itself. */
  let standsDownOn: array<Spec.event>
  let isLocation: Slice.inboundCommand => bool
  let isVerdict: Slice.inboundCommand => bool
}
