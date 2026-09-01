// ProductImages StateChangeSlice: a product's attachment set — attach, remove,
// choose the primary, caption. The graft of the attachment-set trait; the set's
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
