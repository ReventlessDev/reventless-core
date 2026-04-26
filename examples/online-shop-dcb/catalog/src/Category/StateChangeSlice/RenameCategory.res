// RenameCategory StateChangeSlice.
// Requires category to exist and not be archived.
@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

@schema
type command = RenameCategory({categoryId: string, name: string})

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived

@schema
type event = CategoryRenamed({categoryId: string, name: string})
