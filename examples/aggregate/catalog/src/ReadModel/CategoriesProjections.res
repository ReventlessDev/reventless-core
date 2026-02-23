// Category projection mappings.
// Maps Category aggregate events to Categories read model state changes.

open ReventlessSpec.Message
open ReventlessSpec.Projection
open Reventless.Projection
open Category

module CategoryMapping = Mapping.Make(
  Category,
  CategoriesReadModel,
  {
    let map = ({event, id, _}) =>
      switch event {
      | CategoryAdded({categoryId, name}) =>
        Set(id, {CategoriesReadModel.categoryId, name, archived: false})
      | CategoryRenamed({name}) => Update(id, state => {...state, name})
      | CategoryArchived(_) => Update(id, state => {...state, archived: true})
      }
  },
)

module Mappings = Mappings.Make(CategoriesReadModel)

let mappings: array<module(Mappings.Mapping)> = [module(CategoryMapping)]
