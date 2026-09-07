@@reventless.behavior

type state = {exists: bool, archived: bool}

let initialState = {exists: false, archived: false}

let evolve = (state, event) =>
  switch event {
  | CategoryAdded => {exists: true, archived: false}
  | CategoryArchived => {...state, archived: true}
  | CategoryUnarchived => {...state, archived: false}
  }

let decide = (state, command) =>
  switch command {
  | UnarchiveCategory({categoryId: theId}) =>
    if !state.exists {
      Error(CategoryNotFound)
    } else if !state.archived {
      Ok([]) // idempotent — already in the catalog
    } else {
      Ok([CategoryUnarchived({categoryId: theId})])
    }
  }
