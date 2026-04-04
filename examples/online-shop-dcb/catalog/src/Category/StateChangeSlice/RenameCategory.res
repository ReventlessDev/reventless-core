// RenameCategory StateChangeSlice.
// Requires category to exist and not be archived.
@@reventless.spec

type state = {exists: bool, archived: bool}

let initialState = {exists: false, archived: false}

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

let evolve = (state, event) =>
  switch event {
  | CategoryAdded => {exists: true, archived: false}
  | CategoryArchived => {...state, archived: true}
  }

@schema
type command = RenameCategory({categoryId: string, name: string})

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived

@schema
type event = CategoryRenamed({categoryId: string, name: string})

let decide = (state, command) =>
  switch command {
  | RenameCategory({categoryId, name}) =>
    if !state.exists {
      Error(CategoryNotFound)
    } else if state.archived {
      Error(CategoryAlreadyArchived)
    } else {
      Ok([CategoryRenamed({categoryId, name})])
    }
  }
