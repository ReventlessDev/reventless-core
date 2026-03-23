// ChangeEmail StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when email is unchanged.

open Reventless
open OrderingEventLog

let name = "ChangeEmail"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type command = ChangeEmail({customerId: @s.matches(DcbTag.string) string, email: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

type state = {exists: bool, deactivated: bool, currentEmail: string}

let initialState = {exists: false, deactivated: false, currentEmail: ""}

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered({email}) => {exists: true, deactivated: false, currentEmail: email}
  | EmailChanged({email}) => {...state, currentEmail: email}
  | CustomerDeactivated(_) => {...state, deactivated: true}
  | _ => state
  }

let decide = (state, command) =>
  switch command {
  | ChangeEmail({customerId, email}) =>
    if !state.exists {
      Error(CustomerNotFound)
    } else if state.deactivated {
      Error(CustomerAlreadyDeactivated)
    } else if email == state.currentEmail {
      Ok([]) // idempotent — email unchanged
    } else {
      Ok([EmailChanged({customerId, email})])
    }
  }
