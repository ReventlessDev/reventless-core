// AvailableProducts projection mappings.
// Maps CatalogProduct aggregate events to the AvailableProducts read model.

open Reventless
open Reventless.Projection

module CatalogProductMapping = Mapping.Make(
  CatalogProduct,
  AvailableProductsReadModel,
  {
    let map = ({Message.event: event, id, _}) =>
      switch event {
      | CatalogProduct.CatalogProductSynced({productId, name, price}) =>
        Set(id, {AvailableProductsReadModel.productId, name, price})
      | CatalogProduct.CatalogProductPriceUpdated({price}) =>
        Update(id, state => {...state, price})
      }
  },
)

module Mappings = Mappings.Make(AvailableProductsReadModel)

let mappings: array<module(Mappings.Mapping)> = [module(CatalogProductMapping)]
