// Customer aggregate specification.
// A registered buyer with contact details and account status.

@@reventless.spec

// A map coordinate carried by location commands/events. `GeoPoint.t` rather than
// a local `{lat, lng}` record: the wire shape is identical — so every event
// already stored decodes unchanged — and the declaration buys the range checks
// at the boundary and the marker the command form and the map view read, instead
// of both being inferred from the field names.
// A human enters an address and nothing else. `GeocodeCustomerAddress` — an
// OutboundTranslationSlice subscribed to this aggregate — turns that address
// into a point and reports the outcome back through the two `@noApi` commands
// below.
//
// The rule that shapes this API: **whoever supplies a point supplies the address
// it belongs to.** So a caller never sends a bare coordinate — `SetLocation` is
// the slice's shape, not a client's, and stays internal. A UI corrects a row
// through `SetAddressLocation`, which covers the pin-only fix too (same address,
// new point).
//
// The two are not interchangeable even though their payloads nearly are. The
// slice's `SetLocation` is a *report about a past address* and loses to a
// subsequent change; `SetAddressLocation` is an *assertion about the present* and
// wins. That is the whole reason `resolvedFrom` exists.
@schema
type command =
  | Register({email: string, address: string})
  | UpdateEmail({email: string})
  // The two public address commands, spliced from the trait: `UpdateAddress` and
  // `SetAddressLocation`. They stayed hand-written here for as long as their
  // lifecycle guard had to live on the constructor; `commandTransition` below
  // answers for them instead, so the trait owns the shape and this file owns
  // only the policy.
  | ...TraitAddressGeocoding.AddressGeocoding.addressCommands
  // `resolvedFrom` is a staleness token as much as provenance: an answer for an
  // address that has since changed is dropped rather than applied.
  //
  // These two are deliberately NOT guarded. On a deactivated customer they
  // return `Ok([])` rather than refusing, so an in-flight geocode landing after
  // deactivation does not park a TODO row in Failed forever — which makes them
  // legal in every state, and a from-set naming every state says nothing.
  //
  // Spliced from the trait, `@noApi` and all: the exclusion is recorded on each
  // member, so it survives the spread and neither is published.
  | ...TraitAddressGeocoding.AddressGeocoding.reportCommands
  | Deactivate
  // The way back. Deactivation withdraws a customer from ordinary use; it does
  // not erase them, so restoring one needs no payload — the profile is still in
  // the state, and asking a caller to re-supply an email they never changed
  // would be a second chance to get it wrong.
  | Reactivate

@schema
type event =
  | Registered({email: string, address: string})
  | EmailUpdated({email: string})
  // The geocoding graft's four facts, spliced from the trait rather than copied:
  // `AddressUpdated`, `LocationSet`, `AddressLocated`, `AddressUnresolvable`.
  // They are matched unqualified below and in the projections, and sury splices
  // the schema flat, so the wire format is what hand-written arms produced.
  | ...TraitAddressGeocoding.AddressGeocoding.events
  | Deactivated
  | Reactivated

@schema
type error =
  | CustomerAlreadyRegistered
  | CustomerNotFound
  | CustomerAlreadyDeactivated

// Which lifecycle edge each command owns, as a switch rather than as
// an attribute on the constructors. Two things follow that an attribute
// could not give here.
//
// It is **exhaustive**, so the two commands spliced from the geocoding trait
// have to be answered. An annotation cannot reach them at all — it lowers to a
// dict on this union, and a spread splices members — so before this the graft's
// commands silently carried no policy.
//
// And the states are `Customers`' own constructors, checked by the compiler
// rather than matched as strings at plugin assembly. The reference costs
// nothing: a lifecycle arm is payload-less, so `[Customers.Active]` compiles to
// `["Active"]` and this module imports nothing from the view — which is also
// why it cannot cycle, since a view spec holds no reference back to the
// aggregate it projects.
//
// Named once, so every arm speaks of one lifecycle: a from-set out of this enum
// with a target out of another does not compile.
type lifecycleState = Customers.accountStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  // Registration brings the row into existence, so there is no state it could
  // come from — and it names no target either, because the row's status is the
  // view's to derive.
  | Register(_) => Unrestricted
  // A from-set and no target: legal on an active customer, and it does not move
  // them. Each is `Error(CustomerAlreadyDeactivated)` on a deactivated one, so
  // this says exactly what `decide` already enforces — it only stops a menu
  // offering what the write side would refuse.
  | UpdateEmail(_)
  | UpdateAddress(_)
  | SetAddressLocation(_) =>
    Guards([Customers.Active])
  // The trait's two reports, deliberately legal in every state: an in-flight
  // geocode landing after deactivation returns `Ok([])` rather than refusing, so
  // it does not park a TODO row in Failed forever.
  | SetLocation(_) | MarkAddressUnresolvable(_) => Unrestricted
  | Deactivate => Moves([Customers.Active], Customers.Deactivated)
  // Works because the view's retirement IS a state of its lifecycle rather than
  // a boolean beside one, so the states a command names and the states a row can
  // be in are one vocabulary. The refusal still lives in `decide`; this tells a
  // board which command answers the move.
  | Reactivate => Moves([Customers.Deactivated], Customers.Active)
  }
}

// Grafted, and this is the only record of it that survives into a deployed
// plugin — every other signal (the dependency, the spread, the rules alias, the
// conformance binding) is source-side. The value comes from the trait, so a
// rename or a removed dependency is a build error rather than a stale row.
let traits = [TraitAddressGeocoding.AddressGeocoding.declaration]
