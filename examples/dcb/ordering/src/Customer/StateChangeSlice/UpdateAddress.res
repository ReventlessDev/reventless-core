// UpdateAddress StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when address is unchanged.

open Reventless
open OrderingEventLog

let name = "UpdateAddress"

module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | UpdateAddress({customerId: @s.matches(DcbTag.string) string, address: string})

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
  | AddressUpdated({address}) => {...model, currentAddress: address}
  | CustomerDeactivated(_) => {...model, deactivated: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | UpdateAddress({customerId, address}) =>
    if !model.exists {
      Error(CustomerNotFound)
    } else if model.deactivated {
      Error(CustomerAlreadyDeactivated)
    } else if address == model.currentAddress {
      Ok([]) // idempotent — address unchanged
    } else {
      Ok([AddressUpdated({customerId, address})])
    }
  }
