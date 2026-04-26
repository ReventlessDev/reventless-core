// AddCategory StateChangeSlice.
// Handles the AddCategory command; rejects duplicate creation via DCB optimistic concurrency.
@@reventless.spec


@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

@schema
type command = AddCategory({categoryId: string, name: string})

@schema
type error = CategoryAlreadyExists

@schema
type event = CategoryAdded({categoryId: string, name: string})
