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
  | CustomerRegistered({email, address}) => Active({email, address})
  | EmailUpdated(_)
  | AddressUpdated(_)
  | CustomerDeactivated(_) =>
    throw(InvalidEvent(event->encode(eventSchema)))
  }

let apply = (state, event) =>
  switch (state, event) {
  | (Active(_), CustomerRegistered({email, address})) => Active({email, address})
  | (Active(s), EmailUpdated({email})) => Active({...s, email})
  | (Active(s), AddressUpdated({address})) => Active({...s, address})
  | (Active(_), CustomerDeactivated(_)) => Deactivated
  | (Deactivated, _) => state
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | RegisterCustomer({customerId, email, address}) => [
      CustomerRegistered({customerId, email, address}),
    ]
  | UpdateEmail(_)
  | UpdateAddress(_)
  | DeactivateCustomer(_) =>
    errorHandler(CustomerNotFound, command, _context)
  }

let execute = (state, command, context, errorHandler) =>
  switch (state, command) {
  | (Active(_), RegisterCustomer(_)) => errorHandler(CustomerAlreadyRegistered, command, context)
  | (Active(s), UpdateEmail({email})) if email == s.email => []
  | (Active(_), UpdateEmail({customerId, email})) => [EmailUpdated({customerId, email})]
  | (Active(s), UpdateAddress({address})) if address == s.address => []
  | (Active(_), UpdateAddress({customerId, address})) => [AddressUpdated({customerId, address})]
  | (Active(_), DeactivateCustomer({customerId: cid})) => [CustomerDeactivated({customerId: cid})]
  | (Deactivated, RegisterCustomer(_)) => errorHandler(CustomerAlreadyDeactivated, command, context)
  | (Deactivated, UpdateEmail(_)) => errorHandler(CustomerAlreadyDeactivated, command, context)
  | (Deactivated, UpdateAddress(_)) => errorHandler(CustomerAlreadyDeactivated, command, context)
  | (Deactivated, DeactivateCustomer(_)) => [] // idempotent
  }
