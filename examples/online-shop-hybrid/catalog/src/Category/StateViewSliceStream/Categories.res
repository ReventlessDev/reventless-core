// Categories StateViewSliceStream.
// Projects category events from the shared catalog event log into a Categories read model.

@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded({categoryId: string, name: string, imageUrl?: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryImageChanged({categoryId: string, imageUrl: string})
  | CategoryArchived({categoryId: string})

@schema
type state = {
  categoryId: string,
  name: string,
  archived: bool,
  @storageRef("categoryImages") imageUrl?: string,
}
