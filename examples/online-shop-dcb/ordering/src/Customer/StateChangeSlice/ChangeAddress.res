// ChangeAddress StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when address is unchanged.

open Reventless
open OrderingEventLog

let name = "ChangeAddress"

module DcbEventLogSpec = OrderingEventLog

@schema
type command = ChangeAddress({customerId: @s.matches(DcbTag.string) string, address: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

type decisionModel = {exists: bool, deactivated: bool, currentAddress: string}

let initialDecisionModel = {exists: false, deactivated: false, currentAddress: ""}

let reduce = (model, event) =>
  switch event {
  | CustomerRegistered({address}) => {
      exists: true,
      deactivated: false,
      currentAddress: address,
    }
  | AddressChanged({address}) => {...model, currentAddress: address}
  | CustomerDeactivated(_) => {...model, deactivated: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | ChangeAddress({customerId, address}) =>
    if !model.exists {
      Error(CustomerNotFound)
    } else if model.deactivated {
      Error(CustomerAlreadyDeactivated)
    } else if address == model.currentAddress {
      Ok([]) // idempotent — address unchanged
    } else {
      Ok([AddressChanged({customerId, address})])
    }
  }
