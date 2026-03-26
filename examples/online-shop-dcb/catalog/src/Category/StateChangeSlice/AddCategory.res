// AddCategory StateChangeSlice.
// Handles the AddCategory command; rejects duplicate creation via DCB optimistic concurrency.

open Reventless

let name = "AddCategory"
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
type command = AddCategory({categoryId: @s.matches(DcbTag.string) string, name: string})

@schema
type error = CategoryAlreadyExists

@schema
type producedEvent = CategoryAdded({categoryId: @s.matches(DcbTag.string) string, name: string})

let decide = (state, command) =>
  switch command {
  | AddCategory({categoryId, name}) =>
    if state.exists {
      Error(CategoryAlreadyExists)
    } else {
      Ok([CategoryAdded({categoryId, name})])
    }
  }
