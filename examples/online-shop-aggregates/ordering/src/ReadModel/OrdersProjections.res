// Order projection mappings.
// Maps Order aggregate events to Orders read model state changes.

open Reventless.Message
open Reventless.Projection

module OrderMapping = Mapping.Make(
  Order,
  OrdersReadModel,
  {
    open Order
    let project = ({event, id, _}) =>
      switch event {
      | Placed({customerId, productIds}) =>
        Set(id, {OrdersReadModel.customerId: customerId, productIds, status: "placed"})
      | Shipped => Update(id, state => {...state, status: "shipped"})
      | Cancelled(_) => Update(id, state => {...state, status: "cancelled"})
      }
  },
)
