// DeactivateCustomer StateChangeSlice.
// Requires customer to exist; idempotent if already deactivated.

open Reventless
open OrderingEventLog

let name = "DeactivateCustomer"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type command = DeactivateCustomer({customerId: @s.matches(DcbTag.string) string})

@schema
type error = CustomerNotFound

type state = {exists: bool, deactivated: bool}

let initialState = {exists: false, deactivated: false}

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered(_) => {exists: true, deactivated: false}
  | CustomerDeactivated(_) => {...state, deactivated: true}
  | _ => state
  }

let decide = (state, command) =>
  switch command {
  | DeactivateCustomer({customerId: theId}) =>
    if !state.exists {
      Error(CustomerNotFound)
    } else if state.deactivated {
      Ok([]) // idempotent — already deactivated
    } else {
      Ok([CustomerDeactivated({customerId: theId})])
    }
  }
