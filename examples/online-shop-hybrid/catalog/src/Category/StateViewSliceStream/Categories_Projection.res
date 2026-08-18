@@reventless.projection

let project = ({event}) =>
  switch event {
  | CategoryAdded({categoryId, name, categoryImage: ?categoryImage}) => [
      Set(categoryId, {categoryId, name, shelfStatus: Listed, categoryImage: ?categoryImage}),
    ]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryImageChanged({categoryId, categoryImage}) => [
      Update(categoryId, state => {...state, categoryImage}),
    ]
  | CategoryArchived({categoryId}) => [
      Update(categoryId, state => {...state, shelfStatus: Archived}),
    ]
  | CategoryUnarchived({categoryId}) => [
      Update(categoryId, state => {...state, shelfStatus: Listed}),
    ]
  }
