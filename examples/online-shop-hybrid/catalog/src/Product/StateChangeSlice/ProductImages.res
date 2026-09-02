// ProductImages StateChangeSlice: a product's attachment set — attach, remove,
// choose the primary, caption. The graft of the attachments trait; the set's
// rules are asserted by the trait's conformance suite, bound in the tests.

@@reventless.spec

// `ProductAdded` carries no `productId` here: the id is the partition this slice
// reads, not payload it folds. Declaring it reads as "this id comes from a
// foreign producer", leaving the slice with no partition of its own — an
// ambiguity that drops the derived scope for the whole boundary.
@schema
type consumedEvent =
  | ProductAdded
  | ProductImageAttached({productImage: Reventless.UploadableImage.t})
  | ProductImageRemoved({productImage: Reventless.UploadableImage.t})
  | ProductPrimaryImageSet({productImage: Reventless.UploadableImage.t})
  | ProductImageAltTextSet({productImage: Reventless.UploadableImage.t, altText: string})
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  AttachProductImage({
      productId: string,
      productImage: Reventless.UploadableImage.t,
      altText?: string,
    })
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  RemoveProductImage({productId: string, productImage: Reventless.UploadableImage.t})
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  SetPrimaryProductImage({productId: string, productImage: Reventless.UploadableImage.t})
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  SetProductImageAltText({
      productId: string,
      productImage: Reventless.UploadableImage.t,
      altText: string,
    })

@schema
type error =
  | ProductNotFound
  | ProductIsDiscontinued
  | ProductImageNotAttached

@schema
type event =
  | ProductImageAttached({
      productId: string,
      productImage: Reventless.UploadableImage.t,
      altText?: string,
    })
  | ProductImageRemoved({productId: string, productImage: Reventless.UploadableImage.t})
  | ProductPrimaryImageSet({productId: string, productImage: Reventless.UploadableImage.t})
  | ProductImageAltTextSet({
      productId: string,
      productImage: Reventless.UploadableImage.t,
      altText: string,
    })

// Legal while the product is on the shelf and while it is archived; refused once
// it is discontinued, which is terminal. Four from-sets and no target: an
// attachment is not where the product sits, so none of these move it.
type lifecycleState = Products.shelfStatus

let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
  open Reventless.Transition
  switch command {
  | AttachProductImage(_)
  | RemoveProductImage(_)
  | SetPrimaryProductImage(_)
  | SetProductImageAltText(_) =>
    Guards([Products.Listed, Products.Archived])
  }
}

// Grafted, and this is the only record of it that survives into a deployed
// plugin — every other signal (the dependency, the spread, the rules alias, the
// conformance binding) is source-side. The value comes from the trait, so a
// rename or a removed dependency is a build error rather than a stale row.
let traits = [TraitAttachments.Attachments.declaration]
