// ChangeCategoryImage StateChangeSlice.
// Requires category to exist and not be archived; idempotent when the image is
// unchanged.

@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded({categoryImage?: string})
  | CategoryImageChanged({categoryImage: string})
  | CategoryArchived
  // Same reason as the rename slice: the refusal is on `archived`, so the slice
  // has to hear when that stops being true.
  | CategoryUnarchived

@schema
type command =
  // Guard-only, for the same reason as `RenameCategory`: legal on a listed
  // category, refused on an archived one, and it moves nothing.
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Categories.Listed])
  ChangeCategoryImage({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
    })

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived

@schema
type event =
  | CategoryImageChanged({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
    })
