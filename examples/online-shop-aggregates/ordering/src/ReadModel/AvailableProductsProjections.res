// AvailableProducts projection mappings.
// Maps CatalogProduct aggregate events to the AvailableProducts read model.

open Reventless.Message
open Reventless.Projection

module CatalogProductMapping = Mapping.Make(
  CatalogProduct,
  AvailableProductsReadModel,
  {
    open CatalogProduct
    let map = ({event, id, _}) =>
      switch event {
      | Synced({name, price}) =>
        Set(id, {AvailableProductsReadModel.productId: id, name, price})
      | PriceUpdated({price}) =>
        Update(id, state => {...state, price})
      }
  },
)
