// ChangeEmail StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when email is unchanged.

open Reventless
open OrderingEventLog

let name = "ChangeEmail"

module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | ChangeEmail({customerId: @s.matches(DcbTag.string) string, email: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

type decisionModel = {exists: bool, deactivated: bool, currentEmail: string}

let initialDecisionModel = {exists: false, deactivated: false, currentEmail: ""}

let reduce = (model, event) =>
  switch event {
  | CustomerRegistered({email}) => {exists: true, deactivated: false, currentEmail: email}
  | EmailChanged({email}) => {...model, currentEmail: email}
  | CustomerDeactivated(_) => {...model, deactivated: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | ChangeEmail({customerId, email}) =>
    if !model.exists {
      Error(CustomerNotFound)
    } else if model.deactivated {
      Error(CustomerAlreadyDeactivated)
    } else if email == model.currentEmail {
      Ok([]) // idempotent — email unchanged
    } else {
      Ok([EmailChanged({customerId, email})])
    }
  }
