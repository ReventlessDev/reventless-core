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

@schema
type command = RenameCategory({categoryId: string, name: string})

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived

// `categoryId` is this slice's partition; AddProduct's cross-partition read of it
// is inferred from the slice graph (see AddCategory) — no annotation needed.
@schema
type event = CategoryRenamed({categoryId: string, name: string})
