// RegisterCustomer StateChangeSlice.
// Handles the RegisterCustomer command; rejects duplicate registration.

open Reventless
open OrderingEventLog

let name = "RegisterCustomer"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | RegisterCustomer({customerId: @s.matches(DcbTag.string) string, email: string, address: string})

@schema
type error = CustomerAlreadyRegistered

type state = {exists: bool}

let initialState = {exists: false}

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered(_) => {exists: true}
  | _ => state
  }

let decide = (state, command) =>
  switch command {
  | RegisterCustomer({customerId, email, address}) =>
    if state.exists {
      Error(CustomerAlreadyRegistered)
    } else {
      Ok([CustomerRegistered({customerId, email, address})])
    }
  }
