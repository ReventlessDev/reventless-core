@@reventless.behavior

type state = {exists: bool, archived: bool, name: string}

let initialState = {exists: false, archived: false, name: ""}

let evolve = (state, event: consumedEvent) =>
  switch event {
  | CategoryAdded({name}) => {exists: true, archived: false, name}
  | CategoryRenamed({name}) => {...state, name}
  | CategoryArchived => {...state, archived: true}
  }

let decide = (state, command) =>
  switch command {
  | RenameCategory({categoryId, name}) =>
    if !state.exists {
      Error(CategoryNotFound)
    } else if state.archived {
      Error(CategoryAlreadyArchived)
    } else if name == state.name {
      Ok([])
    } else {
      Ok([CategoryRenamed({categoryId, name})])
    }
  }
