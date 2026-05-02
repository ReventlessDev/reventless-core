// Category projection mappings.
// Maps Category aggregate events to Categories read model state changes.
@@reventless.mappings

module CategoryMapping = Mapping.Make(
  Category,
  Categories,
  {
    open Category
    let project = ({event, id, _}) =>
      switch event {
      | Added({name}) => Set(id, {Categories.name: name, archived: false})
      | Renamed({name}) => Update(id, state => {...state, name})
      | Archived => Update(id, state => {...state, archived: true})
      }
  },
)

let mappings: array<module(Mapping)> = [module(CategoryMapping)]
