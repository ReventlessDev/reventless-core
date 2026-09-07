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

// Meaningful only on a category still on the shelf. The states are the view's
// own constructors, which is the same field `@retired` marks — one vocabulary,
// so a menu offers this and `UnarchiveCategory` on opposite sides of the same
// fact, and the edge between them is drawn from the declaration rather than
// guessed from the command's name.
type lifecycleState = Categories.shelfStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | ArchiveCategory(_) => Moves([Categories.Listed], Categories.Archived)
  }
}
