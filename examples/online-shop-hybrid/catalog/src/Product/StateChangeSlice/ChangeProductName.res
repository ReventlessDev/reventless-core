// ChangeProductName StateChangeSlice.
// Requires product to exist; idempotent when name is unchanged.

@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded({name: string})
  | ProductNameChanged({name: string})
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

// Legal on a listed product and on an archived one — correcting a name while a
// product is off the shelf is exactly when it wants correcting. Not legal on a
// discontinued one, which is terminal.
@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition([Products.Listed, Products.Archived])
  ChangeProductName({productId: string, name: string})

@schema
type error =
  | ProductNotFound
  | ProductIsDiscontinued

@schema
type event =
  | ProductNameChanged({productId: string, name: string})
