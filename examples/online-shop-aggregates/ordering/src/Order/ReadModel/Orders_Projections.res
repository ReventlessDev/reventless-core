// Order projection mappings.
// Maps Order aggregate events to Orders read model state changes.
@@reventless.mappings

module OrderMapping = Mapping.Make(
  Order,
  Orders,
  {
    open Order
    let project = ({event, id, _}) =>
      switch event {
      | Placed({customerId, productIds}) =>
        Set(
          id,
          {
            Orders.customerId: customerId,
            productIds,
            lifecycle: (Placed: Orders.lifecycle),
          },
        )
      | Shipped =>
        Update(id, state => {...state, lifecycle: (Shipped: Orders.lifecycle)})
      | Cancelled(_) =>
        Update(id, state => {...state, lifecycle: (Cancelled: Orders.lifecycle)})
      | Refunded(_) =>
        Update(id, state => {...state, lifecycle: (Refunded: Orders.lifecycle)})
      }
  },
)

let mappings: array<module(Mapping)> = [module(OrderMapping)]
