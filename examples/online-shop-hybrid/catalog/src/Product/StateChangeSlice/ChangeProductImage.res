// ChangeProductImage StateChangeSlice.
// Requires product to exist; idempotent when the image is unchanged.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({imageUrl?: string})
  | ProductImageChanged({imageUrl: string})
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

// Legal while the product is on the shelf and while it is archived; refused once
// it is discontinued, which is terminal.
@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Products.Listed, Products.Archived])
  ChangeProductImage({productId: string, @storageRef("productImages") imageUrl: string})

@schema
type error =
  | ProductNotFound
  | ProductIsDiscontinued

@schema
type event =
  | ProductImageChanged({
      productId: string,
      @storageRef("productImages") imageUrl: string,
    })
