// Customer aggregate specification.
// A registered buyer with contact details and account status.

@@reventless.spec

// A map coordinate carried by location commands/events. Emitted as a JSON-Schema
// object with numeric `lat`/`lng` sub-properties, which the generated command
// form recognises as a geo-point picker.
@schema
type location = {lat: float, lng: float}

@schema
type command =
  | Register({email: string, address: string})
  | UpdateEmail({email: string})
  | UpdateAddress({address: string})
  | SetLocation({location: location})
  | Deactivate

@schema
type event =
  | Registered({email: string, address: string})
  | EmailUpdated({email: string})
  | AddressUpdated({address: string})
  | LocationSet({location: location})
  | Deactivated

@schema
type error =
  | CustomerAlreadyRegistered
  | CustomerNotFound
  | CustomerAlreadyDeactivated
