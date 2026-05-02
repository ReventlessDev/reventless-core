// AvailableProducts projection mappings.
// Maps CatalogProduct aggregate events to the AvailableProducts read model.
@@reventless.mappings

module CatalogProductMapping = Mapping.Make(
  CatalogProduct,
  AvailableProducts,
  {
    open CatalogProduct
    let project = ({event, id, _}) =>
      switch event {
      | Synced({name, price}) =>
        Set(id, {AvailableProducts.name: name, price})
      | PriceUpdated({price}) =>
        Update(id, state => {...state, price})
      }
  },
)

let mappings: array<module(Mapping)> = [module(CatalogProductMapping)]
