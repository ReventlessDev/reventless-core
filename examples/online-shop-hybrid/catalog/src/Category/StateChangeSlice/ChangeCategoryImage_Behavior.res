@@reventless.behavior

type state = {exists: bool, archived: bool, currentImageUrl: option<string>}

let initialState = {exists: false, archived: false, currentImageUrl: None}

let evolve = (state, event) =>
  switch event {
  | CategoryAdded({imageUrl: ?imageUrl}) => {
      exists: true,
      archived: false,
      currentImageUrl: imageUrl,
    }
  | CategoryImageChanged({imageUrl}) => {...state, currentImageUrl: Some(imageUrl)}
  | CategoryArchived => {...state, archived: true}
  | CategoryUnarchived => {...state, archived: false}
  }

let decide = (state, command) =>
  switch command {
  | ChangeCategoryImage({categoryId, imageUrl}) =>
    if !state.exists {
      Error(CategoryNotFound)
    } else if state.archived {
      Error(CategoryAlreadyArchived)
    } else if Some(imageUrl) == state.currentImageUrl {
      Ok([]) // idempotent — image unchanged
    } else {
      Ok([CategoryImageChanged({categoryId, imageUrl})])
    }
  }
