@@reventless.projection

let project = ({event}) =>
  switch event {
  | CategoryAdded({categoryId, name, imageUrl: ?imageUrl}) => [
      Set(categoryId, {categoryId, name, archived: false, imageUrl: ?imageUrl}),
    ]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryImageChanged({categoryId, imageUrl}) => [
      Update(categoryId, state => {...state, imageUrl}),
    ]
  | CategoryArchived({categoryId}) => [Update(categoryId, state => {...state, archived: true})]
  | CategoryUnarchived({categoryId}) => [
      Update(categoryId, state => {...state, archived: false}),
    ]
  }
