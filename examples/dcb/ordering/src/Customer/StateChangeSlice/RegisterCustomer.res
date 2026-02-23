// RegisterCustomer StateChangeSlice.
// Handles the RegisterCustomer command; rejects duplicate registration.

open OrderingEventLog

let name = "RegisterCustomer"

module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | RegisterCustomer({
      customerId: @s.matches(Reventless.DcbTag.string) string,
      email: string,
      address: string,
    })

@schema
type error = | CustomerAlreadyRegistered

type decisionModel = {exists: bool}

let initialDecisionModel = {exists: false}

let reduce = (model, event) =>
  switch event {
  | CustomerRegistered(_) => {exists: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | RegisterCustomer({customerId, email, address}) =>
    if model.exists {
      Error(CustomerAlreadyRegistered)
    } else {
      Ok([CustomerRegistered({customerId, email, address})])
    }
  }
