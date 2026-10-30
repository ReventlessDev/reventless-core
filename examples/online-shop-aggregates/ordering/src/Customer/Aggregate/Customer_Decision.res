// Customer aggregate decision.
// Implements the state machine for registering and managing customers.

@@reventless.decision

@schema
type state =
  | NotCreated
  | Active({email: string, address: string})
  | Deactivated

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  // A personal field reads `Erased` once its customer is erased; the state then
  // holds nothing in its place, as a profile never written would.
  | (NotCreated | Active(_), Registered({email, address})) =>
    Active({email: email->Reventless.Pii.getOr(""), address: address->Reventless.Pii.getOr("")})
  | (Active(s), EmailUpdated({email})) => Active({...s, email: email->Reventless.Pii.getOr("")})
  | (Active(s), AddressUpdated({address})) =>
    Active({...s, address: address->Reventless.Pii.getOr("")})
  | (Active(_), Customer.Deactivated) => Deactivated
  | (Deactivated, _) => state
  | (NotCreated, _) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Register({email, address})) =>
    Ok([Registered({email: Value(email), address: Value(address)})])
  | (NotCreated, UpdateEmail(_)) => Error(CustomerNotFound)
  | (NotCreated, UpdateAddress(_)) => Error(CustomerNotFound)
  | (NotCreated, Deactivate) => Error(CustomerNotFound)
  | (Active(_), Register(_)) => Error(CustomerAlreadyRegistered)
  | (Active(s), UpdateEmail({email})) if email == s.email => Ok([])
  | (Active(_), UpdateEmail({email})) => Ok([EmailUpdated({email: Value(email)})])
  | (Active(s), UpdateAddress({address})) if address == s.address => Ok([])
  | (Active(_), UpdateAddress({address})) => Ok([AddressUpdated({address: Value(address)})])
  | (Active(_), Deactivate) => Ok([Customer.Deactivated])
  | (Deactivated, Register(_)) => Error(CustomerAlreadyDeactivated)
  | (Deactivated, UpdateEmail(_)) => Error(CustomerAlreadyDeactivated)
  | (Deactivated, UpdateAddress(_)) => Error(CustomerAlreadyDeactivated)
  | (Deactivated, Deactivate) => Ok([]) // idempotent
  }
