// ArchiveCategory StateChangeSlice.
// Requires category to exist; idempotent if already archived.
@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

@schema
type command = ArchiveCategory({categoryId: string})

@schema
type error = CategoryNotFound

@schema
type event = CategoryArchived({categoryId: string})
