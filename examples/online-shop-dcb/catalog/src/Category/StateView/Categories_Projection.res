@@reventless.projection

let project = ({event}) =>
  switch event {
  | CategoryAdded({categoryId, name}) => [
      Set(categoryId, {categoryId, name, archived: false}),
    ]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryArchived({categoryId}) => [Update(categoryId, state => {...state, archived: true})]
  }
