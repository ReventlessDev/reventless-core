// CategoryImages StateChangeSlice: a category's attachment set — the second host
// of the attachments trait, so its rules are proven to survive a host swap.

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

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  AttachCategoryImage({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
      altText?: string,
    })
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  RemoveCategoryImage({categoryId: string, categoryImage: Reventless.UploadableImage.t})
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  SetPrimaryCategoryImage({categoryId: string, categoryImage: Reventless.UploadableImage.t})
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
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

// Guard-only, as `RenameCategory`: legal on a listed category, refused on an
// archived one, and it moves nothing. Narrower than the product host's, which
// allows the archived shelf too — the same trait, two hosts' policies.
type lifecycleState = Categories.shelfStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | AttachCategoryImage(_)
  | RemoveCategoryImage(_)
  | SetPrimaryCategoryImage(_)
  | SetCategoryImageAltText(_) =>
    Guards([Categories.Listed])
  }
}

// Grafted, and this is the only record of it that survives into a deployed
// plugin — every other signal (the dependency, the spread, the rules alias, the
// conformance binding) is source-side. The value comes from the trait, so a
// rename or a removed dependency is a build error rather than a stale row.
let traits = [TraitAttachments.Attachments.declaration]
