// Customer aggregate behavior.
// Implements the state machine for registering and managing customers.

@@reventless.behavior

// `location` and `locationResolvedFrom` are separate fields rather than one,
// because there are three states and a lone `option` can only express two: no
// attempt yet, a point found, and an address *tried and found wanting* (which
// has a resolved-from but no point). The read model surfaces the same three.
//
// The invariant they maintain: `locationResolvedFrom` is either `None` or equal
// to `address`. Every arm below preserves it, and it is what makes "is this pin
// still current?" a decidable question rather than an assumption.
@schema
type state =
  | NotCreated
  | Active({
      email: string,
      address: string,
      location: option<Reventless.GeoPoint.t>,
      locationResolvedFrom: option<string>,
    })
  // Carries the profile it was holding when it was withdrawn. Deactivation is
  // not deletion — the orders still name this customer — so the state that comes
  // back on reactivation has to be the state that went in. A payloadless
  // `Deactivated` would make `Reactivate` either impossible or a second
  // registration, and a second registration is a different fact.
  | Deactivated({
      email: string,
      address: string,
      location: option<Reventless.GeoPoint.t>,
      locationResolvedFrom: option<string>,
    })

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Registered({email, address})) =>
    Active({email, address, location: None, locationResolvedFrom: None})
  | (Active(s), Registered({email, address})) => Active({...s, email, address})
  | (Active(s), EmailUpdated({email})) => Active({...s, email})
  // A new address invalidates whatever was known about the old one — dropping
  // both is what puts the row back in front of the geocoding slice.
  | (Active(s), AddressUpdated({address})) =>
    Active({...s, address, location: None, locationResolvedFrom: None})
  | (Active(s), LocationSet({location, resolvedFrom})) =>
    Active({...s, location: Some(location), locationResolvedFrom: Some(resolvedFrom)})
  // Both halves at once, from a client. `locationResolvedFrom` is the address
  // itself: the caller supplied the pair, so there is nothing left to resolve.
  | (Active(s), AddressLocated({address, location})) =>
    Active({...s, address, location: Some(location), locationResolvedFrom: Some(address)})
  // Tried, and no usable answer. Recording the address keeps the slice from
  // handing it back for another round.
  | (Active(s), AddressUnresolvable({address})) =>
    Active({...s, location: None, locationResolvedFrom: Some(address)})
  | (Active({email, address, location, locationResolvedFrom}), Customer.Deactivated) =>
    Deactivated({email, address, location, locationResolvedFrom})
  | (Deactivated({email, address, location, locationResolvedFrom}), Reactivated) =>
    Active({email, address, location, locationResolvedFrom})
  | (Deactivated(_), _) => state
  | (Active(_), Reactivated) => state
  | (NotCreated, _) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Register({email, address})) => Ok([Registered({email, address})])
  | (NotCreated, UpdateEmail(_)) => Error(CustomerNotFound)
  | (NotCreated, UpdateAddress(_)) => Error(CustomerNotFound)
  | (NotCreated, SetAddressLocation(_)) => Error(CustomerNotFound)
  | (NotCreated, SetLocation(_)) => Error(CustomerNotFound)
  | (NotCreated, MarkAddressUnresolvable(_)) => Error(CustomerNotFound)
  | (NotCreated, Deactivate) => Error(CustomerNotFound)
  | (NotCreated, Reactivate) => Error(CustomerNotFound)

  | (Active(_), Register(_)) => Error(CustomerAlreadyRegistered)
  | (Active(s), UpdateEmail({email})) if email == s.email => Ok([])
  | (Active(_), UpdateEmail({email})) => Ok([EmailUpdated({email: email})])
  | (Active(s), UpdateAddress({address})) if address == s.address => Ok([])
  | (Active(_), UpdateAddress({address})) => Ok([AddressUpdated({address: address})])

  // Client-supplied pair. Idempotent only when *both* halves already match —
  // same address with a different point is a pin correction, and swallowing it
  // would lose the one edit a human came here to make.
  | (Active(s), SetAddressLocation({address, location}))
    if address == s.address && s.location == Some(location) => Ok([])
  | (Active(_), SetAddressLocation({address, location})) =>
    Ok([AddressLocated({address, location})])

  // Stale: the slice is reporting on an address this customer has since moved
  // off. Applying it would pin the row's new address at the old one's point,
  // with nothing to say the two disagree.
  | (Active(s), SetLocation({resolvedFrom})) if resolvedFrom != s.address => Ok([])
  // Redelivery. Commands arrive at-least-once and the slice re-publishes on
  // every heartbeat sweep until its TODO row clears, so without this an
  // unchanged answer appends a duplicate event on every pass.
  | (Active(s), SetLocation({location, resolvedFrom}))
    if s.location == Some(location) && s.locationResolvedFrom == Some(resolvedFrom) => Ok([])
  | (Active(_), SetLocation({location, resolvedFrom})) =>
    Ok([LocationSet({location, resolvedFrom})])

  // Same two guards, for the verdict: stale reports are dropped, and a repeated
  // verdict on the same address is a no-op.
  | (Active(s), MarkAddressUnresolvable({address})) if address != s.address => Ok([])
  | (Active(s), MarkAddressUnresolvable({address})) if s.locationResolvedFrom == Some(address) =>
    Ok([])
  | (Active(_), MarkAddressUnresolvable({address, reason})) =>
    Ok([AddressUnresolvable({address, reason})])

  | (Active(_), Deactivate) => Ok([Customer.Deactivated])
  // Already where the caller is asking it to be.
  | (Active(_), Reactivate) => Ok([])

  | (Deactivated(_), Register(_)) => Error(CustomerAlreadyDeactivated)
  | (Deactivated(_), UpdateEmail(_)) => Error(CustomerAlreadyDeactivated)
  | (Deactivated(_), UpdateAddress(_)) => Error(CustomerAlreadyDeactivated)
  | (Deactivated(_), SetAddressLocation(_)) => Error(CustomerAlreadyDeactivated)
  // A deactivated customer has no location work owing — swallow rather than
  // error, so an in-flight geocode landing after deactivation does not park a
  // TODO row in Failed forever.
  | (Deactivated(_), SetLocation(_)) => Ok([])
  | (Deactivated(_), MarkAddressUnresolvable(_)) => Ok([])
  | (Deactivated(_), Deactivate) => Ok([]) // idempotent
  // The one command this state exists to accept.
  | (Deactivated(_), Reactivate) => Ok([Reactivated])
  }
