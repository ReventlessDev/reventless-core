/**
The host contract of the address-geocoding trait: what an aggregate and its
outbound slice expose so the graft rules can be checked against them. The rules —
staleness, redelivery, an outage is not a verdict, the stand-down — live in
`AddressGeocoding_Guards` and `AddressGeocoding_Translate` and are asserted through a
host by `AddressGeocoding_Conformance`; the confidence rule stays core's
(`Reventless.Geocoding`). The spec surface is written by `AddressGeocoding_Scaffold`.
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

/**
The four facts the graft appends, as real constructors a host splices into its own
event type:

```rescript
type event =
  | Registered({email: string, address: string})
  | ...TraitAddressGeocoding.AddressGeocoding.events
  | Deactivated
```

The host's `evolve` then matches `LocationSet`, `AddressUpdated` and the rest
unqualified, and sury splices the schema flat — the wire format and the generated
GraphQL are identical to hand-written arms, not nested. This is what a spread
replaces: four declarations that every host copied and could mistype.

**Concrete, where `Binding` is abstract.** `Binding.subject` is abstract so the
trait's *rules* hold for any address-shaped thing; these constructors fix
`address: string` and fix the word "Address", because a spread cannot rename what
it splices. A host whose subject is not a string, or that calls it something else,
does not spread — it declares its own arms, which the scaffold's patch prints for
it. The rules, the contract and the conformance suite are the same either way.

Aggregate state is deliberately not here: it is snapshotted, so a trait-owned
record inside it would turn every reshaping release into a migration.
*/
@schema
type events =
  /** A new address invalidates what was resolved, which is what puts the row back
      in front of the slice. */
  | AddressUpdated({address: string})
  /** `resolvedFrom` is provenance, not the address of record; it is what makes "is
      the pin still current?" decidable rather than assumed. */
  | LocationSet({location: Reventless.GeoPoint.t, resolvedFrom: string})
  /** Both halves from a client. Deliberately not `AddressUpdated` + `LocationSet`:
      the slice collects the former, so emitting it here would spend a request
      re-geocoding an address a human just pinned, then race the machine's answer
      against theirs. This event is not in the slice's consumed set — the stand-down. */
  | AddressLocated({address: string, location: Reventless.GeoPoint.t})
  /** A fact, not an absence: `location: None` already means "not looked up yet",
      and one state meaning two things is one nobody can act on. */
  | AddressUnresolvable({address: string, reason: string})

/**
The two commands the outbound slice reports its answer through, as constructors a
host splices into its own command type.

Both are `@noApi`: they are the slice's shape, not a caller's. `SetLocation`
carries a `resolvedFrom` staleness token that only the slice can supply, and a
client correcting a row does it through the host's own public command instead.

The exclusion travels with the spread — it is recorded on each member, not only
on this union — so a host that splices these does not publish them.
*/
@schema
type reportCommands =
  | @noApi SetLocation({location: Reventless.GeoPoint.t, resolvedFrom: string})
  | @noApi MarkAddressUnresolvable({address: string, reason: string})

/**
The two commands a caller changes the address through, as constructors a host
splices into its own command type.

These are public, and that is what kept them out of the trait until now. Both
are legal only while the entity is in some state the HOST names, and a
`@transition` cannot be attached to a constructor a host did not declare — it
lowers to a dict on the parent union, and a spread splices members. So the pair
stayed hand-written in every host, which is the whole of what a spreading host
still had to transcribe.

`commandTransition` is what freed them: the host answers for them in an
exhaustive switch, in its own lifecycle vocabulary, and the compiler will not let
it forget. The trait owns the shape; the host owns the policy; nothing crosses as
a string.

The rule that shapes the pair: **whoever supplies a point supplies the address it
belongs to.** A caller never sends a bare coordinate — that is `SetLocation`
above, the slice's shape and internal. `SetAddressLocation` covers the pin-only
correction too, as the same address with a new point.
*/
@schema
type addressCommands =
  /** Change the address and let the geocoder find the point. */
  | UpdateAddress({address: string})
  /** Change the address *and* say where it is — a client that already has a
      point, because it geocoded or a human dragged the pin. Suppresses the
      geocoder for this address, there being nothing left to look up. */
  | SetAddressLocation({address: string, location: Reventless.GeoPoint.t})

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
