// Product projection mappings.
// Maps Product aggregate events to Products read model state changes.

open ReventlessSpec
open ReventlessSpec.Projection
open Reventless.Projection

module ProductMapping = Mapping.Make(
  Product,
  ProductsReadModel,
  {
    let map = ({Message.event: event, id, _}) =>
      switch event {
      | Product.ProductAdded({productId, name, description, price}) =>
        Projection.Set(id, {ProductsReadModel.productId, name, description, price})
      | Product.ProductNameUpdated({name}) => Update(id, state => {...state, name})
      | Product.ProductDescriptionUpdated({description}) =>
        Update(id, state => {...state, description})
      | Product.ProductPriceUpdated({price}) => Update(id, state => {...state, price})
      }
  },
)

module Mappings = Mappings.Make(ProductsReadModel)

let mappings: array<module(Mappings.Mapping)> = [module(ProductMapping)]
