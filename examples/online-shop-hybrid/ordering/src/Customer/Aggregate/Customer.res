// Customer aggregate specification.
// A registered buyer with contact details and account status.

@@reventless.spec

// A map coordinate carried by location commands/events. `GeoPoint.t` rather than
// a local `{lat, lng}` record: the wire shape is identical — so every event
// already stored decodes unchanged — and the declaration buys the range checks
// at the boundary and the marker the command form and the map view read, instead
// of both being inferred from the field names.
@schema
type command =
  | Register({email: string, address: string})
  | UpdateEmail({email: string})
  | UpdateAddress({address: string})
  | SetLocation({location: Reventless.GeoPoint.t})
  | Deactivate

@schema
type event =
  | Registered({email: string, address: string})
  | EmailUpdated({email: string})
  | AddressUpdated({address: string})
  | LocationSet({location: Reventless.GeoPoint.t})
  | Deactivated

@schema
type error =
  | CustomerAlreadyRegistered
  | CustomerNotFound
  | CustomerAlreadyDeactivated
