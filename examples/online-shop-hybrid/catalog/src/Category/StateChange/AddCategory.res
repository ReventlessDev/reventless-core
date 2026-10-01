// AddCategory StateChangeSlice.
// Handles the AddCategory command; rejects duplicate creation via DCB optimistic concurrency.
@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

@schema
type command =
  | @authorize(AllowRoles([Admin, Merchandiser]))
  AddCategory({
      categoryId: CategoryId.t,
      name: string,
    })

@schema
type error = CategoryAlreadyExists

@schema
type event = CategoryAdded({categoryId: CategoryId.t, name: string})
