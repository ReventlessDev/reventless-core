// Customer aggregate behavior.
// Implements the state machine for registering and managing customers.

open Reventless
open Reventless.Message
open Customer

module Spec = Customer

@schema
type state =
  | Active({email: string, address: string})
  | Deactivated

let resolverConfig = {
  Behavior.commandSchema,
  fields: [],
}

let init = event =>
  switch event {
  | Registered({email, address}) => Active({email, address})
  | EmailUpdated(_)
  | AddressUpdated(_)
  | Customer.Deactivated =>
    throw(InvalidEvent(event->encode(eventSchema)))
  }

let apply = (state, event) =>
  switch (state, event) {
  | (Active(_), Registered({email, address})) => Active({email, address})
  | (Active(s), EmailUpdated({email})) => Active({...s, email})
  | (Active(s), AddressUpdated({address})) => Active({...s, address})
  | (Active(_), Customer.Deactivated) => Deactivated
  | (Deactivated, _) => state
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | Register({email, address}) => [
      Registered({email, address}),
    ]
  | UpdateEmail(_)
  | UpdateAddress(_)
  | Deactivate =>
    errorHandler(CustomerNotFound, command, _context)
  }

let execute = (state, command, context, errorHandler) =>
  switch (state, command) {
  | (Active(_), Register(_)) => errorHandler(CustomerAlreadyRegistered, command, context)
  | (Active(s), UpdateEmail({email})) if email == s.email => []
  | (Active(_), UpdateEmail({email})) => [EmailUpdated({email: email})]
  | (Active(s), UpdateAddress({address})) if address == s.address => []
  | (Active(_), UpdateAddress({address})) => [AddressUpdated({address: address})]
  | (Active(_), Deactivate) => [Customer.Deactivated]
  | (Deactivated, Register(_)) => errorHandler(CustomerAlreadyDeactivated, command, context)
  | (Deactivated, UpdateEmail(_)) => errorHandler(CustomerAlreadyDeactivated, command, context)
  | (Deactivated, UpdateAddress(_)) => errorHandler(CustomerAlreadyDeactivated, command, context)
  | (Deactivated, Deactivate) => [] // idempotent
  }
