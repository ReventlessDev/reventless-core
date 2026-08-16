// DiscontinueProduct StateChangeSlice.
// Takes a product off the shelf for good. Idempotent if already discontinued,
// and allowed from either live state — a product can be discontinued straight
// out of the catalog or after a spell in the archive.
//
// There is deliberately no way back. `Discontinued` names no from-state on any
// command, so the generated lifecycle diagram draws it terminal and no surface
// offers an exit.
@@reventless.spec

@schema
type consumedEvent =
  | ProductAdded
  | ProductArchived
  | ProductUnarchived
  | ProductDiscontinued

@schema
type command =
  // Both live states, because the decision is about the product's future rather
  // than about where it sits today.
  | @authorize(AllowGroups(["Admin", "Merchandiser"]))
  @transition(([Products.Listed, Products.Archived]) => Products.Discontinued)
  DiscontinueProduct({productId: string})

@schema
type error = ProductNotFound

@schema
type event = ProductDiscontinued({productId: string})
