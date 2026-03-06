// AutoShipOrder AutomationSlice.
// When OrderPlaced is emitted, automatically issue a ShipOrder command.
// Resolved when OrderShipped arrives.

open Reventless
open OrderingEventLog

let name = "AutoShipOrder"
module DcbEventLogSpec = OrderingEventLog

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: @s.matches(DcbTag.string) string})

let collect = event =>
  switch event {
  | OrderPlaced({orderId}) => [(orderId, {orderId: orderId})]
  | _ => []
  }

let resolve = event =>
  switch event {
  | OrderShipped({orderId}) => Some(orderId)
  | _ => None
  }

let process = (id, _item) => Some((id, ShipOrder({orderId: id})))

let maxRetries = 3
let heartbeatInterval = 60
