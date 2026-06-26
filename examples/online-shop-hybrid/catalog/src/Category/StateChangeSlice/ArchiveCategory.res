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

// `categoryId` is this slice's partition; AddProduct's cross-partition read of it
// is inferred from the slice graph (see AddCategory) — no annotation needed.
@schema
type event = CategoryArchived({categoryId: string})
