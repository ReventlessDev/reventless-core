// Order projection mappings.
// Maps Order aggregate events to Orders read model state changes.

open ReventlessSpec.Message
open ReventlessSpec.Projection
open Order

module OrderMapping = Mapping.Make(
  Order,
  OrdersReadModel,
  {
    let map = ({event, id, _}) =>
      switch event {
      | OrderPlaced({orderId, customerId, productIds}) =>
        Set(id, {OrdersReadModel.orderId, customerId, productIds, status: "placed"})
      | OrderShipped(_) => Update(id, state => {...state, status: "shipped"})
      | OrderCancelled(_) => Update(id, state => {...state, status: "cancelled"})
      }
  },
)

module Mappings = Mappings.Make(OrdersReadModel)

let mappings: array<module(Mappings.Mapping)> = [module(OrderMapping)]
