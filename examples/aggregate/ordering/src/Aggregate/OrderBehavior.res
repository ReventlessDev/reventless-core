// Order aggregate behavior.
// Implements the lifecycle for placing, shipping, and cancelling orders.

open ReventlessSpec
open ReventlessSpec.Message
open Order

module Spec = Order

@schema
type state =
  | Placed({customerId: string, productIds: array<string>})
  | Shipped
  | Cancelled

let resolverConfig = {
  Behavior.commandSchema,
  fields: [],
}

let init = event =>
  switch event {
  | OrderPlaced({customerId, productIds}) => Placed({customerId, productIds})
  | OrderShipped(_)
  | OrderCancelled(_) =>
    throw(InvalidEvent(event->encode(eventSchema)))
  }

let apply = (state, event) =>
  switch (state, event) {
  | (Placed(_), OrderPlaced({customerId, productIds})) => Placed({customerId, productIds})
  | (Placed(_), OrderShipped(_)) => Shipped
  | (Placed(_), OrderCancelled(_)) => Cancelled
  | (Shipped, _) => state
  | (Cancelled, _) => state
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | PlaceOrder({orderId, customerId, productIds}) => [
      OrderPlaced({orderId, customerId, productIds}),
    ]
  | ShipOrder(_)
  | CancelOrder(_) =>
    errorHandler(OrderNotFound, command, _context)
  }

let execute = (state, command, context, errorHandler) =>
  switch (state, command) {
  | (Placed(_), PlaceOrder(_)) => errorHandler(OrderAlreadyPlaced, command, context)
  | (Placed(_), ShipOrder({orderId: oid})) => [OrderShipped({orderId: oid})]
  | (Placed(_), CancelOrder({orderId: oid})) => [OrderCancelled({orderId: oid})]
  | (Shipped, PlaceOrder(_)) => errorHandler(OrderAlreadyShipped, command, context)
  | (Shipped, ShipOrder(_)) => [] // idempotent
  | (Shipped, CancelOrder(_)) => errorHandler(OrderAlreadyShipped, command, context)
  | (Cancelled, PlaceOrder(_)) => errorHandler(OrderAlreadyCancelled, command, context)
  | (Cancelled, ShipOrder(_)) => errorHandler(OrderAlreadyCancelled, command, context)
  | (Cancelled, CancelOrder(_)) => [] // idempotent
  }
