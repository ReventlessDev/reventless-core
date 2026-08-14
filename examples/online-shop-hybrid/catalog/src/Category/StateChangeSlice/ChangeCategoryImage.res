// ChangeCategoryImage StateChangeSlice.
// Requires category to exist and not be archived; idempotent when the image is
// unchanged.

@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded({imageUrl?: string})
  | CategoryImageChanged({imageUrl: string})
  | CategoryArchived

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"])) ChangeCategoryImage({
      categoryId: string,
      @storageRef("categoryImages") imageUrl: string,
    })

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived

@schema
type event =
  | CategoryImageChanged({
      categoryId: string,
      @storageRef("categoryImages") imageUrl: string,
    })
