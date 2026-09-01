// ProductImages StateChangeSlice: a product's attachment set — attach, remove,
// choose the primary, caption. The graft of the attachments trait; the set's
// rules are asserted by the trait's conformance suite, bound in the tests.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({productId: string})
  | ProductImageAttached({productImage: string})
  | ProductImageRemoved({productImage: string})
  | ProductPrimaryImageSet({productImage: string})
  | ProductImageAltTextSet({productImage: string, altText: string})
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

// Legal while the product is on the shelf and while it is archived; refused once
// it is discontinued, which is terminal.
@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Products.Listed, Products.Archived])
  AttachProductImage({
      productId: string,
      productImage: Reventless.UploadableImage.t,
      altText?: string,
    })
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Products.Listed, Products.Archived])
  RemoveProductImage({productId: string, productImage: Reventless.UploadableImage.t})
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Products.Listed, Products.Archived])
  SetPrimaryProductImage({productId: string, productImage: Reventless.UploadableImage.t})
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Products.Listed, Products.Archived])
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

// Grafted, and this is the only record of it that survives into a deployed
// plugin — every other signal (the dependency, the spread, the rules alias, the
// conformance binding) is source-side. The value comes from the trait, so a
// rename or a removed dependency is a build error rather than a stale row.
let traits = [TraitAttachments.Attachments.declaration]
