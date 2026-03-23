// RenameCategory StateChangeSlice.
// Requires category to exist and not be archived.

open Reventless
open CatalogEventLog

let name = "RenameCategory"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = CatalogEventLog

@schema
type command = RenameCategory({categoryId: @s.matches(DcbTag.string) string, name: string})

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived

type state = {exists: bool, archived: bool}

let initialState = {exists: false, archived: false}

let evolve = (state, event) =>
  switch event {
  | CategoryAdded(_) => {exists: true, archived: false}
  | CategoryArchived(_) => {...state, archived: true}
  | _ => state
  }

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
