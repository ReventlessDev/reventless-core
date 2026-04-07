// CategoriesView StateViewSlice.
// Projects category events from the shared catalog event log into a Categories read model.
@@reventless.spec

@schema
type state = {categoryId: string, name: string, archived: bool}

@schema
type consumedEvent =
  | CategoryAdded({categoryId: string, name: string})
  | CategoryRenamed({categoryId: string, name: string})
  | CategoryArchived({categoryId: string})

let project = event =>
  switch event {
  | CategoryAdded({categoryId, name}) => [
      Set(categoryId, {categoryId, name, archived: false}),
    ]
  | CategoryRenamed({categoryId, name}) => [Update(categoryId, state => {...state, name})]
  | CategoryArchived({categoryId}) => [Update(categoryId, state => {...state, archived: true})]
  }
