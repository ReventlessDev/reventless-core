// Order projection mappings.
// Maps Order aggregate events to Orders read model state changes.

open Reventless.Message
open Reventless.Projection

module OrderMapping = Mapping.Make(
  Order,
  OrdersReadModel,
  {
    open Order
    let map = ({event, id, _}) =>
      switch event {
      | Placed({customerId, productIds}) =>
        Set(id, {OrdersReadModel.orderId: id, customerId, productIds, status: "placed"})
      | Shipped => Update(id, state => {...state, status: "shipped"})
      | Cancelled(_) => Update(id, state => {...state, status: "cancelled"})
      }
  },
)
