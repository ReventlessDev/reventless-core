// Customer aggregate behavior.
// Implements the state machine for registering and managing customers.

@@reventless.behavior

// Staleness, redelivery and the client-supplied pair are the geocoding trait's
// rules; this aggregate keeps the fields they read and names the facts they allow.
module Guards = TraitAddressGeocoding.AddressGeocoding_Guards

// `location` and `locationResolvedFrom` are separate fields rather than one,
// because there are three states and a lone `option` can only express two: no
// attempt yet, a point found, and an address *tried and found wanting* (which
// has a resolved-from but no point). The read model surfaces the same three.
//
// The invariant they maintain: `locationResolvedFrom` is either `None` or equal
// to `address`. Every arm below preserves it, and it is what makes "is this pin
// still current?" a decidable question rather than an assumption.
//
// `verifiedEmail` is the verification graft's staleness token, and it holds the
// same shape of invariant: it is either `None` or equal to `email`. `EmailUpdated`
// dropping it is what makes "is this address proven?" a decidable question rather
// than an assumption — and what stops a proof issued for the old address from
// settling against the new one.
@schema
type state =
  | NotCreated
  | Active({
      email: string,
      address: string,
      location: option<Reventless.GeoPoint.t>,
      locationResolvedFrom: option<string>,
      verifiedEmail: option<string>,
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
      verifiedEmail: option<string>,
    })

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Registered({email, address})) =>
    Active({email, address, location: None, locationResolvedFrom: None, verifiedEmail: None})
  | (Active(s), Registered({email, address})) => Active({...s, email, address})
  // 🚨 A new address is unproven, whatever was proven before. Dropping the token
  // here is the host half of the staleness guard: without it a proof issued for
  // the old address would settle against the new one, which is exactly the
  // "change the address, then present the old link" takeover.
  | (Active(s), EmailUpdated({email})) => Active({...s, email, verifiedEmail: None})
  | (Active(s), EmailVerified({email})) => Active({...s, verifiedEmail: Some(email)})
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
  | (
      Active({email, address, location, locationResolvedFrom, verifiedEmail}),
      Customer.Deactivated,
    ) =>
    Deactivated({email, address, location, locationResolvedFrom, verifiedEmail})
  | (Deactivated({email, address, location, locationResolvedFrom, verifiedEmail}), Reactivated) =>
    Active({email, address, location, locationResolvedFrom, verifiedEmail})
  | (Deactivated(_), _) => state
  | (Active(_), Reactivated) => state
  | (NotCreated, _) => state
  }

// The three fields the trait reads, and what it decides, in this host's terms.
// Built per call: an aggregate's state is snapshotted, so the trait's own record
// stays out of it.
let resolution = (address, location, locationResolvedFrom): Guards.resolution => {
  subject: address,
  location,
  resolvedFrom: locationResolvedFrom,
}

let appended = (verdict, event) =>
  switch verdict {
  | Guards.Append => Ok([event])
  | Guards.Ignore => Ok([])
  }

// The verification graft's two fields, in this host's terms. Built per call for
// the same reason the geocoding one is: an aggregate's state is snapshotted, so
// the graft's own record stays out of it.
module Verification = ContactVerification_Guards

let verification = (email, verifiedEmail): Verification.verification => {
  contact: ByEmail(email),
  verifiedAddress: verifiedEmail->Option.map(e => ContactVerification.ByEmail(e)),
}

let verified = (verdict, event) =>
  switch verdict {
  | Verification.Append => Ok([event])
  | Verification.Ignore => Ok([])
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Register({email, address})) => Ok([Registered({email, address})])
  | (NotCreated, UpdateEmail(_)) => Error(CustomerNotFound)
  | (NotCreated, UpdateAddress(_)) => Error(CustomerNotFound)
  | (NotCreated, SetAddressLocation(_)) => Error(CustomerNotFound)
  | (NotCreated, SetLocation(_)) => Error(CustomerNotFound)
  | (NotCreated, MarkAddressUnresolvable(_)) => Error(CustomerNotFound)
  | (NotCreated, MarkEmailVerified(_)) => Error(CustomerNotFound)
  | (NotCreated, Deactivate) => Error(CustomerNotFound)
  | (NotCreated, Reactivate) => Error(CustomerNotFound)

  | (Active(_), Register(_)) => Error(CustomerAlreadyRegistered)
  | (Active(s), UpdateEmail({email})) if email == s.email => Ok([])
  | (Active(_), UpdateEmail({email})) => Ok([EmailUpdated({email: email})])
  | (Active(s), UpdateAddress({address})) =>
    Guards.onSubjectUpdate(
      resolution(s.address, s.location, s.locationResolvedFrom),
      ~subject=address,
    )->appended(AddressUpdated({address: address}))

  | (Active(s), SetAddressLocation({address, location})) =>
    Guards.onSuppliedPair(
      resolution(s.address, s.location, s.locationResolvedFrom),
      ~subject=address,
      ~location,
    )->appended(AddressLocated({address, location}))

  | (Active(s), SetLocation({location, resolvedFrom})) =>
    Guards.onLocationReport(
      resolution(s.address, s.location, s.locationResolvedFrom),
      ~location,
      ~resolvedFrom,
    )->appended(LocationSet({location, resolvedFrom}))

  | (Active(s), MarkAddressUnresolvable({address, reason})) =>
    Guards.onUnresolvableReport(
      resolution(s.address, s.location, s.locationResolvedFrom),
      ~subject=address,
    )->appended(AddressUnresolvable({address, reason}))

  // 🚨 The security control at the host boundary. A verdict naming an address
  // the customer has since changed is dropped rather than applied — and it is
  // dropped here as well as in the ledger, because a verdict can arrive by
  // redelivery or from a ledger that is simply wrong, and only this check sits
  // inside the host's own consistency boundary.
  | (Active(s), MarkEmailVerified({email})) =>
    Verification.onVerifiedReport(
      verification(s.email, s.verifiedEmail),
      ~contact=ByEmail(email),
    )->verified(EmailVerified({email: email}))

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
  // Same reasoning: a proof settled while the customer was being deactivated is
  // swallowed rather than refused, so the reporting slice does not retry forever.
  | (Deactivated(_), MarkEmailVerified(_)) => Ok([])
  | (Deactivated(_), Deactivate) => Ok([]) // idempotent
  // The one command this state exists to accept.
  | (Deactivated(_), Reactivate) => Ok([Reactivated])
  }
