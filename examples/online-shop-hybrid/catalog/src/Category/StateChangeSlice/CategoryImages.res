// CategoryImages StateChangeSlice: a category's attachment set — the second host
// of the file-attachment trait, so its rules are proven to survive a host swap.

@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryImageAttached({categoryImage: string})
  | CategoryImageRemoved({categoryImage: string})
  | CategoryPrimaryImageSet({categoryImage: string})
  | CategoryImageAltTextSet({categoryImage: string, altText: string})
  | CategoryArchived
  // The refusal is on `archived`, so the slice has to hear when that stops.
  | CategoryUnarchived

// Guard-only, as `RenameCategory`: legal on a listed category, refused on an
// archived one, and it moves nothing.
@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Categories.Listed])
  AttachCategoryImage({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
      altText?: string,
    })
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Categories.Listed])
  RemoveCategoryImage({categoryId: string, categoryImage: Reventless.UploadableImage.t})
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Categories.Listed])
  SetPrimaryCategoryImage({categoryId: string, categoryImage: Reventless.UploadableImage.t})
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Categories.Listed])
  SetCategoryImageAltText({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
      altText: string,
    })

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived
  | CategoryImageNotAttached

@schema
type event =
  | CategoryImageAttached({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
      altText?: string,
    })
  | CategoryImageRemoved({categoryId: string, categoryImage: Reventless.UploadableImage.t})
  | CategoryPrimaryImageSet({categoryId: string, categoryImage: Reventless.UploadableImage.t})
  | CategoryImageAltTextSet({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
      altText: string,
    })
