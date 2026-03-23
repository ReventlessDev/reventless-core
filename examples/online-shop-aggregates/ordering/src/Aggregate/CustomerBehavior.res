// Customer aggregate behavior.
// Implements the state machine for registering and managing customers.

open Customer

module Spec = Customer

@schema
type state =
  | NotCreated
  | Active({email: string, address: string})
  | Deactivated

let resolverConfig = {
  Reventless.Behavior.commandSchema,
  fields: [],
}

let moduleUrl: string = %raw(`import.meta.url`)

let initialState = NotCreated

let evolve = (state, event) =>
  switch (state, event) {
  | (NotCreated, Registered({email, address})) => Active({email, address})
  | (Active(_), Registered({email, address})) => Active({email, address})
  | (Active(s), EmailUpdated({email})) => Active({...s, email})
  | (Active(s), AddressUpdated({address})) => Active({...s, address})
  | (Active(_), Customer.Deactivated) => Deactivated
  | (Deactivated, _) => state
  | (NotCreated, _) => state
  }

let decide = (state, command) =>
  switch (state, command) {
  | (NotCreated, Register({email, address})) => Ok([Registered({email, address})])
  | (NotCreated, UpdateEmail(_)) => Error(CustomerNotFound)
  | (NotCreated, UpdateAddress(_)) => Error(CustomerNotFound)
  | (NotCreated, Deactivate) => Error(CustomerNotFound)
  | (Active(_), Register(_)) => Error(CustomerAlreadyRegistered)
  | (Active(s), UpdateEmail({email})) if email == s.email => Ok([])
  | (Active(_), UpdateEmail({email})) => Ok([EmailUpdated({email: email})])
  | (Active(s), UpdateAddress({address})) if address == s.address => Ok([])
  | (Active(_), UpdateAddress({address})) => Ok([AddressUpdated({address: address})])
  | (Active(_), Deactivate) => Ok([Customer.Deactivated])
  | (Deactivated, Register(_)) => Error(CustomerAlreadyDeactivated)
  | (Deactivated, UpdateEmail(_)) => Error(CustomerAlreadyDeactivated)
  | (Deactivated, UpdateAddress(_)) => Error(CustomerAlreadyDeactivated)
  | (Deactivated, Deactivate) => Ok([]) // idempotent
  }
