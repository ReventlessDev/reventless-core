// Worked example for StateViewSlice_GWT.
// Projects a small category event stream into a `{categoryId, name, archived}`
// read model, exercising Set / Update actions.

open Reventless.Projection

module CategoriesViewSpec = {
  let name = "CategoriesView"

  @schema
  type state = {categoryId: string, name: string, archived: bool}

  @schema
  type consumedEvent =
    | CategoryAdded({categoryId: string, name: string})
    | CategoryRenamed({categoryId: string, name: string})
    | CategoryArchived({categoryId: string})

  let project = event =>
    switch event {
    | CategoryAdded({categoryId, name}) => [
        Set(categoryId, {categoryId, name, archived: false}),
      ]
    | CategoryRenamed({categoryId, name}) => [
        Update(categoryId, state => {...state, name}),
      ]
    | CategoryArchived({categoryId}) => [
        Update(categoryId, state => {...state, archived: true}),
      ]
    }

  let subIdConfig = None
}

include StateViewSlice_GWT.Make(CategoriesViewSpec)

describe("CategoriesView StateViewSlice", () => {
  test("projects CategoryAdded into a new row", () =>
    givenEvents([])
    ->whenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
    ->thenStateWithId(
      "c1",
      {categoryId: "c1", name: "Electronics", archived: false},
    )
  )

  test("CategoryRenamed updates the name", () =>
    givenEvents([CategoryAdded({categoryId: "c1", name: "Electronics"})])
    ->whenEvent(CategoryRenamed({categoryId: "c1", name: "Consumer Electronics"}))
    ->thenStateWithId(
      "c1",
      {categoryId: "c1", name: "Consumer Electronics", archived: false},
    )
  )
})
