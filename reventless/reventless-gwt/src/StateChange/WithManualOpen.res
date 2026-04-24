// Second Spec used by the companion-fixtures manual-open dedup verification
// test at [tests/StateChange/WithManualOpen_GWT.res]. Identical shape to
// [WithFixtures.res]; named differently so it gets its own companion
// [<Stem>_Fixtures] sibling that the PPX considers for auto-open.

let name = "WithManualOpen"

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
