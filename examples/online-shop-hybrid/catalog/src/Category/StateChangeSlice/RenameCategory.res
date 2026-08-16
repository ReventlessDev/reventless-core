// RenameCategory StateChangeSlice.
// Requires category to exist and not be archived. Renaming to the current
// name is a no-op — commands may be retried under at-least-once delivery.
@@reventless.spec

// `CategoryAdded` / `CategoryRenamed` carry `name` so the decision model knows
// the current name and can short-circuit a rename to the same value.
@schema
type consumedEvent =
  | CategoryAdded({name: string})
  | CategoryRenamed({name: string})
  | CategoryArchived
  // A category back in the catalog can be renamed again; without this the slice
  // keeps refusing on a flag that is no longer true.
  | CategoryUnarchived

// A from-set and no target: renaming a category is legal only while it is on
// the shelf, and it does not move it anywhere. `decide` already refuses with
// `CategoryAlreadyArchived`; the declaration is what keeps the command off an
// archived row's menu instead of offering it and then refusing.
@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Categories.Listed])
  RenameCategory({categoryId: string, name: string})

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived

@schema
type event = CategoryRenamed({categoryId: string, name: string})
