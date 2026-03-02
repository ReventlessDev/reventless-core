// ProductDemand projection mappings.
// Multi-source read model: combines events from two aggregates.
// Source 1: Product — initialises the entry on ProductAdded.
// Source 2: ProductDemand — increments / decrements the order count.

open Reventless
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,
  ProductDemandReadModel,
  {
    let map = ({Message.event: event, id, _}) =>
      switch event {
      | Product.ProductAdded({productId, name}) =>
        Set(id, {ProductDemandReadModel.productId, name, orderCount: 0})
      | _ => Ignore
      }
  },
)

module ProductDemandMapping = Mapping.Make(
  ProductDemand,
  ProductDemandReadModel,
  {
    let map = ({Message.event: event, id, _}) =>
      switch event {
      | ProductDemand.ProductDemandRecorded(_) =>
        Update(id, (state: ProductDemandReadModel.state) => {...state, orderCount: state.orderCount + 1})
      | ProductDemand.ProductDemandRevoked(_) =>
        Update(id, (state: ProductDemandReadModel.state) => {...state, orderCount: max(0, state.orderCount - 1)})
      }
  },
)

module Mappings = Mappings.Make(ProductDemandReadModel)

let mappings: array<module(Mappings.Mapping)> = [module(ProductMapping), module(ProductDemandMapping)]
