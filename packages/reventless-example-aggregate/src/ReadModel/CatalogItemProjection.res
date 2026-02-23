// CatalogItem projection mappings.
// Maps aggregate events to read model state changes.

module ItemMapping = Reventless.Projection.Mapping.Make(
  CatalogItemSpec,
  CatalogItemReadModelSpec,
  {
    let map = ({Reventless.Message.event, id, _}) =>
      switch event {
      | CatalogItemSpec.ItemCreated({itemId: iid, name: n, description: d}) =>
        ReventlessSpec.Projection.Set(
          id,
          {CatalogItemReadModelSpec.itemId: iid, name: n, description: d, archived: false},
        )
      | CatalogItemSpec.ItemUpdated({itemId: iid, name: n, description: d}) =>
        ReventlessSpec.Projection.Update(id, state => {...state, itemId: iid, name: n, description: d})
      | CatalogItemSpec.ItemArchived(_) =>
        ReventlessSpec.Projection.Update(id, state => {...state, archived: true})
      }
  },
)

module MappingsHelper = Reventless.Projection.Mappings.Make(CatalogItemReadModelSpec)

let mappings: array<module(MappingsHelper.Mapping)> = [module(ItemMapping)]
