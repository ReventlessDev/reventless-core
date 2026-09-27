// A state mismatch's hint names the fold that produced the state: `project` for
// a view's scenario, `evolve` for a behavior's.

open JestGlobals

module CategoriesView = {
  module Key = Reventless.Id.StringPure
  let name = "CategoriesView"

  @schema
  type state = {categoryId: string, name: string}

  @schema
  type consumedEvent = CategoryAdded({categoryId: string, name: string})

  let subIdConfig = None
}

module CategoriesViewProjection = {
  module Spec = CategoriesView
  open CategoriesView

  let project = ({event}: Reventless.StateViewSlice.consumed<consumedEvent>) =>
    switch event {
    | CategoryAdded({categoryId, name}) => [
        Reventless.Projection.Set(categoryId, {categoryId, name}),
      ]
    }
}

module View = Projection_GWT.Make(CategoriesView, CategoriesViewProjection)

describe("Hint for a StateMismatch", () => {
  testPromise("a view's differing row points at project", async () => {
    let outcome = await View.givenEvents([])
    ->View.whenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
    ->View.thenStateWithId("c1", {categoryId: "c1", name: "Books"})
    switch outcome {
    | Error(m) =>
      let hint = Hint.forMismatch(~slice=CategoriesView.name, m)
      expect(hint.locus)->toBe("CategoriesView.project")
      expect(hint.message)->toBe(
        "project() filed a different row than expected. Check the arm for the event and the key it sets.",
      )
    | Ok() => JsError.throwWithMessage("expected a StateMismatch")
    }
  })

  testSync("a behavior's differing state still points at evolve", () => {
    let hint = Hint.forMismatch(
      ~slice="AddCategory",
      Outcome.StateMismatch({key: "c1", expected: None, actual: None}),
    )
    expect(hint.locus)->toBe("AddCategory.evolve")
  })
})
