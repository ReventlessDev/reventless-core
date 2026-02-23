// CatalogItem projection mappings.
// Maps aggregate events to read model state changes.

module ItemMapping = Reventless.Projection.Mapping.Make(
  CatalogItem,
  CatalogItemsReadModel,
  {
    let map = ({Reventless.Message.event: event, id, _}) =>
      switch event {
      | CatalogItem.ItemCreated({itemId: iid, name: n, description: d}) =>
        ReventlessSpec.Projection.Set(
          id,
          {CatalogItemsReadModel.itemId: iid, name: n, description: d, archived: false},
        )
      | CatalogItem.ItemRenamed({newName}) =>
        ReventlessSpec.Projection.Update(id, state => {...state, name: newName})
      | CatalogItem.ItemUpdated({itemId: iid, name: n, description: d}) =>
        ReventlessSpec.Projection.Update(
          id,
          state => {...state, itemId: iid, name: n, description: d},
        )
      | CatalogItem.ItemArchived(_) =>
        ReventlessSpec.Projection.Update(id, state => {...state, archived: true})
      }
  },
)

module Mappings = Reventless.Projection.Mappings.Make(CatalogItemsReadModel)

let mappings: array<module(Mappings.Mapping)> = [module(ItemMapping)]
