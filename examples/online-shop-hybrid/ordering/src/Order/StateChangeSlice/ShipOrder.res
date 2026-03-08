// ShipOrder StateChangeSlice.
// Requires order to exist and not be cancelled; idempotent if already shipped.

open Reventless
open OrderingEventLog

let name = "ShipOrder"

module DcbEventLogSpec = OrderingEventLog

@schema
type command = ShipOrder({orderId: @s.matches(DcbTag.string) string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyCancelled

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
  | ShipOrder({orderId: theId}) =>
    if !model.exists {
      Error(OrderNotFound)
    } else if model.cancelled {
      Error(OrderAlreadyCancelled)
    } else if model.shipped {
      Ok([]) // idempotent — already shipped
    } else {
      Ok([OrderShipped({orderId: theId})])
    }
  }
