@@reventless.behavior

type state = {exists: bool, archived: bool}

let initialState = {exists: false, archived: false}

let evolve = (state, event) =>
  switch event {
  | CategoryAdded => {exists: true, archived: false}
  | CategoryArchived => {...state, archived: true}
  }

let decide = (state, command) =>
  switch command {
  | ArchiveCategory({categoryId: theId}) =>
    if !state.exists {
      Error(CategoryNotFound)
    } else if state.archived {
      Ok([]) // idempotent — already archived
    } else {
      Ok([CategoryArchived({categoryId: theId})])
    }
  }
