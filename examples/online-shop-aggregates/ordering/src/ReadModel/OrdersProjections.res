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
        Set(
          id,
          {
            OrdersReadModel.customerId: customerId,
            productIds,
            status: (Placed: OrdersReadModel.status),
          },
        )
      | Shipped =>
        Update(id, state => {...state, status: (Shipped: OrdersReadModel.status)})
      | Cancelled(_) =>
        Update(id, state => {...state, status: (Cancelled: OrdersReadModel.status)})
      }
  },
)
