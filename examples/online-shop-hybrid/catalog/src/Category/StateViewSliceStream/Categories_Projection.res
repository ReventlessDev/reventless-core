@@reventless.projection

let project = ({event}) =>
  switch event {
  | CategoryAdded({categoryId, name, imageUrl: ?imageUrl}) => [
      Set(categoryId, {categoryId, name, shelfStatus: Listed, imageUrl: ?imageUrl}),
    ]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryImageChanged({categoryId, imageUrl}) => [
      Update(categoryId, state => {...state, imageUrl}),
    ]
  | CategoryArchived({categoryId}) => [
      Update(categoryId, state => {...state, shelfStatus: Archived}),
    ]
  | CategoryUnarchived({categoryId}) => [
      Update(categoryId, state => {...state, shelfStatus: Listed}),
    ]
  }
