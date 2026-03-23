// ArchiveCategory StateChangeSlice.
// Requires category to exist; idempotent if already archived.

open Reventless
open CatalogEventLog

let name = "ArchiveCategory"
let moduleUrl: string = %raw(`import.meta.url`)

module DcbEventLogSpec = CatalogEventLog

@schema
type command = ArchiveCategory({categoryId: @s.matches(DcbTag.string) string})

@schema
type error = CategoryNotFound

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
  | ArchiveCategory({categoryId: theId}) =>
    if !state.exists {
      Error(CategoryNotFound)
    } else if state.archived {
      Ok([]) // idempotent — already archived
    } else {
      Ok([CategoryArchived({categoryId: theId})])
    }
  }
