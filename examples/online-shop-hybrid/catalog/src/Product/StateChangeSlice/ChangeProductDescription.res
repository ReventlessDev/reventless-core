// ChangeProductDescription StateChangeSlice.
// Requires product to exist; idempotent when description is unchanged.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({description: string})
  | ProductDescriptionChanged({description: string})
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

// Legal while the product is on the shelf and while it is archived; refused once
// it is discontinued, which is terminal.
@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Products.Listed, Products.Archived])
  ChangeProductDescription({productId: string, description: string})

@schema
type error =
  | ProductNotFound
  | ProductIsDiscontinued

@schema
type event =
  | ProductDescriptionChanged({
      productId: string,
      description: string,
    })
