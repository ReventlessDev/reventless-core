// External-Spec verification test for @@reventless.gwt.
//
// Zero payload, no local module, no alias. The PPX resolves:
//   - Kind from the folder segment "StateChange" -> Behavior
//   - Spec from the filename stem (strip "_GWT") -> ExternalAddCategorySlice
//   - Impl derived as ExternalAddCategorySlice_Behavior
//   - open ExternalAddCategorySlice +
//     include Behavior_GWT.Make(ExternalAddCategorySlice, ExternalAddCategorySlice_Behavior)
//
// Mirrors the canonical consumer pattern documented in
// docs/guides/given-when-then.md § 4.10.

@@reventless.gwt

describe("ExternalAddCategory StateChangeSlice (external Spec)", () => {
  test("empty event log produces CategoryAdded", () =>
    givenEvents([])
    ->whenCmd(AddCategory({categoryId: "c1", name: "Electronics"}))
    ->thenEvent(CategoryAdded({categoryId: "c1", name: "Electronics"}))
  )

  test("existing category returns CategoryAlreadyExists", () =>
    givenEvents([CategoryAdded])
    ->whenCmd(AddCategory({categoryId: "c1", name: "X"}))
    ->thenError(CategoryAlreadyExists)
  )
})
