// DeactivateCustomer StateChangeSlice.
// Requires customer to exist; idempotent if already deactivated.

open Reventless

let name = "DeactivateCustomer"
let moduleUrl: string = %raw(`import.meta.url`)

type state = {exists: bool, deactivated: bool}

let initialState = {exists: false, deactivated: false}

@schema
type consumedEvent =
  | CustomerRegistered
  | CustomerDeactivated

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered => {exists: true, deactivated: false}
  | CustomerDeactivated => {...state, deactivated: true}
  }

@schema
type command = DeactivateCustomer({customerId: @s.matches(DcbTag.string) string})

@schema
type error = CustomerNotFound

@schema
type producedEvent = CustomerDeactivated({customerId: @s.matches(DcbTag.string) string})

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
