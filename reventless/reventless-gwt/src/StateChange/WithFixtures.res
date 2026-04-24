// Production-shaped Spec for the companion-fixtures auto-open verification
// tests at [tests/StateChange/WithFixtures_GWT.res] and
// [tests/StateChange/WithManualOpen_GWT.res]. Mirrors the AddCategory slice
// shape: DCB-tagged categoryId, payload-less consumed events, decide that
// guards against duplicates.

let name = "WithFixtures"

type state = {exists: bool}
let initialState = {exists: false}

@schema
type consumedEvent =
  | CategoryAdded

let evolve = (_state, event) =>
  switch event {
  | CategoryAdded => {exists: true}
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
