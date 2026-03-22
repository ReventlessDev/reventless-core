// Category projection mappings.
// Maps Category aggregate events to Categories read model state changes.

open Reventless.Message
open Reventless.Projection

module CategoryMapping = Mapping.Make(
  Category,
  CategoriesReadModel,
  {
    open Category
    let map = ({event, id, _}) =>
      switch event {
      | Added({name}) =>
        Set(id, {CategoriesReadModel.name: name, archived: false})
      | Renamed({name}) => Update(id, state => {...state, name})
      | Archived => Update(id, state => {...state, archived: true})
      }
  },
)
