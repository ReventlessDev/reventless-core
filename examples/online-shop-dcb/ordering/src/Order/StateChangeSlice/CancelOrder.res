// CancelOrder StateChangeSlice.
// Requires order to exist and not be shipped; idempotent if already cancelled.

open Reventless
open OrderingEventLog

let name = "CancelOrder"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type command = CancelOrder({orderId: @s.matches(DcbTag.string) string})

@schema
type error =
  | OrderNotFound
  | OrderAlreadyShipped

type state = {exists: bool, shipped: bool, cancelled: bool, productIds: array<string>}

let initialState = {exists: false, shipped: false, cancelled: false, productIds: []}

let evolve = (state, event) =>
  switch event {
  | OrderPlaced({productIds}) => {exists: true, shipped: false, cancelled: false, productIds}
  | OrderShipped(_) => {...state, shipped: true}
  | OrderCancelled(_) => {...state, cancelled: true}
  | _ => state
  }

let decide = (state, command) =>
  switch command {
  | CancelOrder({orderId: theId}) =>
    if !state.exists {
      Error(OrderNotFound)
    } else if state.shipped {
      Error(OrderAlreadyShipped)
    } else if state.cancelled {
      Ok([]) // idempotent — already cancelled
    } else {
      Ok([OrderCancelled({orderId: theId, productIds: state.productIds})])
    }
  }
