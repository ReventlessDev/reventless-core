// AutoShipOrder AutomationSlice.
// When OrderPlaced is emitted, automatically issue a ShipOrder command.
// Resolved when OrderShipped arrives.

open Reventless

let name = "AutoShipOrder"
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | OrderShipped({orderId: string})

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: @s.matches(DcbTag.string) string})

let collect = event =>
  switch event {
  | OrderPlaced({orderId}) => [(orderId, {orderId: orderId})]
  | OrderShipped(_) => []
  }

let resolve = event =>
  switch event {
  | OrderShipped({orderId}) => Some(orderId)
  | OrderPlaced(_) => None
  }

let process = (id, _item) => Some((id, ShipOrder({orderId: id})))

let maxRetries = 3
let heartbeatInterval = 60
