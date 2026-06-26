// ArchiveCategory StateChangeSlice.
// Requires category to exist; idempotent if already archived.
@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

@schema
type command =
  | @authorize(AllowGroups(["Admin"])) ArchiveCategory({categoryId: string})

@schema
type error = CategoryNotFound

// `categoryId` is `@crossPartition` to agree with the global per-key scope used
// by AddProduct's cross-partition category read (see AddCategory).
@schema
type event = CategoryArchived({@crossPartition categoryId: string})
