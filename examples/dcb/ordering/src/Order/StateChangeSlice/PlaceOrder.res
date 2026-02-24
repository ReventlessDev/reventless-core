// PlaceOrder StateChangeSlice.
// Handles the PlaceOrder command; rejects duplicate placement.

open ReventlessSpec
open OrderingEventLog

let name = "PlaceOrder"

module DcbEventLogSpec = OrderingEventLog

@schema
type command =
  | PlaceOrder({
      orderId: @s.matches(DcbTag.string) string,
      customerId: string,
      productIds: array<string>,
    })

@schema
type error = | OrderAlreadyPlaced

type decisionModel = {exists: bool}

let initialDecisionModel = {exists: false}

let reduce = (model, event) =>
  switch event {
  | OrderPlaced(_) => {exists: true}
  | _ => model
  }

let decide = (model, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productIds}) =>
    if model.exists {
      Error(OrderAlreadyPlaced)
    } else {
      Ok([OrderPlaced({orderId, customerId, productIds})])
    }
  }
