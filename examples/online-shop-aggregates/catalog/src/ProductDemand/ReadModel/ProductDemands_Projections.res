// ProductDemands projection mappings.
// Multi-source read model: combines events from two aggregates.
// Source 1: Product — initialises the entry on Added.
// Source 2: ProductDemand — increments / decrements the order count.
@@reventless.mappings

module ProductMapping = Mapping.Make(
  Product,
  ProductDemands,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name}) =>
        Set(id, {ProductDemands.name: name, orderCount: 0})
      | _ => Ignore
      }
  },
)

module ProductDemandMapping = Mapping.Make(
  ProductDemand,
  ProductDemands,
  {
    open ProductDemand
    let project = ({event, id, _}) =>
      switch event {
      | Recorded(_) =>
        Update(id, (state: ProductDemands.state) => {...state, orderCount: state.orderCount + 1})
      | Revoked(_) =>
        Update(id, (state: ProductDemands.state) => {...state, orderCount: max(0, state.orderCount - 1)})
      }
  },
)

let mappings: array<module(Mapping)> = [module(ProductMapping), module(ProductDemandMapping)]
