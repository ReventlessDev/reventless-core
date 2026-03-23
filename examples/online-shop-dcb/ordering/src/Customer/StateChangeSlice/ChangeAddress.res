// ChangeAddress StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when address is unchanged.

open Reventless
open OrderingEventLog

let name = "ChangeAddress"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type command = ChangeAddress({customerId: @s.matches(DcbTag.string) string, address: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

type state = {exists: bool, deactivated: bool, currentAddress: string}

let initialState = {exists: false, deactivated: false, currentAddress: ""}

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered({address}) => {
      exists: true,
      deactivated: false,
      currentAddress: address,
    }
  | AddressChanged({address}) => {...state, currentAddress: address}
  | CustomerDeactivated(_) => {...state, deactivated: true}
  | _ => state
  }

let decide = (state, command) =>
  switch command {
  | ChangeAddress({customerId, address}) =>
    if !state.exists {
      Error(CustomerNotFound)
    } else if state.deactivated {
      Error(CustomerAlreadyDeactivated)
    } else if address == state.currentAddress {
      Ok([]) // idempotent — address unchanged
    } else {
      Ok([AddressChanged({customerId, address})])
    }
  }
