// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.

open OrderingEventLog

let name = "CancelOrder"

module DcbEventLogSpec = OrderingEventLog

@schema
type command = | CancelOrder({orderId: @s.matches(Reventless.DcbTag.string) string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

type decisionModel = {exists: bool, shipped: bool, cancelled: bool}

let initialDecisionModel = {exists: false, shipped: false, cancelled: false}

let reduce = (model, event) =>
  switch event {
  | OrderPlaced(_) => {exists: true, shipped: false, cancelled: false}
  | OrderShipped(_) => {...model, shipped: true}
  | OrderCancelled(_) => {...model, cancelled: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | CancelOrder({orderId: theId}) =>
    if !model.exists {
      Error(OrderNotFound)
    } else if model.shipped {
      Error(OrderAlreadyShipped)
    } else if model.cancelled {
      Ok([]) // idempotent — already cancelled
    } else {
      Ok([OrderCancelled({orderId: theId})])
    }
  }
