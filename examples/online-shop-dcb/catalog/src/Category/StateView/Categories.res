// Categories StateViewSlice.
// Projects category events from the shared catalog event log into a Categories read model.
@@reventless.spec

// Rows are keyed by this identity.
module Key = CategoryId

@schema
type state = {categoryId: CategoryId.t, name: string, archived: bool}

@schema
type consumedEvent =
  | CategoryAdded({categoryId: CategoryId.t, name: string})
  | CategoryRenamed({categoryId: CategoryId.t, name: string})
  | CategoryArchived({categoryId: CategoryId.t})
