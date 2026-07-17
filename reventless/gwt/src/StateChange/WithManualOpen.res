// Second Spec used by the companion-fixtures manual-open dedup verification
// test at [tests/StateChange/WithManualOpen_GWT.res]. Identical shape to
// [WithFixtures]; named differently so it gets its own companion
// [<Stem>_Fixtures] sibling that the PPX considers for auto-open.
//
// Spec half — pairs with [WithManualOpen_Behavior.res].

let name = "WithManualOpen"

@schema
type consumedEvent =
  | CategoryAdded

@schema
type command =
  AddCategory({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})

@schema
type error = CategoryAlreadyExists

@schema
type event =
  CategoryAdded({categoryId: @s.matches(Reventless.DcbTag.string) string, name: string})
