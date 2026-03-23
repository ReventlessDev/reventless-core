// PlaceOrder StateChangeSlice.
// Handles the PlaceOrder command; rejects duplicate placement.

open Reventless
open OrderingEventLog

let name = "PlaceOrder"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | PlaceOrder({
      orderId: @s.matches(DcbTag.string) string,
      customerId: string,
      productIds: array<string>,
    })

@schema
type error = OrderAlreadyPlaced

type state = {exists: bool}

let initialState = {exists: false}

let evolve = (state, event) =>
  switch event {
  | OrderPlaced(_) => {exists: true}
  | _ => state
  }

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productIds}) =>
    if state.exists {
      Error(OrderAlreadyPlaced)
    } else {
      Ok([OrderPlaced({orderId, customerId, productIds})])
    }
  }
