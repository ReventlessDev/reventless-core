// ProductDemand projection mappings.
// Multi-source read model: combines events from two aggregates.
// Source 1: Product — initialises the entry on Added.
// Source 2: ProductDemand — increments / decrements the order count.
open Reventless.Message
open Reventless.Projection
module ProductMapping = Mapping.Make(
  Product,
  ProductDemandReadModel,
  {
    open Product
    let project = ({event, id, _}) =>
      switch event {
      | Added({name}) =>
        Set(id, {ProductDemandReadModel.name: name, orderCount: 0})
      | _ => Ignore
      }
  },
)
module ProductDemandMapping = Mapping.Make(
  ProductDemand,
  ProductDemandReadModel,
  {
    open ProductDemand
    let project = ({event, id, _}) =>
      switch event {
      | Recorded(_) =>
        Update(id, (state: ProductDemandReadModel.state) => {...state, orderCount: state.orderCount + 1})
      | Revoked(_) =>
        Update(id, (state: ProductDemandReadModel.state) => {...state, orderCount: max(0, state.orderCount - 1)})
      }
  },
)
