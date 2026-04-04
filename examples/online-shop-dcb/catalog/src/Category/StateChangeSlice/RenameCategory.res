// RenameCategory StateChangeSlice.
// Requires category to exist and not be archived.

open Reventless

let name = "RenameCategory"
module Id = Reventless.Id.String
let moduleUrl: string = %raw(`import.meta.url`)

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
type command = RenameCategory({categoryId: @s.matches(DcbTag.string) string, name: string})

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived

@schema
type event = CategoryRenamed({categoryId: @s.matches(DcbTag.string) string, name: string})

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
