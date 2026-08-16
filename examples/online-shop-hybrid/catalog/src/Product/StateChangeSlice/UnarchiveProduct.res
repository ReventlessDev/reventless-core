// UnarchiveProduct StateChangeSlice.
// The way back onto the shelf. Requires the product to exist; idempotent if it
// is already listed, and refused on a discontinued one.
//
// This slice is what makes `Archived` and `Discontinued` two states rather than
// one: they withdraw the row identically, and only the existence of a command
// naming one of them as a from-state says which withdrawal can be undone.
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @allowedStates([Products.Archived])
  UnarchiveProduct({productId: string})

@schema
type error = ProductNotFound | ProductIsDiscontinued

@schema
type event = ProductUnarchived({productId: string})
