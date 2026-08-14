// AddCategory StateChangeSlice.
// Handles the AddCategory command; rejects duplicate creation via DCB optimistic concurrency.
@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryArchived

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"])) AddCategory({
      categoryId: string,
      name: string,
      // Optional: a category may be created without an image (absent, not `""`).
      @storageRef("categoryImages") imageUrl?: string,
    })

@schema
type error = CategoryAlreadyExists

@schema
type event =
  | CategoryAdded({
      categoryId: string,
      name: string,
      @storageRef("categoryImages") imageUrl?: string,
    })
