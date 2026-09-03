// CategoryImages StateChangeSlice: a category's single image — the second host of
// the attachments trait, so its rules are proven to survive a host swap. It is
// also the bounded host: a category has one picture, not a gallery, and the trait
// enforces that rather than the projection hoping for it.

@@reventless.spec

@schema
type consumedEvent =
  | CategoryAdded
  | CategoryImageAttached({categoryImage: Reventless.UploadableImage.t})
  | CategoryImageRemoved({categoryImage: Reventless.UploadableImage.t})
  | CategoryImageAltTextSet({categoryImage: Reventless.UploadableImage.t, altText: string})
  | CategoryArchived
  // The refusal is on `archived`, so the slice has to hear when that stops.
  | CategoryUnarchived

// One reference field, on `SetCategoryImage`, and it accepts a new file — so it
// is typed as the uploadable it is and a form binds an upload input to it.
// Neither other command names a reference: a category holds one image, so there
// is nothing to choose between, and asking a caller to name it would be asking
// them to repeat what the row already says. That is the whole of the bounded
// cardinality's effect on the surface.
@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  SetCategoryImage({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
      altText?: string,
    })
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  RemoveCategoryImage({categoryId: string})
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  SetCategoryImageAltText({categoryId: string, altText: string})

@schema
type error =
  | CategoryNotFound
  | CategoryAlreadyArchived
  | CategoryImageNotAttached

// `CategoryImageRemoved` still names what left. Setting a second image decides
// two facts — the old one leaves, then the new one arrives — and a removal that
// named nothing would leave a log nobody could replay into a row.
@schema
type event =
  | CategoryImageAttached({
      categoryId: string,
      categoryImage: Reventless.UploadableImage.t,
      altText?: string,
    })
  | CategoryImageRemoved({categoryId: string, categoryImage: Reventless.UploadableImage.t})
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
  | SetCategoryImage(_)
  | RemoveCategoryImage(_)
  | SetCategoryImageAltText(_) =>
    Guards([Categories.Listed])
  }
}

// Grafted, and this is the only record of it that survives into a deployed
// plugin — every other signal (the dependency, the spread, the rules alias, the
// conformance binding) is source-side. The value comes from the trait, so a
// rename or a removed dependency is a build error rather than a stale row.
let traits = [TraitAttachments.Attachments.declaration]
