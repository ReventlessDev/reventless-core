// ArchiveCategory StateChangeSlice.
// Requires category to exist; idempotent if already archived.
@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

@schema
type command = | @authorize(AllowGroups(["Admin"])) ArchiveCategory({categoryId: CategoryId.t})

@schema
type error = CategoryNotFound

@schema
type event = CategoryArchived({categoryId: CategoryId.t})
