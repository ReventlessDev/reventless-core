// Worked example for StateChangeSlice_GWT.
// Uses the canonical "AddCategory" DCB slice shape — payload-less consumed
// events, decide that appends `CategoryAdded` unless the category already
// exists.

module AddCategorySlice = {
  let name = "AddCategory"

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
  type command = AddCategory({categoryId: string, name: string})

  @schema
  type error = CategoryAlreadyExists

  @schema
  type event = CategoryAdded({categoryId: string, name: string})

  let decide = (state, command) =>
    switch command {
    | AddCategory({categoryId, name}) =>
      state.exists
        ? Error(CategoryAlreadyExists)
        : Ok([CategoryAdded({categoryId, name})])
    }
}

include StateChangeSlice_GWT.Make(AddCategorySlice)

describe("AddCategory StateChangeSlice", () => {
  test("on empty event log produces CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
  )

  test("on existing category returns CategoryAlreadyExists", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(AddCategory({categoryId: "c1", name: "X"}))
    ->thenError(CategoryAlreadyExists)
  )
})
