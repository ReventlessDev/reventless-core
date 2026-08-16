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
  // Meaningful only on a category still on the shelf. `@transition` names states
  // of the view's lifecycle, which is the same field `@retired` marks — one
  // vocabulary, so a menu offers this and `UnarchiveCategory` on opposite sides
  // of the same fact, and the edge between them is drawn from the declaration
  // rather than guessed from the command's name.
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition(([Categories.Listed]) => Categories.Archived)
  ArchiveCategory({categoryId: string})

@schema
type error = CategoryNotFound

@schema
type event = CategoryArchived({categoryId: string})
