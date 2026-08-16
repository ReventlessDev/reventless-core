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
// beside one, so a command's `@transition` can name it: that is the whole of "offer
// Unarchive on an archived category and Archive on a listed one".
//
// `@retired` sits on the state it names. Archiving withdraws a category from the
// catalog without deleting it — the products filed under it still name it, and a
// merchandiser still needs to find it — and marking the constructor is what makes
// the platform enforce that: ordinary reads exclude these rows.
@schema
type shelfStatus =
  | Listed
  | @retired Archived

@schema
type state = {
  categoryId: string,
  name: string,
  // `@lifecycle` is what makes this the field a command's `@transition` is
  // written in terms of, so the way back is offered exactly where it applies.
  // The retirement is on `shelfStatus`'s own constructor and needs no second
  // annotation here.
  @lifecycle shelfStatus: shelfStatus,
  @storageRef("categoryImages") imageUrl?: string,
}
