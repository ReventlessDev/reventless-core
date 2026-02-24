// DeactivateCustomer StateChangeSlice.
// Requires customer to exist; idempotent if already deactivated.

open ReventlessSpec
open OrderingEventLog

let name = "DeactivateCustomer"

module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | DeactivateCustomer({customerId: @s.matches(DcbTag.string) string})

@schema
type error = | CustomerNotFound

type decisionModel = {exists: bool, deactivated: bool}

let initialDecisionModel = {exists: false, deactivated: false}

let reduce = (model, event) =>
  switch event {
  | CustomerRegistered(_) => {exists: true, deactivated: false}
  | CustomerDeactivated(_) => {...model, deactivated: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | DeactivateCustomer({customerId: theId}) =>
    if !model.exists {
      Error(CustomerNotFound)
    } else if model.deactivated {
      Ok([]) // idempotent — already deactivated
    } else {
      Ok([CustomerDeactivated({customerId: theId})])
    }
  }
