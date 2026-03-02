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
  | ProductDemandRecorded({orderId}) => {recordedOrderIds: [orderId]}
  | ProductDemandRevoked(_) =>
    throw(Message.InvalidEvent(event->Message.encode(eventSchema)))
  }

let apply = (state, event) =>
  switch event {
  | ProductDemandRecorded({orderId}) =>
    {recordedOrderIds: Array.concat(state.recordedOrderIds, [orderId])}
  | ProductDemandRevoked({orderId}) =>
    {recordedOrderIds: state.recordedOrderIds->Array.filter(id => id !== orderId)}
  }

let create = (command, _context, _errorHandler) =>
  switch command {
  | RecordDemand({productId, orderId}) => [ProductDemandRecorded({productId, orderId})]
  | RevokeDemand(_) => [] // nothing recorded yet — idempotent
  }

let execute = (state, command, _context, _errorHandler) =>
  switch command {
  | RecordDemand({productId, orderId}) =>
    if state.recordedOrderIds->Array.includes(orderId) {
      [] // idempotent
    } else {
      [ProductDemandRecorded({productId, orderId})]
    }
  | RevokeDemand({productId, orderId}) =>
    if !(state.recordedOrderIds->Array.includes(orderId)) {
      [] // idempotent
    } else {
      [ProductDemandRevoked({productId, orderId})]
    }
  }
