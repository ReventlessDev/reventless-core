// Categories StateViewSliceStream.
// Projects category events from the shared catalog event log into a Categories read model.

@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded({categoryId: string, name: string, imageUrl?: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryImageChanged({categoryId: string, imageUrl: string})
  | CategoryArchived({categoryId: string})
  | CategoryUnarchived({categoryId: string})

// Where a category is in its life in the catalog. A state rather than a flag
// beside one, so `@allowedStates` can name it: that is the whole of "offer
// Unarchive on an archived category and Archive on a listed one".
@schema
type shelfStatus =
  | Listed
  | Archived

@schema
type state = {
  categoryId: string,
  name: string,
  // Archiving a category withdraws it from the catalog without deleting it: the
  // products filed under it still name it, and a merchandiser still needs to
  // find it. `@retired(Archived)` is what makes the platform enforce that —
  // ordinary reads exclude these rows — and `@lifecycle` is what makes the same
  // field the one a command's `@allowedStates` is written in terms of, so the
  // way back is offered exactly where it applies.
  @retired(Archived) @lifecycle shelfStatus: shelfStatus,
  @storageRef("categoryImages") imageUrl?: string,
}
