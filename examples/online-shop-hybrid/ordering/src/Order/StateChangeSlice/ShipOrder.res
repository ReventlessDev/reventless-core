// ShipOrder StateChangeSlice.
// Requires order to exist and not be cancelled; idempotent if already shipped.

open Reventless
open OrderingEventLog

let name = "ShipOrder"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type command = ShipOrder({orderId: @s.matches(DcbTag.string) string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyCancelled

type state = {exists: bool, shipped: bool, cancelled: bool}

let initialState = {exists: false, shipped: false, cancelled: false}

let evolve = (state, event) =>
  switch event {
  | OrderPlaced(_) => {exists: true, shipped: false, cancelled: false}
  | OrderShipped(_) => {...state, shipped: true}
  | OrderCancelled(_) => {...state, cancelled: true}
  | _ => state
  }

let decide = (state, command) =>
  switch command {
  | ShipOrder({orderId: theId}) =>
    if !state.exists {
      Error(OrderNotFound)
    } else if state.cancelled {
      Error(OrderAlreadyCancelled)
    } else if state.shipped {
      Ok([]) // idempotent — already shipped
    } else {
      Ok([OrderShipped({orderId: theId})])
    }
  }
