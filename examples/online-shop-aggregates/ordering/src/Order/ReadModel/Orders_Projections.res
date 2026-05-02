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
            status: (Placed: Orders.status),
          },
        )
      | Shipped =>
        Update(id, state => {...state, status: (Shipped: Orders.status)})
      | Cancelled(_) =>
        Update(id, state => {...state, status: (Cancelled: Orders.status)})
      }
  },
)

let mappings: array<module(Mapping)> = [module(OrderMapping)]
