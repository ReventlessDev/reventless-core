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

// `categoryId` is `@crossPartition` to agree with the global per-key scope used
// by AddProduct's cross-partition category read (see AddCategory).
@schema
type event = CategoryRenamed({@crossPartition categoryId: string, name: string})
