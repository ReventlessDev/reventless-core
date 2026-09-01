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
  // No `@transition`: registration creates the row, so there is no state to
  // come *from*. A creating command declares nothing rather than declaring an
  // empty from-set.
  | Register({email: string, address: string})
  // The three editing commands below carry a from-set and no target, which is
  // the whole of "legal on an active customer, and it does not move them". Each
  // one is `Error(CustomerAlreadyDeactivated)` on a deactivated customer, so the
  // declaration says exactly what `decide` already enforces — it only stops a
  // menu offering what the write side would refuse.
  | @transition([Customers.Active]) UpdateEmail({email: string})
  // Change the address and let the geocoder find the point.
  | @transition([Customers.Active]) UpdateAddress({address: string})
  // Change the address *and* say where it is — a client that already has a point
  // (it geocoded, or a human dragged the pin). Suppresses the geocoder for this
  // address, because there is nothing left to look up.
  | @transition([Customers.Active])
  SetAddressLocation({address: string, location: Reventless.GeoPoint.t})
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
  | @transition(([Customers.Active]) => Customers.Deactivated) Deactivate
  // The way back. Deactivation withdraws a customer from ordinary use; it does
  // not erase them, so restoring one needs no payload — the profile is still in
  // the state, and asking a caller to re-supply an email they never changed
  // would be a second chance to get it wrong.
  //
  // `@transition(([Deactivated]) => Active)` is the whole of "offer this on a
  // deactivated customer and nowhere else, and it puts them back". It works
  // because the view's retirement IS a state of its lifecycle rather than a
  // boolean beside one, so the states a command names and the states a row can
  // be in are the same vocabulary. The refusal still lives in `decide`; this
  // only stops a menu offering what the write side would reject, and tells a
  // board which command answers the move.
  | @transition(([Customers.Deactivated]) => Customers.Active) Reactivate

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
