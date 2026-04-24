// Production-shaped StateChangeSlice Spec used by the external-Spec
// verification test at [tests/StateChange/ExternalAddCategorySlice_GWT.res].
// Mirrors the worked-example AddCategory slice shape: DCB-tagged categoryId
// on command + event, payload-less consumed events, decide that guards
// against duplicates.

let name = "ExternalAddCategory"

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
type command =
  AddCategory({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

@schema
type error = CategoryAlreadyExists

@schema
type event =
  CategoryAdded({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

let decide = (state, command) =>
  switch command {
  | AddCategory({categoryId, name}) =>
    state.exists ? Error(CategoryAlreadyExists) : Ok([CategoryAdded({categoryId, name})])
  }
