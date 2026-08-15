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

@schema
type state = {
  categoryId: string,
  name: string,
  // Archiving a category withdraws it from the catalog without deleting it: the
  // products filed under it still name it, and a merchandiser still needs to
  // find it. `@retired` is what makes the platform enforce that — ordinary reads
  // exclude these rows — and what lets a consumer render the state beside the
  // category's name instead of as a column reading `false` on all but a handful
  // of rows.
  @retired archived: bool,
  @storageRef("categoryImages") imageUrl?: string,
}
