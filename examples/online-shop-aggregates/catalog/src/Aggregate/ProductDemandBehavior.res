// ProductDemand aggregate behavior.
// Idempotently records and revokes order demand per product.

open Reventless
open ProductDemand

module Spec = ProductDemand

@schema
type state = {recordedOrderIds: array<string>}

let resolverConfig = {Behavior.commandSchema, fields: []}

let init = event =>
  switch event {
  | Recorded({orderId}) => {recordedOrderIds: [orderId]}
  | Revoked(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch event {
  | Recorded({orderId}) =>
    {recordedOrderIds: Array.concat(state.recordedOrderIds, [orderId])}
  | Revoked({orderId}) =>
    {recordedOrderIds: state.recordedOrderIds->Array.filter(id => id !== orderId)}
  }

let create = (command, _context, _errorHandler) =>
  switch command {
  | Record({orderId}) => [Recorded({orderId: orderId})]
  | Revoke(_) => [] // nothing recorded yet — idempotent
  }

let execute = (state, command, _context, _errorHandler) =>
  switch command {
  | Record({orderId}) =>
    if state.recordedOrderIds->Array.includes(orderId) {
      [] // idempotent
    } else {
      [Recorded({orderId: orderId})]
    }
  | Revoke({orderId}) =>
    if !(state.recordedOrderIds->Array.includes(orderId)) {
      [] // idempotent
    } else {
      [Revoked({orderId: orderId})]
    }
  }
