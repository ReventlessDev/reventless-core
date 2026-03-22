// Order aggregate behavior.
// Implements the lifecycle for placing, shipping, and cancelling orders.

open Reventless
open Reventless.Message
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

let moduleUrl: string = %raw(`import.meta.url`)

let init = event =>
  switch event {
  | Order.Placed({customerId, productIds}) => Placed({customerId, productIds})
  | Order.Shipped
  | Order.Cancelled(_) =>
    throw(InvalidEvent(event->encode(eventSchema)))
  }

let apply = (state, event) =>
  switch (state, event) {
  | (Placed(_), Order.Placed({customerId, productIds})) => Placed({customerId, productIds})
  | (Placed(_), Order.Shipped) => Shipped
  | (Placed(_), Order.Cancelled(_)) => Cancelled
  | (Shipped, _) => state
  | (Cancelled, _) => state
  }

let create = (command, _context, errorHandler) =>
  switch command {
  | Place({customerId, productIds}) => [
      Order.Placed({customerId, productIds}),
    ]
  | Ship
  | Cancel =>
    errorHandler(OrderNotFound, command, _context)
  }

let execute = (state, command, context, errorHandler) =>
  switch (state, command) {
  | (Placed(_), Place(_)) => errorHandler(OrderAlreadyPlaced, command, context)
  | (Placed(_), Ship) => [Order.Shipped]
  | (Placed({productIds}), Cancel) => [Order.Cancelled({productIds: productIds})]
  | (Shipped, Place(_)) => errorHandler(OrderAlreadyShipped, command, context)
  | (Shipped, Ship) => [] // idempotent
  | (Shipped, Cancel) => errorHandler(OrderAlreadyShipped, command, context)
  | (Cancelled, Place(_)) => errorHandler(OrderAlreadyCancelled, command, context)
  | (Cancelled, Ship) => errorHandler(OrderAlreadyCancelled, command, context)
  | (Cancelled, Cancel) => [] // idempotent
  }
