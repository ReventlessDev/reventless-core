// ArchiveCategory StateChangeSlice.
// Requires category to exist; idempotent if already archived.

open Reventless

let name = "ArchiveCategory"
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
type command = ArchiveCategory({categoryId: @s.matches(DcbTag.string) string})

@schema
type error = CategoryNotFound

@schema
type event = CategoryArchived({categoryId: @s.matches(DcbTag.string) string})

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
