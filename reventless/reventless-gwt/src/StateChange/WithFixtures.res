// Production-shaped Spec for the companion-fixtures auto-open verification
// tests at [tests/StateChange/WithFixtures_GWT.res] and
// [tests/StateChange/WithManualOpen_GWT.res].
//
// Spec half — pairs with [WithFixtures_Behavior.res].

let name = "WithFixtures"

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
