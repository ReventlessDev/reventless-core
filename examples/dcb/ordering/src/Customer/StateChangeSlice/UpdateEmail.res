// UpdateEmail StateChangeSlice.
// Requires customer to exist and not be deactivated; idempotent when email is unchanged.

open OrderingEventLog

let name = "UpdateEmail"

module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | UpdateEmail({customerId: @s.matches(Reventless.DcbTag.string) string, email: string})

@schema
type error =
  | CustomerNotFound
  | CustomerAlreadyDeactivated

type decisionModel = {exists: bool, deactivated: bool, currentEmail: string}

let initialDecisionModel = {exists: false, deactivated: false, currentEmail: ""}

let reduce = (model, event) =>
  switch event {
  | CustomerRegistered({email}) => {exists: true, deactivated: false, currentEmail: email}
  | EmailUpdated({email}) => {...model, currentEmail: email}
  | CustomerDeactivated(_) => {...model, deactivated: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | UpdateEmail({customerId, email}) =>
    if !model.exists {
      Error(CustomerNotFound)
    } else if model.deactivated {
      Error(CustomerAlreadyDeactivated)
    } else if email == model.currentEmail {
      Ok([]) // idempotent — email unchanged
    } else {
      Ok([EmailUpdated({customerId, email})])
    }
  }
