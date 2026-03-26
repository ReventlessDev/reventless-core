// ChangeAddress StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when address is unchanged.

open Reventless

let name = "ChangeAddress"
let moduleUrl: string = %raw(`import.meta.url`)

type state = {exists: bool, deactivated: bool, currentAddress: string}

let initialState = {exists: false, deactivated: false, currentAddress: ""}

@schema
type consumedEvent =
  | CustomerRegistered({address: string})
  | AddressChanged({address: string})
  | CustomerDeactivated

let evolve = (state, event) =>
  switch event {
  | CustomerRegistered({address}) => {
      exists: true,
      deactivated: false,
      currentAddress: address,
    }
  | AddressChanged({address}) => {...state, currentAddress: address}
  | CustomerDeactivated => {...state, deactivated: true}
  }

@schema
type command = ChangeAddress({customerId: @s.matches(DcbTag.string) string, address: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

@schema
type producedEvent = AddressChanged({customerId: @s.matches(DcbTag.string) string, address: string})

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
