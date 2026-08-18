@@reventless.behavior

type state = {exists: bool, archived: bool, currentImageUrl: option<string>}

let initialState = {exists: false, archived: false, currentImageUrl: None}

let evolve = (state, event) =>
  switch event {
  | CategoryAdded({categoryImage: ?categoryImage}) => {
      exists: true,
      archived: false,
      currentImageUrl: categoryImage,
    }
  | CategoryImageChanged({categoryImage}) => {...state, currentImageUrl: Some(categoryImage)}
  | CategoryArchived => {...state, archived: true}
  | CategoryUnarchived => {...state, archived: false}
  }

let decide = (state, command) =>
  switch command {
  | ChangeCategoryImage({categoryId, categoryImage}) =>
    if !state.exists {
      Error(CategoryNotFound)
    } else if state.archived {
      Error(CategoryAlreadyArchived)
    } else if Some(categoryImage) == state.currentImageUrl {
      Ok([]) // idempotent — image unchanged
    } else {
      Ok([CategoryImageChanged({categoryId, categoryImage})])
    }
  }
