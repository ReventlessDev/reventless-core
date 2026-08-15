// ArchiveCategory StateChangeSlice.
// Requires category to exist; idempotent if already archived.
@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived
  // Without this the slice's own `archived` goes stale the moment a category
  // returns to the catalog, and archiving it a second time reads as a repeat and
  // is swallowed. Every slice that decides on this flag consumes both events.
  | CategoryUnarchived

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"])) ArchiveCategory({categoryId: string})

@schema
type error = CategoryNotFound

@schema
type event = CategoryArchived({categoryId: string})
